import Foundation

/// Recognises a list the speaker read out and marks it up.
///
/// The hard part is not finding "first" and "second" — it is not finding them in "the first
/// thing I noticed". Three rules keep the inference honest, and together they mean an
/// ordinary sentence containing an ordinal is left alone:
///
/// 1. **Clause position.** A cue counts at the start of the text, after sentence or comma
///    punctuation, or after "and". A cue with nothing but a space in front of it — which is
///    what a speech engine gives you when the speaker didn't pause — counts too, but only
///    under the extra conditions in `looseSequenceHolds`. "The first thing" fails this and
///    is never a cue, because "the" sits in front of it.
/// 2. **Starts at one, ascends.** The sequence has to open with "first" and climb. A stray
///    "second" with no "first" in front of it is not a list.
/// 3. **Two items minimum.** "First I need coffee." stays a sentence.
///
/// Rule 1 used to require punctuation outright, and that is why dictated lists worked only
/// sometimes: the punctuation came from the *cleanup* pass, which is off by default and
/// unavailable on most Macs, so "first buy milk second call the bank" — said in one breath,
/// which is how people actually say it — arrived here as one flat sentence with nothing to
/// anchor a cue to. A space is now enough, and `looseSequenceHolds` carries the weight rule
/// 1 used to.
///
/// Explicit spoken markers — "bullet point", "number one" — never come through here as
/// inference; `SpokenCommands` has already turned them into real markers, and this pass
/// only renumbers them so a continued list keeps counting.
public enum ListStructure {
    /// Cues that name their own position.
    private static let ordinals: [String: Int] = [
        "first": 1, "firstly": 1, "first of all": 1, "first off": 1,
        "second": 2, "secondly": 2,
        "third": 3, "thirdly": 3,
        "fourth": 4, "fourthly": 4,
        "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10,
    ]

    /// Cues that mean "one more than the last one". Only ever counted once an ordinal has
    /// established that a list is under way — otherwise every "and then" in ordinary speech
    /// would start one.
    private static let continuations: Set<String> = [
        "next", "then", "after that", "also", "finally", "lastly", "and finally", "last",
    ]

    public static func apply(to text: String, options: StructureOptions) -> String {
        guard !text.isEmpty, options.field.allowsLineBreaks, options.field.isProse else {
            return text
        }

        let startAt = CaretContinuation.nextListNumber(after: options.textBeforeCaret) ?? 1
        if hasExplicitMarkers(text) {
            return renumber(text, from: startAt)
        }

        guard options.listsEnabled, options.listStyle != .none else { return text }
        return infer(in: text, options: options, startAt: startAt)
    }

    // MARK: - Already marked up

    private static func hasExplicitMarkers(_ text: String) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        let marked = lines.count { line in
            Rx.firstMatch(Rx.make("^[ \\t]*(?:\\d{1,3}[.)]|[-*\u{2022}])\\s+\\S"), in: String(line)) != nil
        }
        return marked >= 2
    }

    /// Renumbers `1.`-style markers so they run consecutively from `start`.
    ///
    /// Needed because the numbers arrive from two places that can't see each other: what the
    /// speaker said out loud, and what is already above the caret. Saying "number one" under
    /// an existing item 2 should type item 3, not a second item 1.
    private static func renumber(_ text: String, from start: Int) -> String {
        guard let regex = Rx.make("(?<lead>(?:^|\\n)[ \\t]*)(?<n>\\d{1,3})(?<punct>[.)])(?=\\s+\\S)") else {
            return text
        }
        var next = start
        return SpokenCommands.rewrite(text, regex) { match, source in
            let lead = Rx.text(match, source, named: "lead") ?? ""
            let punct = Rx.text(match, source, named: "punct") ?? "."
            let value = next
            next += 1
            return "\(lead)\(value)\(punct)"
        }
    }

    // MARK: - Inference

    private struct Cue {
        let leadStart: String.Index
        let itemStart: String.Index
        let value: Int
        /// Whether this cue had only whitespace in front of it rather than punctuation.
        let loose: Bool
    }

    /// Words that make a following ordinal attributive rather than an item marker.
    ///
    /// Closed-class only, and that is the point: "the first thing", "my first car", "for the
    /// first time", "in first place". A verb can do the same thing ("he finished first") but
    /// the set of verbs is open, so that case is caught on the way out instead — see
    /// `looseSequenceHolds`.
    private static let attributive: Set<String> = [
        "the", "a", "an", "this", "that", "these", "those", "my", "your", "his", "her", "its",
        "our", "their", "whose", "every", "each", "another", "any", "some", "no", "one",
        "at", "in", "on", "for", "from", "of", "to", "by", "with", "about", "into", "onto",
        "than", "until", "since", "during", "per",
    ]

    /// Words no genuine list item begins with.
    ///
    /// A spoken item is a clause — "buy milk", "ship the beta". A fragment starting with a
    /// conjunction or a preposition is the tail of the sentence the ordinal was sitting in,
    /// which is exactly what "he finished first *and she finished* second" produces.
    private static let neverStartsAnItem: Set<String> = [
        "and", "or", "but", "nor", "yet", "so", "because", "although", "though", "while",
        "whereas", "since", "unless", "until", "if", "when", "where", "than", "then", "also",
        "plus", "in", "on", "at", "to", "of", "from", "with", "without", "by", "about",
        "into", "onto", "over", "under", "between", "through", "during", "against", "after",
        "before", "as", "per", "via", "near", "upon",
    ]

    private static func infer(in text: String, options: StructureOptions, startAt: Int) -> String {
        let words = (ordinals.keys.map { $0 } + continuations)
            .sorted { ($0.count, $0) > ($1.count, $1) }
            .map { phrase in
                phrase.split(separator: " ")
                    .map { NSRegularExpression.escapedPattern(for: String($0)) }
                    .joined(separator: "\\s+")
            }
            .joined(separator: "|")

        // The lead is captured rather than looked behind, so the pattern stays inside the
        // fixed-length-lookbehind subset both regex engines agree on. `loose` is its own
        // group so the pass can tell a cue the speaker punctuated from one it merely paused
        // at — the two are held to different standards below. It is last in the alternation
        // because alternation is ordered: "and" has to be read as "and" before it is read as
        // whitespace-plus-a-word.
        let pattern = "(?<lead>^|[.!?;,\\n]\\s*|\\s+and\\s+|(?<loose>[ \\t]+))"
            + "(?<cue>\(words))(?![\\p{L}\\p{N}])[,:]?\\s+(?=\\S)"
        guard let regex = Rx.make(pattern) else { return text }

        var cues: [Cue] = []
        var expected = 1

        for match in Rx.matches(regex, in: text) {
            guard let whole = Range(match.range, in: text),
                  let cue = Rx.text(match, text, named: "cue")?.lowercased()
            else { continue }

            let loose = match.range(withName: "loose").location != NSNotFound

            let normalized = cue.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            let value: Int
            if let ordinal = ordinals[normalized] {
                value = ordinal
            } else if continuations.contains(normalized), !cues.isEmpty {
                // Never on a loose lead. "then", "next" and "also" are far too ordinary to
                // start an item off nothing but a space — an explicit ordinal at least names
                // its own position, and these only inherit one.
                guard !loose else { continue }
                value = expected
            } else {
                continue
            }

            // A space in front is not enough on its own. "the first thing", "my first car",
            // "for the first time" all put an ordinary word in front of the ordinal, and
            // that word is what says the ordinal is describing a noun rather than marking an
            // item.
            if loose, attributive.contains(wordBefore(whole.lowerBound, in: text)) { continue }

            // Must open at one and climb by one. Anything else is an ordinal doing ordinary
            // work in a sentence, not an item marker.
            guard value == expected else { continue }
            cues.append(
                Cue(leadStart: whole.lowerBound, itemStart: whole.upperBound, value: value, loose: loose)
            )
            expected += 1
        }

        guard cues.count >= 2 else { return text }

        var items: [String] = []
        for (index, cue) in cues.enumerated() {
            let end = index + 1 < cues.count ? cues[index + 1].leadStart : text.endIndex
            let item = String(text[cue.itemStart..<end])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !item.isEmpty else { return text }
            items.append(item)
        }

        // Everything above is the old contract. This is the price of accepting a cue that
        // had only a space in front of it.
        if cues.contains(where: \.loose), !looseSequenceHolds(items) { return text }

        let preamble = String(text[text.startIndex..<cues[0].leadStart])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // A trailing full stop only comes off when every item is a fragment. If any item
        // contains sentence punctuation of its own, these are sentences and keep their marks.
        let allFragments = items.allSatisfy { item in
            !item.dropLast().contains { ".!?".contains($0) }
        }

        let style = CaretContinuation.continuedStyle(after: options.textBeforeCaret) ?? options.listStyle
        var lines: [String] = []
        if !preamble.isEmpty {
            lines.append(needsColon(preamble) ? preamble + ":" : preamble)
        }
        for (offset, item) in items.enumerated() {
            lines.append(style.marker(at: startAt + offset) + tidy(item, stripPeriod: allFragments))
        }
        return lines.joined(separator: "\n")
    }

    /// The word immediately before `index`, lowercased, or "" at the start of the text.
    private static func wordBefore(_ index: String.Index, in text: String) -> String {
        let head = text[text.startIndex..<index]
        let word = head.reversed().prefix { $0.isLetter || $0 == "'" || $0 == "\u{2019}" }
        return String(word.reversed()).lowercased()
    }

    /// Whether a sequence that leaned on a loose cue reads as a list rather than a sentence.
    ///
    /// Two checks, and between them they cover the failure that punctuation used to rule out
    /// for free — an ordinal used as an adverb, with the rest of the sentence mistaken for an
    /// item:
    ///
    /// - **No item opens with a conjunction or a preposition.** "He finished first and she
    ///   finished second" yields the item "and she finished", and "She placed first in the
    ///   race and second in the relay" yields "in the race". A spoken item is a clause and
    ///   starts like one.
    /// - **No item still contains an ordinal.** A leftover "third" sitting inside item two
    ///   means the sequence was read off the wrong words — "I ate first, she ate second, he
    ///   ate third" splits into two items and strands the third ordinal, which is the tell.
    private static func looseSequenceHolds(_ items: [String]) -> Bool {
        for item in items {
            let first = item.prefix { $0.isLetter || $0 == "'" || $0 == "\u{2019}" }.lowercased()
            if neverStartsAnItem.contains(first) { return false }
            if containsOrdinal(item) { return false }
        }
        return true
    }

    private static func containsOrdinal(_ item: String) -> Bool {
        let words = ordinals.keys.filter { !$0.contains(" ") }
        guard let regex = Rx.make(Rx.phrases(words)) else { return false }
        return Rx.firstMatch(regex, in: item) != nil
    }

    private static func tidy(_ item: String, stripPeriod: Bool) -> String {
        var result = item
        while let last = result.last, last == "," || last == ";" || last.isWhitespace {
            result.removeLast()
        }
        if stripPeriod, result.last == "." { result.removeLast() }
        guard let first = result.first, first.isLowercase else { return result }
        return first.uppercased() + result.dropFirst()
    }

    private static func needsColon(_ preamble: String) -> Bool {
        guard let last = preamble.last else { return false }
        return last.isLetter || last.isNumber
    }
}
