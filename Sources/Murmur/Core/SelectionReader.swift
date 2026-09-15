import AppKit
import ApplicationServices
import Foundation

/// Reads the text the user has highlighted in whatever app has focus.
///
/// Command Mode's entire premise is that the selection is the object of the sentence — "make
/// *this* more formal" — so this runs at key **down**, not at key up. By the time the key
/// comes up the user has been talking for several seconds, and a selection is a fragile
/// thing: a stray click, an app that drops it when a panel appears, an autocomplete popping
/// under the cursor. Reading it early and confirming it late is the difference between
/// rewriting what the user pointed at and rewriting whatever happens to be selected now.
///
/// It refuses to read its own process for the same reason `FieldHarvester` and
/// `ScreenHarvester` do: Accessibility against this process builds the tree synchronously on
/// the calling thread, which evaluates SwiftUI bodies off the main actor and crashes.
enum SelectionReader {
    /// Same ceiling as the other harvesters. One unresponsive app must not stall the key.
    private static let messagingTimeout: Float = 0.15

    /// Longer than a sane selection for a single instruction, and short enough that a
    /// stray ⌘A doesn't hand the on-device model a whole document to chew through.
    ///
    /// Not silently truncated — a selection over this is refused, because rewriting the
    /// first 4,000 characters of a document and replacing the whole thing with them is
    /// destructive in a way the user cannot see coming.
    static let maximumLength = 4_000

    enum Failure: Error, Equatable {
        case noAccessibility
        case nothingSelected
        case tooLong(Int)

        var message: String {
            switch self {
            case .noAccessibility: "Accessibility is off — grant it in System Settings"
            case .nothingSelected: "Nothing selected — highlight some text first"
            case .tooLong(let count): "Selection is too long (\(count) characters)"
            }
        }
    }

    /// - Returns: the highlighted text, or why there isn't any.
    static func read() -> Result<String, Failure> {
        guard AXIsProcessTrusted() else { return .failure(.noAccessibility) }

        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, messagingTimeout)

        guard let raw = copy(systemWide, kAXFocusedUIElementAttribute) else {
            return .failure(.nothingSelected)
        }
        let element = unsafeDowncast(raw as AnyObject, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, messagingTimeout)

        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid != getpid() else {
            return .failure(.nothingSelected)
        }

        guard let text = copy(element, kAXSelectedTextAttribute) as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return .failure(.nothingSelected)
        }

        guard text.count <= maximumLength else { return .failure(.tooLong(text.count)) }
        return .success(text)
    }

    /// Whether the selection still reads as what was captured when the key went down.
    ///
    /// The last gate before the user's text is replaced. Everything between key-down and
    /// here is asynchronous — transcription, then a model call of several seconds — and any
    /// of it gives the user time to click somewhere else. Replacing a *different* selection
    /// with a rewrite of the old one is the worst thing this feature could do, and it is the
    /// one failure that leaves no trace of what was lost.
    static func stillHolds(_ captured: String) -> Bool {
        guard case .success(let current) = read() else { return false }
        return current == captured
    }

    private static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }
}
