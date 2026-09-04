import Foundation

/// Takes back something the speaker said and then rejected, before it is ever typed.
///
/// The behaviour this implements is **retract and restate** — you finish a thought, decide
/// against it, say so, and say the replacement. "I'll send it next week. Actually no,
/// scratch that. I'll send it today." should type only the last sentence.
///
/// It also handles the other shape people use, **repair in place** — "I want to meet you at
/// 4, no wait at 3" — where only a value changed and the rest of the sentence should survive.
///
/// Three rules do the work, tried in order:
///
/// 1. **Alignment.** Look at what was said *after* the marker and try to find the thing it
///    replaces, inside the same sentence. Two ways, both cheap and both wrong-answer-safe:
///    the replacement repeats a word ("at 4" → "at 3"), or the replacement is a bare value
///    of a kind that appears earlier ("Tuesday" → "Wednesday", "3 things" → "4"). Confined
///    to one sentence, so it never reaches across a full stop.
/// 2. **Scope.** No alignment found, so erase back to the nearest boundary of the configured
///    kind — a sentence end by default, a comma if the user wants it tighter, everything if
///    they want it looser.
/// 3. **Filler back-off.** If everything between that boundary and the marker is filler —
///    "Actually no, scratch that." is a whole sentence containing nothing but a retraction —
///    the retraction was aimed at the sentence *before* it, so the cut extends back one
///    more boundary. Without this the pass erases only itself, which is the single most
///    common way a retraction feature looks broken.
///
/// The marker list still contains no bare "I meant". Alignment makes it *usable* rather than
/// destructive, but "I meant" is also ordinary English in a way "scratch that" is not, and
/// the cleanup model already applies spoken self-corrections when it runs.
public enum Retraction {
    public struct Result: Sendable {
        public let text: String
        /// What was erased, most recent last. Recorded in the run log so a retraction that
        /// fired on ordinary speech is recoverable rather than merely regrettable.
        public let removed: [String]

        public var didFire: Bool { !removed.isEmpty }
    }

    /// Retractions that always take everything said so far. The speaker asked for a blank
    /// page, so scope doesn't apply.
    static let wideMarkers = [
        "scratch all that", "scratch all of that", "scratch everything",
        "delete all that", "delete all of that", "delete everything",
        "forget all that", "forget all of that", "forget everything",
        "ignore all that", "ignore all of that", "ignore everything",
        "start over", "start again", "let me start over",
    ]

    /// Retractions scoped by `RetractionScope`.
    ///
    /// Every phrase here is unambiguous: it can't plausibly appear as ordinary content in
    /// the middle of an email. A bare "sorry" is deliberately absent — "sorry, I didn't mean
    /// to bother you" is a sentence people write, and the cost of a false positive is words
    /// the speaker never gets back.
    static let narrowMarkers = [
        "scratch that", "strike that", "delete that",
        "no wait", "wait no", "no sorry", "sorry no",
        "i didn't mean that", "i did not mean that", "i didnt mean that",
        "that's not right", "thats not right", "that's wrong", "thats wrong",
        "that's not what i meant", "thats not what i meant",
        "never mind that", "nevermind that",
        "let me start that again", "let me try that again",
        "let me say that again", "let me rephrase that",
    ]

    /// Words a retraction may sit among without changing what it is aimed at.
    private static let filler: Set<String> = [
        "actually", "no", "nope", "ok", "okay", "oh", "sorry", "wait", "um", "uh", "uhm",
        "erm", "er", "hmm", "well", "yeah", "yes", "and", "but", "so", "hang", "on", "hold",
        "right", "i", "mean", "like", "just",
    ]

    private static let sentenceBoundaries: Set<Character> = [".", "!", "?", "\n", "\u{2026}"]
    private static let clauseBoundaries: Set<Character> = [
        ".", "!", "?", "\n", "\u{2026}", ",", ";", ":", "\u{2014}", "\u{2013}",
    ]

    /// Punctuation left stranded where the marker used to be.
    private static let strandedAfterMarker: Set<Character> = [
        ",", ".", ";", ":", "!", "?", "\u{2014}", "\u{2013}", "-",
    ]

    public static func apply(to text: String, options: StructureOptions) -> Result {
        guard options.retractionEnabled, !text.isEmpty else {
            return Result(text: text, removed: [])
        }

        let wide = Rx.make(Rx.phrases(wideMarkers))
        let narrow = Rx.make(Rx.phrases(narrowMarkers + options.extraRetractionPhrases))

        var current = text
        var removed: [String] = []

        // Bounded rather than `while true`: a pathological transcript full of markers should
        // cost a fixed amount of work, and eight retractions in one utterance is already
        // well past anything real.
        for _ in 0..<8 {
            guard let hit = firstMarker(in: current, wide: wide, narrow: narrow) else { break }

            var end = hit.range.upperBound
            while end < current.endIndex,
                  strandedAfterMarker.contains(current[end]) || current[end].isWhitespace {
                end = current.index(after: end)
            }

            // A marker with nothing after it is far more likely to be content than a command
            // — "that's wrong." at the end of a sentence is a claim, not a retraction. It
            // would also erase the whole utterance and inject nothing.
            guard current[end...].contains(where: { $0.isLetter || $0.isNumber }) else { break }

            let start: String.Index
            if hit.isWide {
                start = current.startIndex
            } else if options.retractionScope != .utterance,
                      let alignment = align(
                          in: current,
                          markerStart: hit.range.lowerBound,
                          replacementStart: end
                      ) {
                switch alignment {
                case .deleteFrom(let anchor):
                    start = anchor
                case .substitute(let token, let replacement, let deleting):
                    // Two disjoint edits, so the string is rebuilt rather than mutated —
                    // replacing one range invalidates every index into the other.
                    removed.append(String(current[token]))
                    current = String(current[..<token.lowerBound])
                        + replacement
                        + String(current[token.upperBound..<deleting.lowerBound])
                        + String(current[deleting.upperBound...])
                    continue
                }
            } else {
                start = cutStart(
                    in: current,
                    markerStart: hit.range.lowerBound,
                    scope: options.retractionScope
                )
            }

            removed.append(String(current[start..<end]))
            current.replaceSubrange(start..<end, with: "")
        }

        guard !removed.isEmpty else { return Result(text: text, removed: []) }
        return Result(text: current.trimmingCharacters(in: .whitespacesAndNewlines), removed: removed)
    }

    // MARK: - Alignment

    private enum Alignment {
        /// The replacement repeats a word from earlier in the sentence. Everything from that
        /// word through the marker goes.
        case deleteFrom(String.Index)
        /// The replacement is a bare value — a number, a weekday, a month — of the same kind
        /// as a word earlier in the sentence. That word is swapped for it, and the marker and
        /// the replacement are deleted where they stand.
        case substitute(token: Range<String.Index>, with: String, deleting: Range<String.Index>)
    }

    /// Works out what the words after the marker were replacing.
    ///
    /// - Parameter replacementStart: the first character after the marker and any punctuation
    ///   it left stranded.
    ///
    /// The search never crosses a sentence boundary in either direction. That single
    /// constraint is what keeps this from colliding with the filler back-off: a retraction
    /// that is a sentence of its own ("Actually no, scratch that.") has nothing in its own
    /// sentence to align against, so it falls through to scope, which is correct for it.
    private static func align(
        in text: String,
        markerStart: String.Index,
        replacementStart: String.Index
    ) -> Alignment? {
        var replacementEnd = replacementStart
        while replacementEnd < text.endIndex, !sentenceBoundaries.contains(text[replacementEnd]) {
            replacementEnd = text.index(after: replacementEnd)
        }
        let replacement = String(text[replacementStart..<replacementEnd])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !replacement.isEmpty else { return nil }

        let sentenceStart = scanBack(text, from: markerStart, boundaries: sentenceBoundaries).start
        let region = words(in: text, from: sentenceStart, to: markerStart)
        guard !region.isEmpty else { return nil }

        let replacementWords = words(in: text, from: replacementStart, to: replacementEnd)
        guard let lead = replacementWords.first else { return nil }

        // 1. The replacement repeats a word. "at 4, no wait at 3" — the second "at" says
        //    where the first one's phrase began.
        //
        //    Capped at four words, and the cap is what separates a repair from a
        //    restatement. "We should ship the beta, no wait, the beta is not ready" also
        //    repeats a word, but the speaker is replacing the whole clause, not a phrase
        //    inside it — aligning on that "the" produces "ship the beta is not ready".
        //    Anything long enough to be a clause of its own goes to scope instead.
        if replacementWords.count <= 4,
           let anchor = region.last(where: { same($0.text, lead.text) }) {
            return .deleteFrom(anchor.range.lowerBound)
        }

        // 2. The replacement is a bare value. Only for something short — a clause that
        //    happens to open with a number is a restatement, not a value.
        guard replacementWords.count <= 3, let kind = Lexicon.kind(of: lead.text) else {
            return nil
        }
        guard let target = region.last(where: { Lexicon.kind(of: $0.text) == kind }) else {
            return nil
        }

        // The marker takes the punctuation in front of it with it, or "3 things, no wait 4"
        // leaves the comma behind.
        var deleteStart = markerStart
        while deleteStart > text.startIndex {
            let previous = text.index(before: deleteStart)
            guard text[previous].isWhitespace || strandedAfterMarker.contains(text[previous]) else { break }
            deleteStart = previous
        }
        // `>=`, not `>`: "Send it Tuesday, no wait Wednesday" leaves the two regions
        // touching at the comma, which is the ordinary case rather than an overlap.
        guard deleteStart >= target.range.upperBound else { return nil }

        return .substitute(token: target.range, with: replacement, deleting: deleteStart..<replacementEnd)
    }

    private static func same(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    /// Word runs and where they are, in order.
    private static func words(
        in text: String,
        from start: String.Index,
        to end: String.Index
    ) -> [(text: String, range: Range<String.Index>)] {
        var result: [(String, Range<String.Index>)] = []
        var cursor = start
        while cursor < end {
            guard text[cursor].isLetter || text[cursor].isNumber else {
                cursor = text.index(after: cursor)
                continue
            }
            let wordStart = cursor
            while cursor < end,
                  text[cursor].isLetter || text[cursor].isNumber
                    || text[cursor] == "'" || text[cursor] == "\u{2019}" {
                cursor = text.index(after: cursor)
            }
            result.append((String(text[wordStart..<cursor]), wordStart..<cursor))
        }
        return result
    }

    // MARK: - Scope

    private struct Hit {
        let range: Range<String.Index>
        let isWide: Bool
    }

    /// The earliest marker in the text. On a tie the wide marker wins, because "scratch all
    /// that" and "scratch that" start at the same place and the longer reading is the one
    /// the speaker said.
    private static func firstMarker(
        in text: String,
        wide: NSRegularExpression?,
        narrow: NSRegularExpression?
    ) -> Hit? {
        let wideHit = Rx.firstMatch(wide, in: text).flatMap { Range($0.range, in: text) }
        let narrowHit = Rx.firstMatch(narrow, in: text).flatMap { Range($0.range, in: text) }

        switch (wideHit, narrowHit) {
        case let (.some(w), .some(n)):
            return w.lowerBound <= n.lowerBound ? Hit(range: w, isWide: true) : Hit(range: n, isWide: false)
        case let (.some(w), .none): return Hit(range: w, isWide: true)
        case let (.none, .some(n)): return Hit(range: n, isWide: false)
        case (.none, .none): return nil
        }
    }

    private static func cutStart(
        in text: String,
        markerStart: String.Index,
        scope: RetractionScope
    ) -> String.Index {
        let boundaries: Set<Character>
        switch scope {
        case .utterance: return text.startIndex
        case .sentence: boundaries = sentenceBoundaries
        case .clause: boundaries = clauseBoundaries
        }

        var (start, boundary) = scanBack(text, from: markerStart, boundaries: boundaries)

        // At most two hops. One covers the ordinary "Actually no, scratch that." sentence;
        // a second covers "Actually. No. Scratch that." Beyond that the speaker is not
        // retracting, they are stammering, and eating more of their words is the wrong bet.
        var hops = 0
        while hops < 2, let mark = boundary, isPureFiller(text[start..<markerStart]) {
            (start, boundary) = scanBack(text, from: mark, boundaries: boundaries)
            hops += 1
        }
        return start
    }

    /// - Returns: the first character of the region following the nearest boundary before
    ///   `index`, and the boundary character's own position so the caller can hop past it.
    private static func scanBack(
        _ text: String,
        from index: String.Index,
        boundaries: Set<Character>
    ) -> (start: String.Index, boundary: String.Index?) {
        var cursor = index
        while cursor > text.startIndex {
            let previous = text.index(before: cursor)
            if boundaries.contains(text[previous]) {
                var start = cursor
                while start < index, text[start].isWhitespace {
                    start = text.index(after: start)
                }
                return (start, previous)
            }
            cursor = previous
        }
        return (text.startIndex, nil)
    }

    private static func isPureFiller(_ region: Substring) -> Bool {
        let words = region
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
        return words.allSatisfy { filler.contains($0) }
    }
}
