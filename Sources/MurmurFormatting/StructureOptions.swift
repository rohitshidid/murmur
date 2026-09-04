import Foundation

/// What kind of text field a transcript is about to land in.
///
/// The app you are dictating into is only half the answer. Mail's *To* field, its *Subject*
/// line and its body want three different registers, and a browser is one bundle ID
/// covering a hundred different destinations. Everything in this module that decides
/// whether to break a line, number an item or add a full stop asks this first.
public enum FieldKind: String, Codable, Sendable, CaseIterable {
    case emailBody
    case emailSubject
    case emailRecipient
    case searchField
    case urlBar
    case code
    case terminal
    /// A single-line text field with no more specific meaning.
    case shortText
    /// A multi-line text area or document body.
    case longText
    /// Nothing readable. Behaves like `longText` minus anything destructive.
    case unknown

    /// Whether a newline can be inserted here at all.
    ///
    /// In a single-line field a newline is not a line break — it submits the form, which is
    /// how a list turns into four sent messages.
    public var allowsLineBreaks: Bool {
        switch self {
        case .emailBody, .longText, .code, .terminal, .unknown: true
        case .emailSubject, .emailRecipient, .searchField, .urlBar, .shortText: false
        }
    }

    /// Whether a trailing full stop belongs on the last sentence.
    ///
    /// A search box, a subject line and a shell prompt all read worse with one, and in the
    /// search box it changes the query.
    public var wantsTerminalPunctuation: Bool {
        switch self {
        case .emailBody, .longText, .unknown: true
        case .emailSubject, .emailRecipient, .searchField, .urlBar, .shortText, .code, .terminal: false
        }
    }

    /// Whether prose conventions apply. Code and terminals are left alone: an identifier is
    /// not a sentence and must not be sentence-cased, listed or signed off.
    public var isProse: Bool {
        switch self {
        case .code, .terminal, .urlBar: false
        default: true
        }
    }
}

/// How a spoken list should be marked once it has been recognised.
public enum ListMarkerStyle: String, Codable, Sendable, CaseIterable {
    case numbered
    case bullet
    case dash
    /// Never turn speech into a list here.
    case none

    public var displayName: String {
        switch self {
        case .numbered: "1. 2. 3."
        case .bullet: "Bullets"
        case .dash: "Dashes"
        case .none: "Off"
        }
    }

    /// - Parameter index: 1-based position in the list.
    public func marker(at index: Int) -> String {
        switch self {
        case .numbered: "\(index). "
        case .bullet: "• "
        case .dash: "- "
        case .none: ""
        }
    }
}

/// How much a retraction erases when the speaker doesn't say.
///
/// Sentence is the default because it matches how people repair themselves out loud — they
/// finish a thought, reject it, and start the thought again. Clause is for anyone who finds
/// that too greedy; utterance is for anyone who finds it not greedy enough.
public enum RetractionScope: String, Codable, Sendable, CaseIterable {
    /// Back to the nearest comma, dash, colon or sentence end — whichever is closest.
    case clause
    /// Back to the start of the sentence the retraction appeared in.
    case sentence
    /// Everything said before the retraction.
    case utterance

    public var displayName: String {
        switch self {
        case .clause: "Clause"
        case .sentence: "Sentence"
        case .utterance: "Everything"
        }
    }
}

/// Everything the structure pass needs to know, with no reference to AppKit, Accessibility
/// or user defaults.
///
/// Kept as a plain value so the whole module is a pure function of its input — which is what
/// makes it runnable from the shared test vectors, and what would let the Windows app
/// reimplement it against the same contract.
public struct StructureOptions: Sendable {
    public var field: FieldKind
    public var listStyle: ListMarkerStyle
    public var retractionScope: RetractionScope
    public var commandsEnabled: Bool
    public var listsEnabled: Bool
    public var retractionEnabled: Bool
    public var signOffEnabled: Bool

    /// Whether a bare closing may have the configured name appended to it.
    ///
    /// The single place this module writes a word the speaker didn't say, so it gets its own
    /// switch. On, "…let me know. Thanks." signs itself; off, a name has to be spoken.
    public var autoSignOff: Bool

    /// Every way the speaker signs their name, longest first. Empty disables sign-off
    /// detection entirely rather than guessing at a name.
    public var userNames: [String]

    /// Extra retraction phrases the user added, on top of the built-in list.
    public var extraRetractionPhrases: [String]

    /// The text immediately before the insertion point in the destination field, or empty
    /// when it couldn't be read. Only the tail matters, so callers should pass a few
    /// hundred characters rather than a whole document.
    public var textBeforeCaret: String

    public init(
        field: FieldKind = .unknown,
        listStyle: ListMarkerStyle = .numbered,
        retractionScope: RetractionScope = .sentence,
        commandsEnabled: Bool = true,
        listsEnabled: Bool = true,
        retractionEnabled: Bool = true,
        signOffEnabled: Bool = true,
        autoSignOff: Bool = true,
        userNames: [String] = [],
        extraRetractionPhrases: [String] = [],
        textBeforeCaret: String = ""
    ) {
        self.field = field
        self.listStyle = listStyle
        self.retractionScope = retractionScope
        self.commandsEnabled = commandsEnabled
        self.listsEnabled = listsEnabled
        self.retractionEnabled = retractionEnabled
        self.signOffEnabled = signOffEnabled
        self.autoSignOff = autoSignOff
        self.userNames = userNames.sorted { $0.count > $1.count }
        self.extraRetractionPhrases = extraRetractionPhrases
        self.textBeforeCaret = textBeforeCaret
    }

    /// The destination-free defaults, used by tests and by any path with no focused field.
    public static let none = StructureOptions()
}
