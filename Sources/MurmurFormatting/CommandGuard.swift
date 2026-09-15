import Foundation

/// The safety check for a Command Mode rewrite.
///
/// The third guard in this app, and it exists because the first two ask questions this pass
/// can't answer. `isPlausibleCleanup` rejects any word that wasn't in the input — but a
/// rewrite is *asked* for new words, which is the whole point of "make this more formal".
/// `PolishGuard` requires every digit and name to survive — but "summarise this" is a
/// legitimate instruction that drops most of them.
///
/// So this one only asks the questions that survive an instruction to change the text:
///
/// 1. **Nothing was invented.** Every digit sequence, URL, path, email address and code
///    identifier in the *output* has to have been in the input. The transform may drop a
///    number; it may never make one up, and it may never quietly alter one — an altered
///    number reads as an invented one, which is exactly what should be caught.
/// 2. **The model didn't start talking.** "Here's a more formal version…" is the model
///    answering the user instead of rewriting the text, and it is the failure that would
///    otherwise land in their document.
/// 3. **It didn't just repeat the instruction back.** The other shape of the same failure.
/// 4. **It isn't a runaway.** A very wide band, because shortening and expanding are both
///    things people ask for. This catches a model that lost the plot, not one that was
///    terse.
public enum CommandGuard {
    public struct Verdict: Sendable {
        public let isAcceptable: Bool
        /// Why it was rejected, for the log and the HUD. Nil when accepted.
        public let reason: String?

        static let accepted = Verdict(isAcceptable: true, reason: nil)
        static func rejected(_ reason: String) -> Verdict {
            Verdict(isAcceptable: false, reason: reason)
        }
    }

    /// Deliberately wide. "Cut this in half" and "expand on this" are both ordinary
    /// instructions, so the band is a runaway check and nothing more.
    private static let minimumRatio = 0.15
    private static let maximumRatio = 4.0

    /// - Parameter instruction: what the speaker asked for, so output that merely echoes it
    ///   can be caught.
    public static func check(
        original: String,
        rewritten: String,
        instruction: String = ""
    ) -> Verdict {
        let rewritten = rewritten.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rewritten.isEmpty else { return .rejected("empty output") }

        if let tell = explanatoryPrefix(in: rewritten) {
            return .rejected("the model started explaining itself (\(tell))")
        }

        let instruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        if !instruction.isEmpty, matches(rewritten, instruction) {
            return .rejected("the model repeated the instruction back")
        }

        let invented = numbers(in: rewritten).subtracting(numbers(in: original))
        guard invented.isEmpty else {
            return .rejected("invented a number: \(invented.sorted().prefix(3).joined(separator: ", "))")
        }

        let newTokens = PolishGuard.exactTokens(in: rewritten)
            .subtracting(PolishGuard.exactTokens(in: original))
        guard newTokens.isEmpty else {
            return .rejected("invented a link, path or identifier: \(newTokens.sorted().prefix(3).joined(separator: ", "))")
        }

        let before = PolishGuard.words(in: original).count
        let after = PolishGuard.words(in: rewritten).count
        guard before > 0 else { return .rejected("empty input") }
        let ratio = Double(after) / Double(before)
        guard ratio >= minimumRatio, ratio <= maximumRatio else {
            return .rejected(String(format: "length ratio %.2f", ratio))
        }

        return .accepted
    }

    // MARK: - Extraction

    /// Every run of digits, as a set.
    ///
    /// A set rather than `PolishGuard`'s ordered string, because a rewrite is allowed to
    /// reorder and to drop — "we need 3 by Friday and 12 by Monday" may legitimately become
    /// "12 by Monday". Only a number that was never there is a problem.
    static func numbers(in text: String) -> Set<String> {
        var found: Set<String> = []
        guard let regex = Rx.make("\\p{N}+", []) else { return found }
        for match in Rx.matches(regex, in: text) {
            guard let range = Range(match.range, in: text) else { continue }
            // Leading zeros dropped, so "007" and "7" are the same number rather than an
            // invented one.
            found.insert(String(String(text[range]).drop { $0 == "0" }))
        }
        found.remove("")
        return found
    }

    private static let tells = [
        "here's", "here is", "sure,", "certainly,", "of course,", "i cannot", "i can't",
        "i'm unable", "as an ai", "the rewritten", "rewritten version", "revised version",
        "more formal version", "a more", "okay,", "ok,", "got it,", "understood,",
    ]

    private static func explanatoryPrefix(in text: String) -> String? {
        let lowered = text.lowercased()
        return tells.first { lowered.hasPrefix($0) }
    }

    /// Whether two strings are the same once case and punctuation are set aside.
    private static func matches(_ lhs: String, _ rhs: String) -> Bool {
        func bare(_ text: String) -> String {
            text.lowercased()
                .split { !$0.isLetter && !$0.isNumber }
                .joined(separator: " ")
        }
        return bare(lhs) == bare(rhs)
    }
}
