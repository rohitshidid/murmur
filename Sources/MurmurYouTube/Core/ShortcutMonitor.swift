import AppKit
import Carbon.HIToolbox
import Foundation

/// Watches for one chorded shortcut using a `CGEventTap` on `.keyDown`.
///
/// Separate from `HotkeyMonitor` because the two watch genuinely different things:
/// push-to-talk is a bare modifier observed through `.flagsChanged`, where this is an
/// ordinary key pressed *with* modifiers. Folding both into one tap would mean a single
/// callback branching on event type for two unrelated jobs.
///
/// Needs the same Accessibility grant as `HotkeyMonitor`, and gets it for free — if the
/// push-to-talk tap was created, this one will be too.
@MainActor
final class ShortcutMonitor {
    /// ⌥⌘Z — undo the last dictation.
    ///
    /// Chosen to sit next to the undo people already know while staying clear of it: ⌘Z is
    /// the app's own undo and ⇧⌘Z is redo, both of which must keep working. ⌥⌘Z is
    /// unclaimed in every app checked, and being adjacent to ⌘Z makes it guessable.
    static let undoKeyCode = Int64(kVK_ANSI_Z)
    static let undoFlags: CGEventFlags = [.maskCommand, .maskAlternate]

    /// The modifiers that decide whether the chord matched.
    ///
    /// Compared against a *masked* copy of the event flags rather than the raw value:
    /// `CGEventFlags` also carries the numeric-pad and coalesced-state bits, which are set
    /// for reasons that have nothing to do with the user's fingers, so a raw equality test
    /// silently never matches.
    private static let modifierMask: CGEventFlags = [
        .maskCommand, .maskAlternate, .maskShift, .maskControl,
    ]

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    var onUndo: (() -> Void)?

    @discardableResult
    func start() -> Bool {
        stop()

        let mask = (1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<ShortcutMonitor>.fromOpaque(refcon).takeUnretainedValue()

                // CGEvent isn't Sendable — read the plain values out before crossing into
                // actor-isolated code, exactly as HotkeyMonitor does.
                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                let flags = event.flags
                let consume = MainActor.assumeIsolated {
                    monitor.handle(type: type, keyCode: keyCode, flags: flags)
                }
                return consume ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else {
            Log.hotkey.error("shortcut tapCreate failed — Accessibility permission missing?")
            return false
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        Log.hotkey.info("listening for ⌥⌘Z (undo dictation)")
        return true
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
    }

    /// - Returns: `true` if the event should be swallowed rather than passed along.
    private func handle(type: CGEventType, keyCode: Int64, flags: CGEventFlags) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }

        guard type == .keyDown, keyCode == Self.undoKeyCode else { return false }
        guard flags.intersection(Self.modifierMask) == Self.undoFlags else { return false }

        // Only swallow the chord when there's something to undo. Otherwise ⌥⌘Z is passed
        // through to whatever app has focus, which may well have its own use for it.
        guard TextInjector.canUndo else { return false }

        onUndo?()
        return true
    }
}
