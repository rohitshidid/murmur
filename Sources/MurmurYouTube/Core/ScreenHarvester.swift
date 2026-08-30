import AppKit
import ApplicationServices
import Foundation

/// Reads the text visible in the frontmost app, so a transcript can be checked against
/// what you were actually looking at.
///
/// Uses the Accessibility grant the app already holds for the hotkey and text insertion —
/// no new permission. That choice has a known limit worth stating plainly: **Electron apps
/// expose a sparse AX tree.** In VS Code, Cursor and their forks you can reliably read the
/// window title (which carries the current filename) but often not the code in the buffer.
/// Native apps, Xcode, and most editors' file trees and tab bars read fully.
///
/// Nothing here is stored. The strings are harvested, matched against one transcript, and
/// dropped.
enum ScreenHarvester {
    /// Hard limits on the walk.
    ///
    /// An AX tree is unbounded in principle and pathological in practice — a long document
    /// or a large file tree is tens of thousands of nodes — so the walk stops at whichever
    /// of these it hits first rather than trying to be complete.
    private static let nodeBudget = 1_200
    private static let maxDepth = 14
    private static let deadline: TimeInterval = 0.35

    /// How long to wait on any single AX call.
    ///
    /// Load-bearing. Without it, one unresponsive app blocks the calling thread for
    /// *seconds* — and this runs in the window between releasing the key and text
    /// appearing, which is the latency the whole app is judged on.
    private static let messagingTimeout: Float = 0.15

    /// - Parameter pid: the app to read, captured on the main actor by the caller. Passed
    ///   in rather than looked up here so this can run off the main actor without touching
    ///   `NSWorkspace`.
    /// - Returns: strings visible in that app, unordered and unfiltered.
    static func visibleText(pid: pid_t) -> [String] {
        guard AXIsProcessTrusted() else { return [] }

        // Never read our own tree. Accessibility against another process is IPC and safe
        // from any thread — but against *this* process it is an in-process call that makes
        // AppKit build the tree synchronously on the calling thread, which evaluates
        // SwiftUI view bodies off the main actor and traps immediately.
        //
        // This is reachable from the Record button, not some edge case: clicking a control
        // in Murmur's own window makes Murmur the frontmost app, so the harvest targets
        // itself. There is nothing here worth harvesting either.
        guard pid != getpid() else {
            Log.speech.info("screen context: skipped — Murmur is frontmost")
            return []
        }

        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, messagingTimeout)

        var found: [String] = []
        var visited = 0
        let started = Date()

        // The window title first and separately: in an Electron editor it is often the only
        // thing readable, and it is also the single most valuable string — it names the file
        // you are looking at.
        if let window = copy(element, kAXFocusedWindowAttribute) {
            let windowElement = unsafeDowncast(window as AnyObject, to: AXUIElement.self)
            AXUIElementSetMessagingTimeout(windowElement, messagingTimeout)

            if let title = string(windowElement, kAXTitleAttribute) {
                found.append(title)
            }
            walk(windowElement, depth: 0, visited: &visited, started: started, into: &found)
        }

        // The focused element's own text, which is the one thing an Electron editor will
        // sometimes hand over when the tree walk finds nothing.
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, messagingTimeout)
        if let focused = copy(systemWide, kAXFocusedUIElementAttribute) {
            let focusedElement = unsafeDowncast(focused as AnyObject, to: AXUIElement.self)
            AXUIElementSetMessagingTimeout(focusedElement, messagingTimeout)
            for attribute in [kAXValueAttribute, kAXSelectedTextAttribute, kAXTitleAttribute] {
                if let text = string(focusedElement, attribute) { found.append(text) }
            }
        }

        Log.speech.info("screen context: \(found.count, privacy: .public) string(s), \(visited, privacy: .public) node(s)")
        return found
    }

    // MARK: - Walk

    private static func walk(
        _ element: AXUIElement,
        depth: Int,
        visited: inout Int,
        started: Date,
        into found: inout [String]
    ) {
        guard depth < maxDepth,
              visited < nodeBudget,
              Date().timeIntervalSince(started) < deadline
        else { return }

        visited += 1

        for attribute in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
            if let text = string(element, attribute), !text.isEmpty {
                found.append(text)
            }
        }

        guard let children = copy(element, kAXChildrenAttribute) as? [AXUIElement] else { return }
        for child in children {
            walk(child, depth: depth + 1, visited: &visited, started: started, into: &found)
        }
    }

    // MARK: - AX helpers

    private static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    /// Only genuine strings. An `AXValue` here is a size or a range, not text.
    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        guard let value = copy(element, attribute) as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // A whole document arriving as one string is common; the tokenizer only needs
        // enough to find identifiers in.
        return String(trimmed.prefix(20_000))
    }
}
