import Foundation

/// The transforms Command Mode can perform without a model.
///
/// Command Mode holds a second key over selected text and does what you say to it. Most of
/// what people say is open-ended — "make this more formal", "turn this into two sentences" —
/// and that needs the on-device model. But a stubborn fraction is not open-ended at all:
/// "make this uppercase", "bullet these", "put it on one line". Those have exactly one right
/// answer, and asking a language model for it is slower, less reliable, and unavailable on
/// most Macs.
///
/// So they live here, they are tried first, and they are the reason the feature does
/// something useful on a Mac without Apple Intelligence rather than nothing at all. It is
/// the same argument the rest of this module is built on: a feature that exists only on top
/// of the on-device model doesn't exist for most users.
///
/// **Matching is exact, never fuzzy.** A verb fires only when the whole instruction reduces
/// to one of its phrasings. "Make this uppercase" matches; "make this uppercase but leave
/// the last line alone" does not, and falls through to the model where it belongs. Guessing
/// here would be worse than not matching: the user is watching their own text get replaced.
public enum CommandVerbs {
    public struct Match: Sendable {
        public let text: String
        /// What to call this in the HUD. Past tense, because by the time it is read the
        /// transform has already happened.
        public let label: String
    }

    /// Words that carry no instruction and appear in front of half of them.
    ///
    /// Stripped before matching so "can you please make this all caps" and "all caps" are
    /// the same instruction. Order matters: longer phrases first, or "make this" leaves
    /// "this" behind.
    private static let politeness = [
        "could you please", "can you please", "would you please", "i want you to",
        "i'd like you to", "i would like you to", "please can you", "could you", "can you",
        "would you", "please", "now", "for me", "murmur",
        "turn this into", "turn that into", "turn it into", "convert this to",
        "convert that to", "convert it to", "rewrite this as", "rewrite that as",
        "change this to", "change that to", "change it to", "format this as",
        "format that as", "format it as", "put this in", "put that in", "put it in",
        "make this into", "make that into", "make it into",
        "make this", "make that", "make it", "set this", "set that", "set it",
        "the selection", "the selected text", "this text", "that text", "the text",
        "these lines", "this line", "all of this", "all of it", "everything",
        // Bare imperatives. Over-stripping here is safe in a way under-stripping is not: an
        // instruction reduced to nothing simply fails to match and goes to the model, which
        // is where anything this list doesn't recognise belongs anyway.
        "put", "keep", "write", "format", "render", "give me", "show me", "do",
        "this", "that", "it", "them", "these", "all",
    ]

    /// Phrasings → transform. Every phrasing is matched whole, after normalisation.
    ///
    /// Written as an array rather than a dictionary because the order is the tie-break:
    /// "numbered list" has to be tested before "list", or a numbered list comes out bulleted.
    private static let verbs: [(phrasings: [String], label: String, transform: @Sendable (String) -> String)] = [
        (["numbered list", "numbered", "number these", "number the lines", "number them",
          "a numbered list", "into a numbered list", "as a numbered list"],
         "Numbered", { numbered($0) }),

        (["bullet", "bullets", "bulleted", "bullet points", "bullet point", "bulleted list",
          "bullet these", "bullet them", "a bulleted list", "a bullet list", "a list",
          "list", "into a list", "as a list", "into bullets", "as bullets"],
         "Bulleted", { bulleted($0) }),

        (["uppercase", "upper case", "all caps", "caps", "capitals", "all uppercase",
          "in caps", "in uppercase", "shout"],
         "Uppercased", { $0.uppercased() }),

        (["lowercase", "lower case", "all lowercase", "in lowercase", "no caps"],
         "Lowercased", { $0.lowercased() }),

        (["title case", "titlecase", "in title case", "capitalise each word",
          "capitalize each word", "capitalise every word", "capitalize every word"],
         "Title cased", { titleCased($0) }),

        (["sentence case", "in sentence case"],
         "Sentence cased", { sentenceCased($0) }),

        (["one line", "a single line", "single line", "join the lines", "join these lines",
          "join the line", "join", "unwrap", "on one line", "one paragraph"],
         "Joined", { joined($0) }),

        (["add a period", "add a full stop", "add the period", "add the full stop",
          "end with a period", "end with a full stop"],
         "Period added", { withTerminalPeriod($0) }),

        (["remove the period", "remove the full stop", "drop the period",
          "drop the full stop", "no period", "no full stop"],
         "Period removed", { withoutTerminalPeriod($0) }),

        (["in quotes", "quotes", "quote", "quoted", "add quotes", "wrap in quotes",
          "put in quotes", "quote marks"],
         "Quoted", { quoted($0) }),

        (["remove the quotes", "remove quotes", "no quotes", "unquote", "drop the quotes"],
         "Quotes removed", { unquoted($0) }),

        (["trim", "trim the spaces", "tidy the spacing", "fix the spacing",
          "remove extra spaces", "remove the extra spaces", "collapse the spaces"],
         "Spacing tidied", { tidied($0) }),
    ]

    /// - Returns: the transformed text, or nil when the instruction isn't one of these.
    public static func apply(_ instruction: String, to selection: String) -> Match? {
        let normalized = normalize(instruction)
        guard !normalized.isEmpty else { return nil }

        for verb in verbs where verb.phrasings.contains(normalized) {
            let result = verb.transform(selection)
            // A transform that changed nothing is not a transform. Saying "make this
            // uppercase" over text that is already uppercase should read as a no-op in the
            // HUD, not as a successful rewrite — and it must not consume the instruction
            // that the model could still have made sense of.
            guard result != selection else { return nil }
            return Match(text: result, label: verb.label)
        }
        return nil
    }

    // MARK: - Normalisation

    /// Reduces an instruction to the words that carry the instruction.
    static func normalize(_ instruction: String) -> String {
        var text = instruction
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Punctuation the speech engine added, and the trailing "please".
        text = text.replacingOccurrences(
            of: "[\\p{P}\\p{S}]",
            with: " ",
            options: .regularExpression
        )
        text = collapse(text)

        // Applied repeatedly: "make this into a list" sheds "make this into", then "a".
        var changed = true
        while changed {
            changed = false
            for filler in politeness.sorted(by: { ($0.count, $0) > ($1.count, $1) }) {
                let stripped = removingPhrase(filler, from: text)
                if stripped != text {
                    text = stripped
                    changed = true
                }
            }
        }
        return collapse(text)
    }

    /// Removes a whole-word phrase wherever it appears, leaving a single space behind.
    private static func removingPhrase(_ phrase: String, from text: String) -> String {
        let pattern = "(?<![\\p{L}\\p{N}])"
            + phrase.split(separator: " ")
                .map { NSRegularExpression.escapedPattern(for: String($0)) }
                .joined(separator: "\\s+")
            + "(?![\\p{L}\\p{N}])"
        return collapse(Rx.replacing(pattern, in: text, with: " "))
    }

    private static func collapse(_ text: String) -> String {
        Rx.replacing("\\s+", in: text, with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Transforms

    /// Splits a selection into the things a list would have one item per.
    ///
    /// Lines first, because text that is already on separate lines has already told you
    /// where the items are. Only text on a single line falls back to splitting on sentences,
    /// and a single sentence with commas falls back to splitting on those — which is what
    /// makes "milk, bread and eggs" into three bullets rather than one.
    static func items(in text: String) -> [String] {
        let lines = text
            .split(separator: "\n")
            .map { stripMarker(String($0)).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if lines.count > 1 { return lines }

        let single = lines.first ?? text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !single.isEmpty else { return [] }

        let sentences = single
            .split(whereSeparator: { ".!?".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if sentences.count > 1 { return sentences }

        let clauses = single
            .replacingOccurrences(
                of: ",?\\s+and\\s+",
                with: ",",
                options: [.regularExpression, .caseInsensitive]
            )
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if clauses.count > 1 {
            return clauses.map { withoutTerminalPeriod($0) }
        }

        return [withoutTerminalPeriod(single)]
    }

    /// Removes a list marker already on the line, so re-listing doesn't stack markers.
    private static func stripMarker(_ line: String) -> String {
        Rx.replacing("^[ \\t]*(?:\\d{1,3}[.)]|[-*\u{2022}])\\s+", in: line, with: "")
    }

    static func bulleted(_ text: String) -> String {
        let items = items(in: text)
        guard !items.isEmpty else { return text }
        return items.map { "\u{2022} " + capitalizedFirst($0) }.joined(separator: "\n")
    }

    static func numbered(_ text: String) -> String {
        let items = items(in: text)
        guard !items.isEmpty else { return text }
        // Written as a loop rather than `items.enumerated().map`, which is not the same
        // thing on a current SDK: `EnumeratedSequence` now conditionally conforms to
        // `Collection`, so that chain resolves to `Collection.map` and emits a reference to
        // a conformance descriptor that only exists in the macOS 26 stdlib. Iterating is
        // plain `Sequence` and needs nothing new.
        var lines: [String] = []
        for (offset, item) in items.enumerated() {
            lines.append("\(offset + 1). " + capitalizedFirst(item))
        }
        return lines.joined(separator: "\n")
    }

    static func joined(_ text: String) -> String {
        collapse(text.replacingOccurrences(of: "\n", with: " "))
    }

    static func titleCased(_ text: String) -> String {
        // The words a title leaves lowercase, unless they open or close it.
        let minor: Set<String> = [
            "a", "an", "the", "and", "but", "or", "nor", "for", "so", "yet", "as", "at",
            "by", "in", "of", "off", "on", "per", "to", "up", "via", "with", "from", "into",
        ]
        var isFirst = true
        var words: [String] = []
        let split = text.split(separator: " ", omittingEmptySubsequences: false)
        for (index, word) in split.enumerated() {
            let raw = String(word)
            guard !raw.isEmpty else { words.append(raw); continue }
            let isLast = index == split.count - 1
            let lowered = raw.lowercased()
            let bare = lowered.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            if !isFirst, !isLast, minor.contains(bare) {
                words.append(lowered)
            } else {
                words.append(capitalizedFirst(lowered))
            }
            isFirst = false
        }
        return words.joined(separator: " ")
    }

    static func sentenceCased(_ text: String) -> String {
        var result = ""
        var capitalizeNext = true
        for character in text.lowercased() {
            if capitalizeNext, character.isLetter {
                result.append(Character(character.uppercased()))
                capitalizeNext = false
            } else {
                result.append(character)
                if ".!?\n".contains(character) { capitalizeNext = true }
            }
        }
        return result
    }

    static func withTerminalPeriod(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last, last.isLetter || last.isNumber else { return trimmed }
        return trimmed + "."
    }

    static func withoutTerminalPeriod(_ text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // An ellipsis is not a full stop, and neither is the dot on "etc."
        guard trimmed.hasSuffix("."), !trimmed.hasSuffix("..") else { return trimmed }
        trimmed.removeLast()
        return trimmed
    }

    static func quoted(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }
        return "\u{201C}" + trimmed + "\u{201D}"
    }

    static func unquoted(_ text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pairs: [(Character, Character)] = [
            ("\u{201C}", "\u{201D}"), ("\"", "\""), ("\u{2018}", "\u{2019}"), ("'", "'"),
        ]
        for (open, close) in pairs where trimmed.count >= 2
            && trimmed.first == open && trimmed.last == close {
            trimmed.removeFirst()
            trimmed.removeLast()
            return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    static func tidied(_ text: String) -> String {
        var result = Rx.replacing("[ \\t]+", in: text, with: " ")
        result = Rx.replacing("[ \\t]*\\n[ \\t]*", in: result, with: "\n")
        result = Rx.replacing("\\n{3,}", in: result, with: "\n\n")
        result = Rx.replacing(" +(?=[,.;:!?%)\\]}])", in: result, with: "")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func capitalizedFirst(_ text: String) -> String {
        guard let first = text.first, first.isLowercase else { return text }
        return first.uppercased() + text.dropFirst()
    }
}
