import AppKit
import Carbon.HIToolbox
import Foundation

/// Which modifier key holds the mic open.
enum PushToTalkKey: String, CaseIterable, Sendable {
    case rightOption
    case fn
    case rightCommand

    var keyCode: Int64 {
        switch self {
        case .rightOption: Int64(kVK_RightOption)   // 61
        case .fn: Int64(kVK_Function)               // 63
        case .rightCommand: Int64(kVK_RightCommand) // 54
        }
    }

    /// Device-*dependent* bit for this specific physical key.
    ///
    /// `CGEventFlags.maskAlternate` is the union mask — it's set whenever *either* Option
    /// key is down. Using it means: hold Left ⌥, tap Right ⌥, and the release is invisible
    /// (the union bit is still set by the left key), so `onRelease` never fires. The mic
    /// stays open, the HUD stays up, and the next press is swallowed too.
    ///
    /// These raw values are the NX_DEVICE* masks from IOKit's event system; they carry the
    /// left/right distinction that the public `CGEventFlags` constants discard.
    var flag: CGEventFlags {
        switch self {
        case .rightOption: CGEventFlags(rawValue: 0x40)   // NX_DEVICERALTKEYMASK
        case .rightCommand: CGEventFlags(rawValue: 0x10)  // NX_DEVICERCMDKEYMASK
        case .fn: .maskSecondaryFn                        // no left/right variant exists
        }
    }

    var displayName: String {
        switch self {
        case .rightOption: "Right ⌥"
        case .fn: "fn"
        case .rightCommand: "Right ⌘"
        }
    }

    /// Swallowing `fn` would break fn+arrow, fn+delete and the emoji picker, so we let it
    /// through. Dedicated right-hand modifiers are safe to consume.
    var shouldConsumeEvent: Bool { self != .fn }
}

/// Watches for a held modifier key using a `CGEventTap`.
///
/// A tap is required rather than `NSEvent.addGlobalMonitor` because `fn` and left/right
/// modifier discrimination don't surface through the higher-level APIs. This needs
/// Accessibility permission; without it `CGEvent.tapCreate` returns nil.
@MainActor
final class HotkeyMonitor {
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isPressed = false

    /// When the current press went down, used to tell a tap from a hold.
    private var pressedAt: Date?
    /// Set when a press was consumed to end a latched session, so the release that follows
    /// it isn't read as a fresh tap and immediately re-latches.
    private var ignoreNextRelease = false

    /// A press shorter than this is a *tap*; anything longer is a hold.
    ///
    /// Tuned to sit above a deliberate quick tap and well below the shortest useful
    /// utterance — nobody dictates a word in under a third of a second, so a press this
    /// short is a gesture, not speech.
    private static let tapThreshold: TimeInterval = 0.35

    /// True while a tap has locked recording on. Read by the HUD.
    private(set) var isLatched = false

    var key: PushToTalkKey = .rightCommand
    /// Whether a quick tap latches recording on. Mirrors `Settings.latchOnTap`.
    var latchOnTap = true
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    /// Fired whenever `isLatched` changes, so the HUD can show the locked state.
    var onLatchChange: ((Bool) -> Void)?

    /// - Returns: `false` if the tap couldn't be created — almost always missing Accessibility permission.
    @discardableResult
    func start() -> Bool {
        stop()

        let mask = (1 << CGEventType.flagsChanged.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()

                // CGEvent isn't Sendable, so pull out the plain values before crossing into
                // actor-isolated code. The tap was added to the main run loop, so this
                // callback genuinely does run on the main thread.
                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                let flags = event.flags
                let consume = MainActor.assumeIsolated {
                    monitor.handle(type: type, keyCode: keyCode, flags: flags)
                }
                return consume ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else {
            Log.hotkey.error("tapCreate failed — Accessibility permission missing?")
            return false
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        Log.hotkey.info("listening for \(self.key.displayName)")
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
        isPressed = false
        clearLatch()
    }

    /// Drops the latch without firing `onRelease`.
    ///
    /// For the paths that end a recording by some route other than the key — an error, a
    /// cancel, the Stop button — after which a latched monitor would otherwise still think
    /// it owned a live session and swallow the next press to "stop" it.
    func clearLatch() {
        pressedAt = nil
        ignoreNextRelease = false
        guard isLatched else { return }
        isLatched = false
        onLatchChange?(false)
    }

    // MARK: - Tap callback

    /// - Returns: `true` if the event should be swallowed rather than passed along.
    private func handle(type: CGEventType, keyCode: Int64, flags: CGEventFlags) -> Bool {
        // The system disables a tap that runs too slowly or is interrupted; re-arm it.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }

        guard type == .flagsChanged, keyCode == key.keyCode else { return false }

        let nowPressed = flags.contains(key.flag)
        guard nowPressed != isPressed else { return false }
        isPressed = nowPressed

        if nowPressed { keyWentDown() } else { keyWentUp() }

        return key.shouldConsumeEvent
    }

    /// Hold to talk; tap to lock on.
    ///
    /// The two gestures are told apart on *release*, by how long the key was held — which
    /// is what lets push-to-talk stay instant. Deferring `onPress` until a double-tap
    /// window elapsed would put 300ms of latency in front of every utterance, and the
    /// beginning of a sentence is exactly the part you can't afford to clip.
    private func keyWentDown() {
        // While latched, a press is the stop gesture rather than the start of one.
        if isLatched {
            isLatched = false
            ignoreNextRelease = true
            onLatchChange?(false)
            onRelease?()
            return
        }

        pressedAt = Date()
        onPress?()
    }

    private func keyWentUp() {
        // The tail of the press that stopped a latched session.
        if ignoreNextRelease {
            ignoreNextRelease = false
            return
        }

        let held = pressedAt.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        pressedAt = nil

        // A tap keeps the mic open and hands control to the next press. Holding a key for a
        // three-minute thought is the thing that stops people using push-to-talk for
        // anything long.
        if latchOnTap, held < Self.tapThreshold {
            isLatched = true
            onLatchChange?(true)
            return
        }

        onRelease?()
    }
}
