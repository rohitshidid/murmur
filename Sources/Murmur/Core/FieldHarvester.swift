import AppKit
import ApplicationServices
import Foundation
import MurmurFormatting

/// What the destination field is, and what is already in it.
struct FieldSnapshot: Sendable {
    var kind: FieldKind
    /// The field's own label — placeholder, title or description. "To:", "Subject", "Search".
    var label: String?
    /// The page's host when the destination is a browser.
    var host: String?
    /// The tail of the text before the insertion point.
    var textBeforeCaret: String

    static let unknown = FieldSnapshot(kind: .unknown, label: nil, host: nil, textBeforeCaret: "")
}

/// Reads the one Accessibility element that matters: the field the text is about to land in.
///
/// `ScreenHarvester` walks the whole tree looking for vocabulary. This does the opposite —
/// a handful of attributes on a single element, plus a short walk up its ancestors for the
/// page URL. That difference is the point: it runs on every dictation, in the window between
/// the key coming up and text appearing, so it has to cost almost nothing.
///
/// What it buys is the difference between knowing which *app* you're in and knowing which
/// *field*. Mail's To line, its Subject line and its body are one bundle ID and three
/// completely different registers, and until this existed all three got the same treatment.
enum FieldHarvester {
    /// Same ceiling as `ScreenHarvester`, and load-bearing for the same reason: one
    /// unresponsive app must not stall the thread between release and injection.
    private static let messagingTimeout: Float = 0.15

    /// How far up the tree to look for a page URL. A web area is a handful of levels above
    /// the focused input in every browser tested; twelve is slack, not a search.
    private static let ancestorBudget = 12

    /// How much text before the caret to keep. Enough to see the line above and the end of
    /// the current sentence, and small enough that reading it from a long document is cheap.
    private static let caretBudget = 600

    /// - Parameter pid: the destination app, captured on the main actor by the caller.
    /// - Parameter bundleID: that app's bundle identifier, for family classification.
    static func snapshot(pid: pid_t, bundleID: String?) -> FieldSnapshot {
        guard AXIsProcessTrusted() else { return .unknown }

        // Same trap as `ScreenHarvester`: Accessibility against our own process builds the
        // tree synchronously on this thread, which evaluates SwiftUI bodies off the main
        // actor and crashes. Reachable whenever the Record button is used.
        guard pid != getpid() else { return .unknown }

        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, messagingTimeout)

        guard let raw = copy(systemWide, kAXFocusedUIElementAttribute) else { return .unknown }
        let element = unsafeDowncast(raw as AnyObject, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, messagingTimeout)

        let role = string(element, kAXRoleAttribute)
        let subrole = string(element, kAXSubroleAttribute)
        let label = [
            string(element, kAXPlaceholderValueAttribute),
            string(element, kAXTitleAttribute),
            string(element, kAXDescriptionAttribute),
        ].compactMap { $0 }.first
        let host = AppFamily.isBrowser(bundleID: bundleID) ? host(from: element) : nil

        let snapshot = FieldSnapshot(
            kind: classify(role: role, subrole: subrole, label: label, host: host, bundleID: bundleID),
            label: label,
            host: host,
            textBeforeCaret: textBeforeCaret(element)
        )
        Log.speech.info("field: \(snapshot.kind.rawValue, privacy: .public), \(snapshot.textBeforeCaret.count, privacy: .public) char(s) before caret")
        return snapshot
    }

    // MARK: - Classification

    /// Most specific signal first. Role alone is nearly useless — Mail's To field, its
    /// Subject field and a search box are all `AXTextField` — so the label does most of the
    /// work and the role only separates one line from many.
    static func classify(
        role: String?,
        subrole: String?,
        label: String?,
        host: String?,
        bundleID: String?
    ) -> FieldKind {
        if subrole == "AXSearchField" { return .searchField }
        if subrole == "AXSecureTextField" { return .shortText }

        let label = label?.lowercased() ?? ""
        let family = AppFamily.of(bundleID: bundleID, host: host)

        if AppFamily.isBrowser(bundleID: bundleID), matches(label, ["address", "search or enter", "url"]) {
            return .urlBar
        }
        if matches(label, ["search", "filter", "find"]) { return .searchField }

        if family == .mail {
            if matches(label, ["to:", "to", "cc", "bcc", "recipient"]) { return .emailRecipient }
            if matches(label, ["subject"]) { return .emailSubject }
            if role == "AXTextArea" || role == "AXWebArea" || role == "AXTextField" {
                // A single-line field in a mail client with no recipient or subject label is
                // more likely the body of a compose window than anything else worth naming.
                return role == "AXTextField" ? .emailSubject : .emailBody
            }
            return .emailBody
        }

        if AppFamily.isTerminal(bundleID: bundleID) { return .terminal }
        if family == .code { return .code }

        switch role {
        case "AXTextArea", "AXWebArea": return .longText
        case "AXTextField", "AXComboBox": return .shortText
        default: return .unknown
        }
    }

    /// Whole-word-ish label matching. A label of "To:" must match "to" without "Topic"
    /// matching it too.
    private static func matches(_ label: String, _ candidates: [String]) -> Bool {
        guard !label.isEmpty else { return false }
        let stripped = label.trimmingCharacters(in: CharacterSet(charactersIn: " :.\u{2026}"))
        return candidates.contains { candidate in
            stripped == candidate || stripped.hasPrefix(candidate + " ") || stripped.hasSuffix(" " + candidate)
        }
    }

    // MARK: - Caret

    private static func textBeforeCaret(_ element: AXUIElement) -> String {
        guard let caret = caretLocation(element), caret > 0 else { return "" }

        // The parameterized read first: it returns only the span asked for, so a caret at
        // the end of a long document costs the same as one in an empty field. Not every app
        // implements it, hence the fallback.
        let start = max(0, caret - caretBudget)
        var request = CFRange(location: start, length: caret - start)
        if let parameter = AXValueCreate(.cfRange, &request) {
            var result: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(
                element,
                kAXStringForRangeParameterizedAttribute as CFString,
                parameter,
                &result
            ) == .success, let text = result as? String {
                return text
            }
        }

        guard let whole = copy(element, kAXValueAttribute) as? String else { return "" }
        let value = whole as NSString
        let end = min(caret, value.length)
        guard end > 0 else { return "" }
        let from = max(0, end - caretBudget)
        return value.substring(with: NSRange(location: from, length: end - from))
    }

    /// The insertion point as a UTF-16 offset, which is what Accessibility deals in.
    private static func caretLocation(_ element: AXUIElement) -> Int? {
        guard let raw = copy(element, kAXSelectedTextRangeAttribute) else { return nil }
        let value = unsafeDowncast(raw as AnyObject, to: AXValue.self)
        guard AXValueGetType(value) == .cfRange else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(value, .cfRange, &range) else { return nil }
        return range.location
    }

    // MARK: - Host

    private static func host(from element: AXUIElement) -> String? {
        var current = element
        for _ in 0..<ancestorBudget {
            if let url = copy(current, kAXURLAttribute) as? NSURL, let host = url.host {
                return host
            }
            guard let parent = copy(current, kAXParentAttribute) else { return nil }
            current = unsafeDowncast(parent as AnyObject, to: AXUIElement.self)
            AXUIElementSetMessagingTimeout(current, messagingTimeout)
        }
        return nil
    }

    // MARK: - AX helpers

    private static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        guard let value = copy(element, attribute) as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
