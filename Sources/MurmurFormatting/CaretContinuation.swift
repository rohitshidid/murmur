import Foundation

/// Makes a new utterance join what's already in the field instead of colliding with it.
///
/// Dictation is judged on the seam. Speak a second sentence into a half-finished one and
/// most tools give you `I went to the storeAnd bought milk.` — no space, a capital in the
/// middle, and a full stop the sentence didn't want. All of that is knowable: the text
/// before the insertion point says exactly which of those apply.
///
/// It also carries list state across utterances, which is the thing that makes dictated
/// lists usable at all. Nobody speaks a five-item list in one breath; they speak one item,
/// stop, and speak the next. If the line above the caret is `2. Call the bank`, the next
/// utterance is item three.
public enum CaretContinuation {
    /// Words safe to lowercase when a sentence is being continued rather than started.
    ///
    /// An allowlist rather than "lowercase whatever comes first", because the first word is
    /// as likely to be a name as an article, and `sarah will handle it` is a worse mistake
    /// than a stray capital.
    private static let continuationWords: Set<String> = [
        "the", "a", "an", "and", "but", "or", "so", "because", "since", "although", "though",
        "while", "whereas", "which", "that", "who", "whom", "whose", "when", "where", "why",
        "how", "if", "unless", "until", "after", "before", "as", "than", "then",
        "with", "without", "for", "from", "into", "onto", "to", "in", "on", "at", "by", "of",
        "about", "over", "under", "between", "through", "during", "against",
        "it", "its", "this", "these", "those", "they", "them", "their", "we", "our", "us",
        "you", "your", "he", "him", "his", "she", "her", "hers",
        "is", "are", "was", "were", "be", "been", "being", "has", "have", "had", "do", "does",
        "did", "will", "would", "should", "could", "can", "may", "might", "must",
        "just", "also", "even", "only", "still", "already", "again", "too", "very",
        "not", "no", "yes", "here", "there", "now", "today", "tomorrow", "yesterday",
    ]

    private static let sentenceEnders: Set<Character> = [".", "!", "?", "\u{2026}"]

    /// Characters after which no separating space belongs.
    private static let openers: Set<Character> = [
        "(", "[", "{", "\u{201C}", "\u{2018}", "\"", "'", "/", "-", "\u{2014}", "@", "#", "$",
    ]

    /// The number a list continued below the caret should start at.
    ///
    /// - Returns: nil when the line above the caret isn't a numbered item, so callers can
    ///   fall back to 1.
    public static func nextListNumber(after textBeforeCaret: String) -> Int? {
        guard let regex = Rx.make("^[ \\t]*(?<n>\\d{1,3})[.)]\\s+\\S"),
              let match = Rx.firstMatch(regex, in: lastLine(of: textBeforeCaret)),
              let digits = Rx.text(match, lastLine(of: textBeforeCaret), named: "n"),
              let value = Int(digits)
        else { return nil }
        return value + 1
    }

    /// The bullet character in use above the caret, so a continued list keeps one marker.
    public static func bulletMarker(after textBeforeCaret: String) -> String? {
        guard let regex = Rx.make("^[ \\t]*(?<m>[-*\u{2022}])\\s+\\S"),
              let match = Rx.firstMatch(regex, in: lastLine(of: textBeforeCaret))
        else { return nil }
        return Rx.text(match, lastLine(of: textBeforeCaret), named: "m").map { $0 + " " }
    }

    /// The list style to continue with, or nil when the caret isn't sitting under a list.
    public static func continuedStyle(after textBeforeCaret: String) -> ListMarkerStyle? {
        if nextListNumber(after: textBeforeCaret) != nil { return .numbered }
        switch bulletMarker(after: textBeforeCaret)?.first {
        case "-", "*": return .dash
        case "\u{2022}": return .bullet
        default: return nil
        }
    }

    /// Whether the caret is at the very start of an otherwise empty field.
    ///
    /// The one place a salutation belongs, and the one place a leading capital is
    /// unambiguously right.
    public static func isFieldEmpty(_ textBeforeCaret: String) -> Bool {
        textBeforeCaret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Joins `text` onto whatever precedes the caret.
    public static func apply(to text: String, options: StructureOptions) -> String {
        let before = options.textBeforeCaret
        guard let last = before.last, !isFieldEmpty(before), !text.isEmpty else { return text }
        guard let firstCharacter = text.first else { return text }

        // The new text opens with punctuation of its own; adding a space in front of a comma
        // is worse than adding nothing.
        let startsWithPunctuation = !firstCharacter.isLetter
            && !firstCharacter.isNumber
            && !openers.contains(firstCharacter)

        if last.isWhitespace || openers.contains(last) || startsWithPunctuation {
            return text
        }

        if sentenceEnders.contains(last) {
            // A finished sentence: separate them, leave the capital alone.
            return " " + text
        }

        // Mid-sentence. The speaker is continuing a thought, so the cleanup pass's leading
        // capital is wrong, and so is any full stop it may have appended earlier.
        return " " + lowercasingContinuation(text)
    }

    private static func lowercasingContinuation(_ text: String) -> String {
        let firstWord = text.prefix { $0.isLetter || $0 == "'" || $0 == "\u{2019}" }
        guard !firstWord.isEmpty,
              // All-caps is an acronym or a deliberate shout; either way, not ours to touch.
              firstWord != firstWord.uppercased() || firstWord.count == 1,
              continuationWords.contains(firstWord.lowercased())
        else { return text }
        return firstWord.lowercased() + text.dropFirst(firstWord.count)
    }

    /// The last line with anything on it.
    ///
    /// Not simply "the text after the last newline": pressing return to start an item and
    /// *then* dictating is the normal way to continue a list, so the caret is usually on a
    /// blank line and the line that carries the numbering is the one above it.
    private static func lastLine(of text: String) -> String {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).reversed()
        where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            return String(line)
        }
        return ""
    }
}
