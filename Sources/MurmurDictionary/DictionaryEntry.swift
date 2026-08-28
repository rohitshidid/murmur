import Foundation

/// One thing the dictionary knows.
///
/// Three kinds, because the three jobs are genuinely different:
///
/// - `.term` — a word or phrase the engine should know exists: "Anthropic", "Vercel".
///   Feeds engine biasing only; it has no "wrong" spelling to correct.
/// - `.correction` — a mapping: when you hear X, write Y. "cloud code" → "Claude Code".
///   Feeds both biasing (on Y, the correct form) and the correction pass (X → Y).
/// - `.snippet` — an expansion: say X, get a whole block of Y. "my address" → three lines.
///   Deliberately invoked, where a correction repairs something you didn't ask for.
///
/// The distinction between the last two is not cosmetic. A correction's output is a short
/// phrase that the engine should be *biased* toward hearing; a snippet's output is a body
/// of text you already know how to say, and feeding it to the engine as context would
/// flood a 40-phrase bias list with prose and make transcription worse.
public struct DictionaryEntry: Identifiable, Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case term
        case correction
        case snippet
    }

    public var id: UUID
    public var kind: Kind

    /// The text that gets written. For `.term` this is the word itself; for `.correction`
    /// and `.snippet` it's the Y in "when you hear X, write Y".
    ///
    /// Biased into the engine for the first two kinds, never for `.snippet`.
    public var write: String

    /// For `.correction` and `.snippet`: the X in "when you hear X". Empty for `.term`.
    public var hear: String

    /// Disabled entries stay in the file but stop affecting anything, so you can test
    /// whether a rule is helping without deleting it.
    public var isEnabled: Bool

    public init(id: UUID = UUID(), kind: Kind, write: String, hear: String = "", isEnabled: Bool = true) {
        self.id = id
        self.kind = kind
        self.write = write
        self.hear = hear
        self.isEnabled = isEnabled
    }

    public static func term(_ word: String) -> DictionaryEntry {
        DictionaryEntry(kind: .term, write: word)
    }

    public static func correction(hear: String, write: String) -> DictionaryEntry {
        DictionaryEntry(kind: .correction, write: write, hear: hear)
    }

    public static func snippet(hear: String, write: String) -> DictionaryEntry {
        DictionaryEntry(kind: .snippet, write: write, hear: hear)
    }

    /// How this entry reads in the plain-text file.
    ///
    /// `->` is a correction and `=>` a snippet. Two arrows rather than a keyword because the
    /// file is meant to be edited by hand, and `my address => …` reads as what it does.
    ///
    /// A snippet body is the one value that can contain newlines, which a line-oriented
    /// file cannot hold literally — so they are escaped on the way out and restored on the
    /// way in. Backslashes are escaped first, or a body ending in one would swallow the
    /// escape of whatever followed.
    public var fileLine: String {
        let body = switch kind {
        case .term: write
        case .correction: "\(hear) -> \(write)"
        case .snippet: "\(hear) => \(Self.escape(write))"
        }
        return isEnabled ? body : "# off: \(body)"
    }

    /// Encodes newlines and tabs so a multi-line snippet survives one line of the file.
    public static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    /// The inverse of `escape`.
    ///
    /// Scanned character by character rather than by three `replacingOccurrences` passes:
    /// unescaping `\\n` sequentially would turn a literal backslash-then-n into a newline,
    /// which is exactly the round trip this has to protect.
    public static func unescape(_ text: String) -> String {
        var result = ""
        var isEscaped = false

        for character in text {
            if isEscaped {
                switch character {
                case "n": result.append("\n")
                case "t": result.append("\t")
                case "\\": result.append("\\")
                default:
                    // Not an escape we know — keep both characters as written.
                    result.append("\\")
                    result.append(character)
                }
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else {
                result.append(character)
            }
        }

        if isEscaped { result.append("\\") }
        return result
    }
}

/// A reason an entry looks likely to fire on text you didn't mean it to.
///
/// Surfaced in the UI when an entry is added — the spec's "warn me if an entry looks like
/// it would match something common". Never blocks; you may genuinely want to rewrite a
/// common word, and it's your dictionary.
public struct DictionaryWarning: Identifiable, Sendable {
    public var id: String { message }
    public let message: String

    /// Ordinary English words that would fire constantly if used as a whole trigger.
    /// Deliberately short — this catches the obvious foot-guns, not every possible one.
    private static let common: Set<String> = [
        "a", "about", "all", "also", "and", "any", "are", "as", "at", "back", "be", "because",
        "but", "by", "call", "can", "case", "check", "class", "close", "cloud", "code", "come",
        "could", "data", "day", "did", "do", "does", "down", "each", "even", "file", "find",
        "first", "for", "from", "get", "give", "go", "good", "great", "group", "had", "has",
        "have", "he", "her", "here", "him", "his", "how", "if", "in", "into", "is", "it",
        "its", "just", "key", "know", "like", "line", "list", "look", "make", "man", "many",
        "may", "me", "more", "most", "my", "need", "new", "no", "not", "now", "number", "of",
        "off", "on", "one", "only", "open", "or", "other", "our", "out", "over", "page",
        "part", "people", "point", "put", "read", "right", "run", "said", "same", "say",
        "see", "set", "she", "should", "show", "side", "so", "some", "state", "still", "such",
        "take", "team", "test", "than", "that", "the", "their", "them", "then", "there",
        "these", "they", "thing", "think", "this", "time", "to", "two", "type", "up", "us",
        "use", "user", "very", "want", "was", "way", "we", "well", "were", "what", "when",
        "where", "which", "who", "will", "with", "word", "work", "would", "year", "you",
        "your",
    ]

    /// - Returns: warnings for `entry`, or empty if it looks safe.
    public static func check(_ entry: DictionaryEntry) -> [DictionaryWarning] {
        // Only the trigger side can misfire. A `.term` is never matched against text.
        guard entry.kind != .term else { return [] }

        let trigger = entry.hear.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trigger.isEmpty else { return [] }

        var warnings: [DictionaryWarning] = []
        let words = trigger.lowercased().split(whereSeparator: { $0 == " " || $0 == "-" })

        if words.count == 1, let only = words.first {
            if common.contains(String(only)) {
                warnings.append(DictionaryWarning(
                    message: "“\(trigger)” is an ordinary word. This will rewrite every use of it, "
                        + "not just the ones you mean. Consider a longer phrase."
                ))
            } else if only.count <= 3 {
                warnings.append(DictionaryWarning(
                    message: "“\(trigger)” is very short and will match often. Consider a longer phrase."
                ))
            }
        }

        if entry.write.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(trigger) == .orderedSame {
            warnings.append(DictionaryWarning(
                message: "This rewrites “\(trigger)” to itself, so it will never change anything."
            ))
        }

        return warnings
    }
}
