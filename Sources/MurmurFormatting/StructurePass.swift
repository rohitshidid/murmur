import Foundation

/// The deterministic structure pass, in the two halves the pipeline needs.
///
/// It is split because the two halves want the text at different moments. Retraction and
/// spoken commands have to see the words exactly as they were said, before any cleanup
/// touches them — a model asked to tidy "scratch that" will tidy it into prose. Lists,
/// sign-offs and the join onto existing text want the final wording, after cleanup has
/// settled the punctuation and capitalisation they depend on.
///
/// Everything here runs whether or not the on-device model is available, which is the point:
/// smart cleanup is off by default and needs hardware not every Mac has, so features built
/// only on top of it don't exist for most users.
public enum StructurePass {
    public struct PreResult: Sendable {
        public let text: String
        /// Anything a retraction erased, for the run log.
        public let retracted: [String]

        public var didRetract: Bool { !retracted.isEmpty }
    }

    /// Runs on the raw transcript, before any cleanup.
    public static func preClean(_ raw: String, options: StructureOptions) -> PreResult {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return PreResult(text: trimmed, retracted: []) }

        // Retraction first. A retracted span may contain spoken commands, and running the
        // commands first would leave their effects behind after the words were taken back.
        let retraction = Retraction.apply(to: trimmed, options: options)

        let startingItem = CaretContinuation.nextListNumber(after: options.textBeforeCaret) ?? 1
        let commanded = SpokenCommands.apply(
            to: retraction.text,
            options: options,
            startingItemNumber: startingItem
        )

        return PreResult(text: commanded, retracted: retraction.removed)
    }

    /// Runs on the cleaned transcript, immediately before the dictionary pass.
    public static func structure(_ text: String, options: StructureOptions) -> String {
        var result = text
        result = ListStructure.apply(to: result, options: options)
        result = SignOff.apply(to: result, options: options)
        result = terminalPunctuation(result, options: options)

        // Not in a code editor or a terminal. Joining onto what precedes the caret means
        // adding a space and lowercasing a leading word, and both of those corrupt a command
        // or an identifier. Everywhere prose is written, it's the difference between
        // `storeAnd bought milk` and a sentence.
        if options.field.isProse {
            result = CaretContinuation.apply(to: result, options: options)
        }
        return result
    }

    /// Removes a full stop the destination doesn't want.
    ///
    /// The cleanup pass appends one unconditionally, which is right for an email and wrong
    /// for a search box, a subject line or a shell prompt — in the search box it is part of
    /// the query. Only a period is removed; a question or exclamation mark was asked for.
    private static func terminalPunctuation(_ text: String, options: StructureOptions) -> String {
        guard !options.field.wantsTerminalPunctuation, text.hasSuffix(".") else { return text }
        // An ellipsis or a trailing abbreviation ("etc.") is not the pass's full stop.
        guard !text.hasSuffix("..") else { return text }
        return String(text.dropLast())
    }
}
