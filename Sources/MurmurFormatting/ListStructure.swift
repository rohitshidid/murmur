import Foundation

/// Recognises a list the speaker read out and marks it up.
///
/// The hard part is not finding "first" and "second" — it is not finding them in "the first
/// thing I noticed". Three rules keep the inference honest, and together they mean an
/// ordinary sentence containing an ordinal is left alone:
///
/// 1. **Clause position.** A cue only counts at the start of the text, after sentence or
///    comma punctuation, or after "and". "The first thing" fails this and is never a cue,
///    because "the" sits in front of it.
/// 2. **Starts at one, ascends.** The sequence has to open with "first" and climb. A stray
///    "second" with no "first" in front of it is not a list.
/// 3. **Two items minimum.** "First I need coffee." stays a sentence.
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
    }

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
        // fixed-length-lookbehind subset both regex engines agree on.
        let pattern = "(?<lead>^|[.!?;,\\n]\\s*|\\s+and\\s+)(?<cue>\(words))(?![\\p{L}\\p{N}])[,:]?\\s+(?=\\S)"
        guard let regex = Rx.make(pattern) else { return text }

        var cues: [Cue] = []
        var expected = 1

        for match in Rx.matches(regex, in: text) {
            guard let whole = Range(match.range, in: text),
                  let cue = Rx.text(match, text, named: "cue")?.lowercased()
            else { continue }

            let normalized = cue.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            let value: Int
            if let ordinal = ordinals[normalized] {
                value = ordinal
            } else if continuations.contains(normalized), !cues.isEmpty {
                value = expected
            } else {
                continue
            }

            // Must open at one and climb by one. Anything else is an ordinal doing ordinary
            // work in a sentence, not an item marker.
            guard value == expected else { continue }
            cues.append(Cue(leadStart: whole.lowerBound, itemStart: whole.upperBound, value: value))
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
