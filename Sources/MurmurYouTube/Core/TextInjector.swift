import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

/// Puts text into whatever field currently has keyboard focus.
///
/// Two strategies, in order:
/// 1. **Accessibility** — set `kAXSelectedTextAttribute` on the focused element. Clean and
///    instant, and it leaves the pasteboard untouched.
/// 2. **Pasteboard + ⌘V** — works in Electron apps and anything else with a half-hearted
///    AX implementation. The previous pasteboard contents are restored afterwards.
///
/// The catch that makes this non-obvious: **many apps return `.success` from the AX write
/// and then do nothing.** Electron (Cursor, VS Code, Slack, Discord), Chrome, and most
/// terminal emulators all report `kAXSelectedTextAttribute` as settable, accept the write,
/// and silently drop it. So the return value is not evidence of anything — strategy 1 is
/// only trusted when the insertion point can be *observed* to have moved.
///
/// This all works because the HUD is a non-activating panel: focus never leaves the user's
/// target app, so "the focused element" is still their text field.
@MainActor
enum TextInjector {
    /// The last thing injected, kept so it can be taken back out again.
    struct Injection {
        let text: String
        let date: Date
        /// Where it went. Undo refuses to fire if you've since switched apps.
        let bundleID: String?
    }

    private(set) static var lastInjection: Injection?

    /// How long an injection stays undoable.
    ///
    /// Short on purpose. Undo removes text without being able to prove, in every app, that
    /// the text is still the text we put there — so the guarantee is bounded by "you just
    /// did this", not by "we found it again".
    private static let undoWindow: TimeInterval = 30

    static func insert(_ text: String) {
        guard !text.isEmpty else { return }

        let target = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        switch insertViaAccessibility(text) {
        case .inserted:
            Log.inject.info("inserted via AX (\(text.count) chars)")
        case .unverified(let reason):
            Log.inject.info("AX insert not verified (\(reason, privacy: .public)) — pasting")
            insertViaPasteboard(text)
        }

        lastInjection = Injection(text: text, date: Date(), bundleID: target)
    }

    // MARK: - Undo

    /// Whether there is a recent injection, in the app it went to, still worth undoing.
    static var canUndo: Bool {
        guard let last = lastInjection else { return false }
        guard Date().timeIntervalSince(last.date) < undoWindow else { return false }
        // Undoing into a different app than the one that received the text would delete
        // something we never wrote.
        let current = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        return current == last.bundleID
    }

    /// Takes the last injected text back out.
    ///
    /// Two strategies, mirroring `insert`:
    /// 1. **Accessibility** — select exactly the injected span behind the caret, confirm it
    ///    still reads as the text we wrote, and delete it. Precise and verified.
    /// 2. **⌘Z** — let the app undo its own paste.
    ///
    /// Synthesizing N backspaces was the obvious third option and is deliberately not used:
    /// it deletes blind. If the caret moved at all — a click, an arrow key, an autocomplete
    /// — it eats the user's own text instead, and there is no way to detect that after the
    /// fact. ⌘Z gets the app to undo the same edit it made, so a moved caret costs an
    /// unrelated undo rather than lost work.
    static func undoLast() {
        guard canUndo, let last = lastInjection else { return }
        // One undo per injection either way — a second ⌥⌘Z should reach the app, not
        // silently delete another span of the user's text.
        lastInjection = nil

        if removeViaAccessibility(last.text) {
            Log.inject.info("undo: removed \(last.text.count) chars via AX")
        } else {
            Log.inject.info("undo: AX removal unavailable — sending ⌘Z")
            postCommandKey(kVK_ANSI_Z, flags: .maskCommand)
        }
    }

    /// - Returns: `true` only if the injected span was found behind the caret and deleted.
    private static func removeViaAccessibility(_ text: String) -> Bool {
        let systemWide = AXUIElementCreateSystemWide()

        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        ) == .success, let focused else { return false }

        let element = unsafeDowncast(focused as AnyObject, to: AXUIElement.self)

        // AX ranges are in UTF-16 units, so the span length has to be counted the same way
        // — a transcript with an emoji or an accented character would otherwise be off by
        // exactly the number of surrogate pairs it contains.
        let length = text.utf16.count
        guard let caret = selectedRange(of: element) else { return false }

        // A non-empty selection means the user has selected something since; deleting the
        // span behind it would throw away a different piece of text than the one we wrote.
        guard caret.length == 0, caret.location >= length else { return false }

        let span = CFRange(location: caret.location - length, length: length)
        guard let spanValue = AXValueCreate(.cfRange, withUnsafePointer(to: span) { $0 }) else {
            return false
        }

        guard AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            spanValue
        ) == .success else { return false }

        // Confirm the selection actually reads back as what we injected before deleting it.
        // Everything above can succeed in an app that quietly ignores range writes, and
        // this is the step that catches it.
        var selected: CFTypeRef?
        let readBack = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &selected
        )
        guard readBack == .success, (selected as? String) == text else {
            // Put the caret back where it was rather than leaving a stray selection.
            restoreCaret(to: caret, in: element)
            return false
        }

        guard AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            "" as CFString
        ) == .success else {
            restoreCaret(to: caret, in: element)
            return false
        }

        return true
    }

    private static func restoreCaret(to range: CFRange, in element: AXUIElement) {
        guard let value = AXValueCreate(.cfRange, withUnsafePointer(to: range) { $0 }) else { return }
        AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value)
    }

    private enum AXOutcome {
        case inserted
        case unverified(String)
    }

    // MARK: - Strategy 1: Accessibility, verified

    private static func insertViaAccessibility(_ text: String) -> AXOutcome {
        let systemWide = AXUIElementCreateSystemWide()

        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        ) == .success, let focused else {
            return .unverified("no focused element")
        }

        let element = unsafeDowncast(focused as AnyObject, to: AXUIElement.self)

        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(
            element,
            kAXSelectedTextAttribute as CFString,
            &settable
        ) == .success, settable.boolValue else {
            return .unverified("selected text not settable")
        }

        // Without a readable insertion point there's no way to tell a real insert from a
        // silently-dropped one, so don't gamble — go straight to the fallback.
        guard let before = selectedRange(of: element) else {
            return .unverified("no readable selection range")
        }

        guard AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFString
        ) == .success else {
            return .unverified("set attribute failed")
        }

        guard let after = selectedRange(of: element) else {
            return .unverified("selection range unreadable after write")
        }

        // Deliberately a *movement* check, not an exact-length check. Falling back after a
        // write that actually landed would paste the text a second time, and a duplicated
        // paragraph is far worse than a missing one. Some apps normalize newlines or run
        // autocorrect, so the caret can legitimately advance by something other than the
        // UTF-16 count — only a completely unmoved selection proves nothing happened.
        let unchanged = after.location == before.location && after.length == before.length
        guard !unchanged else {
            return .unverified("selection unmoved at \(before.location)")
        }

        return .inserted
    }

    private static func selectedRange(of element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &value
        ) == .success, let value else { return nil }

        let axValue = unsafeDowncast(value as AnyObject, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else { return nil }

        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return range
    }

    // MARK: - Strategy 2: Pasteboard + ⌘V

    private static func insertViaPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.pasteboardItems?.compactMap { item -> [NSPasteboard.PasteboardType: Data] in
            var copy: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { copy[type] = data }
            }
            return copy
        }

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        Task { @MainActor in
            // Give the target app a moment to observe the new pasteboard generation before
            // ⌘V arrives, or a fast paste can grab the *previous* contents.
            try? await Task.sleep(for: .milliseconds(40))
            postCommandV()
            Log.inject.info("pasted (\(text.count) chars)")

            // The paste is asynchronous in the target app; restore only once it's had time
            // to read the pasteboard.
            try? await Task.sleep(for: .milliseconds(500))
            restore(saved, to: pasteboard)
        }
    }

    private static func postCommandV() {
        postCommandKey(kVK_ANSI_V, flags: .maskCommand)
    }

    private static func postCommandKey(_ key: Int, flags: CGEventFlags) {
        guard let source = CGEventSource(stateID: .privateState) else { return }
        let code = CGKeyCode(key)

        guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
        else { return }

        // Set explicitly rather than inheriting live hardware modifier state — the user may
        // still be resting a finger on something. For undo this is load-bearing: ⌥⌘Z is
        // physically held as the chord is sent, and passing ⌥ along would turn the ⌘Z we
        // are synthesizing back into ⌥⌘Z.
        down.flags = flags
        up.flags = flags

        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private static func restore(
        _ saved: [[NSPasteboard.PasteboardType: Data]]?,
        to pasteboard: NSPasteboard
    ) {
        guard let saved, !saved.isEmpty else { return }
        pasteboard.clearContents()
        let items = saved.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(items)
    }
}
