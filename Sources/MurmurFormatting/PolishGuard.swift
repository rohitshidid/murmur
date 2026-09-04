import Foundation

/// The safety check for the grammar-repair pass.
///
/// The cleanup guard in the app rejects any output containing a word that wasn't spoken.
/// That is exactly right for cleanup, which is subtractive — and exactly wrong for repair,
/// which has to be allowed to change "me and him goes" into "he and I went". A pass that
/// may rewrite words needs a guard built on what must *survive* instead of on what may
/// appear.
///
/// Four things survive or the output is thrown away:
///
/// 1. **Every digit, in order.** Compared as one flat sequence rather than as tokens, so
///    "eight thirty" may become "8:30" while "send £250" can never become "send £350".
/// 2. **Every name.** No capitalised word may appear that wasn't in the original, and none
///    may go missing — including weekdays and months, which is the check that stops
///    "Tuesday" quietly becoming "Wednesday".
/// 3. **Every exact string.** URLs, email addresses, file paths and code-shaped tokens are
///    compared verbatim. These are the things that stop working when they change.
/// 4. **Roughly the same amount of text.** A wider band than cleanup uses, because repair
///    legitimately adds words — but not wide enough to let a summary through.
public enum PolishGuard {
    public struct Verdict: Sendable {
        public let isAcceptable: Bool
        /// Why it was rejected, for the log. Nil when accepted.
        public let reason: String?

        static let accepted = Verdict(isAcceptable: true, reason: nil)
        static func rejected(_ reason: String) -> Verdict {
            Verdict(isAcceptable: false, reason: reason)
        }
    }

    /// Repair adds articles, auxiliaries and prepositions, so the floor is higher and the
    /// ceiling wider than the cleanup pass's 0.35–1.5.
    private static let minimumRatio = 0.6
    private static let maximumRatio = 1.9

    public static func check(original: String, polished: String) -> Verdict {
        let polished = polished.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !polished.isEmpty else { return .rejected("empty output") }

        if let tell = explanatoryPrefix(in: polished) {
            return .rejected("model started explaining itself (\(tell))")
        }

        guard digits(in: original) == digits(in: polished) else {
            return .rejected("a number changed")
        }

        guard calendarWords(in: original) == calendarWords(in: polished) else {
            return .rejected("a date or weekday changed")
        }

        let originalExact = exactTokens(in: original)
        let polishedExact = exactTokens(in: polished)
        guard originalExact == polishedExact else {
            let lost = originalExact.subtracting(polishedExact).sorted()
            let gained = polishedExact.subtracting(originalExact).sorted()
            return .rejected("a URL, address, path or identifier changed (\((lost + gained).prefix(3).joined(separator: ", ")))")
        }

        let originalNames = properNouns(in: original)
        let polishedNames = properNouns(in: polished)
        let vocabulary = Set(words(in: original).map { $0.lowercased() })
        let invented = polishedNames.filter { !vocabulary.contains($0.lowercased()) }
        guard invented.isEmpty else {
            return .rejected("invented a name: \(invented.sorted().prefix(3).joined(separator: ", "))")
        }
        let polishedVocabulary = Set(words(in: polished).map { $0.lowercased() })
        let dropped = originalNames.filter { !polishedVocabulary.contains($0.lowercased()) }
        guard dropped.isEmpty else {
            return .rejected("dropped a name: \(dropped.sorted().prefix(3).joined(separator: ", "))")
        }

        let before = words(in: original).count
        let after = words(in: polished).count
        guard before > 0 else { return .rejected("empty input") }
        let ratio = Double(after) / Double(before)
        guard ratio >= minimumRatio, ratio <= maximumRatio else {
            return .rejected(String(format: "length ratio %.2f", ratio))
        }

        return .accepted
    }

    // MARK: - Extraction

    /// Every digit in the text, concatenated in order.
    ///
    /// Deliberately not tokenised. "8 30 a m" and "8:30 AM" have different tokens and the
    /// same digits, which is the one reformatting this pass should be free to do.
    static func digits(in text: String) -> String {
        String(text.filter(\.isNumber))
    }

    private static let calendar: Set<String> = [
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "mon", "tue", "tues", "wed", "thu", "thur", "thurs", "fri", "sat", "sun",
        "january", "february", "march", "april", "may", "june", "july", "august",
        "september", "october", "november", "december",
        "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec",
        "today", "tomorrow", "yesterday", "tonight", "morning", "afternoon", "evening",
        "am", "pm", "noon", "midnight",
    ]

    static func calendarWords(in text: String) -> [String] {
        words(in: text)
            .map { $0.lowercased() }
            .filter { calendar.contains($0) }
            .sorted()
    }

    /// Strings that only work if they are exactly right.
    static func exactTokens(in text: String) -> Set<String> {
        let patterns = [
            // Email
            "[\\p{L}\\p{N}._%+-]+@[\\p{L}\\p{N}.-]+\\.[\\p{L}]{2,}",
            // URL
            "(?:https?://|www\\.)[^\\s]+",
            // POSIX and Windows paths
            "(?:~|\\.{1,2})?/[\\p{L}\\p{N}._/-]{2,}",
            "[A-Za-z]:\\\\[^\\s]+",
            // Backticked code
            "`[^`]+`",
            // camelCase, snake_case and dotted identifiers
            "\\b[\\p{Ll}\\p{N}]+[\\p{Lu}][\\p{L}\\p{N}]*\\b",
            "\\b[\\p{L}\\p{N}]+_[\\p{L}\\p{N}_]+\\b",
            "\\b[\\p{L}_][\\p{L}\\p{N}_]*(?:\\.[\\p{L}_][\\p{L}\\p{N}_]*)+\\b",
        ]
        var found: Set<String> = []
        for pattern in patterns {
            guard let regex = Rx.make(pattern, []) else { continue }
            for match in Rx.matches(regex, in: text) {
                guard let range = Range(match.range, in: text) else { continue }
                found.insert(String(text[range]))
            }
        }
        return found
    }

    /// Capitalised words that aren't simply the first word of a sentence.
    ///
    /// Sentence-initial words are excluded because repair moves clauses around, and a name
    /// that starts the sentence before and sits in the middle after would otherwise read as
    /// both dropped and invented.
    static func properNouns(in text: String) -> Set<String> {
        guard let regex = Rx.make("(?<lead>[\\p{L}\\p{N},;]\\s+)(?<word>[\\p{Lu}][\\p{L}'\u{2019}-]+)", []) else {
            return []
        }
        var found: Set<String> = []
        for match in Rx.matches(regex, in: text) {
            guard let word = Rx.text(match, text, named: "word"), word != "I" else { continue }
            found.insert(word)
        }
        // Calendar words are checked separately and case-insensitively, so they are
        // deliberately not folded in here.
        return found
    }

    static func words(in text: String) -> [String] {
        text.split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private static let tells = [
        "here's the", "here is the", "sure,", "certainly,", "i cannot", "i can't",
        "as an ai", "the corrected", "corrected version", "revised version",
    ]

    private static func explanatoryPrefix(in text: String) -> String? {
        let lowered = text.lowercased()
        return tells.first { lowered.hasPrefix($0) }
    }
}
