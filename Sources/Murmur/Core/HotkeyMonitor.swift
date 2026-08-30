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
///
/// **Not `@MainActor`, and the `refcon` is retained.** Both details are load-bearing, and
/// both come from the same crash: repeated `SIGSEGV`s inside the runtime's executor lookup,
/// reached from this callback. The tap's `refcon` was `passUnretained`, which keeps nothing
/// alive — so the callback could resurrect a pointer to a monitor the runtime no longer
/// considered valid, and the first thing to touch it died. It is now `passRetained` and
/// balanced in `stop()`.
///
/// With that fixed the callback also no longer reaches into actor-isolated state at all: it
/// decides whether to swallow the event under a plain lock, and hops to the main queue only
/// to deliver the press and release. `DispatchQueue.main.async` rather than
/// `Task { @MainActor in }` because the main queue is FIFO — a press can never arrive after
/// the release that followed it, and a swapped pair would leave the mic open forever.
final class HotkeyMonitor: @unchecked Sendable {
    /// Guards every field the tap callback touches. Held only across field access, never
    /// across a callback into the app.
    private let lock = NSLock()

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// The retain balancing `passRetained`, released when the tap goes away.
    private var refcon: Unmanaged<HotkeyMonitor>?

    private var isPressed = false
    private var pressedAt: Date?
    /// Set when a press was consumed to end a latched session, so the release that follows
    /// it isn't read as a fresh tap and immediately re-latches.
    private var ignoreNextRelease = false
    private var isLatchedStorage = false

    private var keyStorage: PushToTalkKey = .rightCommand
    private var latchOnTapStorage = true
    private var onPressStorage: (@Sendable () -> Void)?
    private var onReleaseStorage: (@Sendable () -> Void)?
    private var onLatchChangeStorage: (@Sendable (Bool) -> Void)?

    /// A press shorter than this is a *tap*; anything longer is a hold.
    ///
    /// Tuned to sit above a deliberate quick tap and well below the shortest useful
    /// utterance — nobody dictates a word in under a third of a second, so a press this
    /// short is a gesture, not speech.
    private static let tapThreshold: TimeInterval = 0.35

    var key: PushToTalkKey {
        get { lock.withLock { keyStorage } }
        set { lock.withLock { keyStorage = newValue } }
    }

    /// Whether a quick tap latches recording on. Mirrors `Settings.latchOnTap`.
    var latchOnTap: Bool {
        get { lock.withLock { latchOnTapStorage } }
        set { lock.withLock { latchOnTapStorage = newValue } }
    }

    /// True while a tap has locked recording on. Read by the HUD.
    var isLatched: Bool { lock.withLock { isLatchedStorage } }

    var onPress: (@Sendable () -> Void)? {
        get { lock.withLock { onPressStorage } }
        set { lock.withLock { onPressStorage = newValue } }
    }

    var onRelease: (@Sendable () -> Void)? {
        get { lock.withLock { onReleaseStorage } }
        set { lock.withLock { onReleaseStorage = newValue } }
    }

    /// Fired whenever `isLatched` changes, so the HUD can show the locked state.
    var onLatchChange: (@Sendable (Bool) -> Void)? {
        get { lock.withLock { onLatchChangeStorage } }
        set { lock.withLock { onLatchChangeStorage = newValue } }
    }

    /// - Returns: `false` if the tap couldn't be created — almost always missing Accessibility permission.
    @discardableResult
    func start() -> Bool {
        stop()

        let mask = (1 << CGEventType.flagsChanged.rawValue)
        let retained = Unmanaged.passRetained(self)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()

                // CGEvent isn't Sendable, so the plain values come out here. `handle` is
                // lock-guarded and touches no actor, so there is nothing to assume.
                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                let flags = event.flags
                let consume = monitor.handle(type: type, keyCode: keyCode, flags: flags)
                return consume ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: retained.toOpaque()
        ) else {
            // Balance the retain the tap never took ownership of.
            retained.release()
            Log.hotkey.error("tapCreate failed — Accessibility permission missing?")
            return false
        }

        self.tap = tap
        self.refcon = retained
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        Log.hotkey.info("listening for \(self.key.displayName, privacy: .public)")
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

        // After the source is off the run loop no further callback can arrive, so the
        // retain taken in `start()` can be given back.
        refcon?.release()
        refcon = nil

        clearLatch()
    }

    /// Drops the latch without firing `onRelease`.
    ///
    /// For the paths that end a recording by some route other than the key — an error, a
    /// cancel, the Stop button — after which a latched monitor would otherwise still think
    /// it owned a live session and swallow the next press to "stop" it.
    func clearLatch() {
        let (wasLatched, handler): (Bool, (@Sendable (Bool) -> Void)?) = lock.withLock {
            isPressed = false
            pressedAt = nil
            ignoreNextRelease = false
            let was = isLatchedStorage
            isLatchedStorage = false
            return (was, onLatchChangeStorage)
        }
        guard wasLatched else { return }
        DispatchQueue.main.async { handler?(false) }
    }

    // MARK: - Tap callback

    /// What the event means, decided under the lock and acted on outside it.
    private enum Outcome {
        case ignore
        case press((@Sendable () -> Void)?)
        case release((@Sendable () -> Void)?)
        case latch((@Sendable (Bool) -> Void)?)
        case unlatch((@Sendable (Bool) -> Void)?, (@Sendable () -> Void)?)
    }

    /// - Returns: `true` if the event should be swallowed rather than passed along.
    private func handle(type: CGEventType, keyCode: Int64, flags: CGEventFlags) -> Bool {
        // The system disables a tap that runs too slowly or is interrupted; re-arm it.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        guard type == .flagsChanged else { return false }

        var consume = false
        var outcome = Outcome.ignore

        lock.lock()
        if keyCode == keyStorage.keyCode {
            let nowPressed = flags.contains(keyStorage.flag)
            if nowPressed != isPressed {
                isPressed = nowPressed
                outcome = nowPressed ? keyWentDownLocked() : keyWentUpLocked()
                consume = keyStorage.shouldConsumeEvent
            }
        }
        lock.unlock()

        // Delivered on the main queue, in order, outside the lock.
        switch outcome {
        case .ignore:
            break
        case .press(let handler), .release(let handler):
            DispatchQueue.main.async { handler?() }
        case .latch(let change):
            DispatchQueue.main.async { change?(true) }
        case .unlatch(let change, let release):
            DispatchQueue.main.async {
                change?(false)
                release?()
            }
        }

        return consume
    }

    /// Hold to talk; tap to lock on.
    ///
    /// The two gestures are told apart on *release*, by how long the key was held — which
    /// is what lets push-to-talk stay instant. Deferring the press until a double-tap
    /// window elapsed would put 300ms of latency in front of every utterance, and the
    /// beginning of a sentence is exactly the part you can't afford to clip.
    private func keyWentDownLocked() -> Outcome {
        // While latched, a press is the stop gesture rather than the start of one.
        if isLatchedStorage {
            isLatchedStorage = false
            ignoreNextRelease = true
            return .unlatch(onLatchChangeStorage, onReleaseStorage)
        }
        pressedAt = Date()
        return .press(onPressStorage)
    }

    private func keyWentUpLocked() -> Outcome {
        // The tail of the press that stopped a latched session.
        if ignoreNextRelease {
            ignoreNextRelease = false
            return .ignore
        }

        let held = pressedAt.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        pressedAt = nil

        // A tap keeps the mic open and hands control to the next press. Holding a key for a
        // three-minute thought is the thing that stops people using push-to-talk for
        // anything long.
        if latchOnTapStorage, held < Self.tapThreshold {
            isLatchedStorage = true
            return .latch(onLatchChangeStorage)
        }

        return .release(onReleaseStorage)
    }
}
