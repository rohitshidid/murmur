import MurmurDictionary
import MurmurFormatting
import AVFoundation
import AppKit
import Foundation
import Observation

/// Builds the engine named by the current setting.
///
/// Deliberately at file scope rather than a static on `DictationController`: the class is
/// `@MainActor`, which would make a static method main-actor-isolated and therefore
/// ineligible to be `@Sendable`. Reading the setting per-utterance is what lets the menu's
/// engine picker take effect on the very next hold instead of needing a restart.
@Sendable
func engineForCurrentSetting() -> any TranscriptionEngine {
    // Always invoked from `beginDictation`, which runs on the main actor.
    MainActor.assumeIsolated {
        switch Settings.shared.engine {
        case .apple: AppleSpeechEngine()
        case .parakeet: ParakeetEngine()
        }
    }
}

@MainActor
@Observable
final class DictationController {
    enum State: Equatable {
        case idle
        case starting
        case listening
        case finishing
        case error(String)

        var isActive: Bool {
            switch self {
            case .starting, .listening, .finishing: true
            case .idle, .error: false
            }
        }
    }

    /// What the current hold is for.
    ///
    /// Both modes record through the same capture, engine and HUD — the only thing that
    /// differs is what happens to the words on release. Dictation types them; Command Mode
    /// reads them as an instruction and applies it to text the user had already selected.
    enum Mode: Equatable {
        case dictation
        case command
    }

    /// A short line the HUD shows after a hold ends: what was done, or why nothing was.
    ///
    /// Separate from `state` on purpose. A notice has to outlive the session that produced
    /// it — the user is reading it after the key is up — but it must not make the controller
    /// look busy, because `beginDictation` refuses to start while anything is active. Held
    /// as its own value, the HUD can linger for two seconds without blocking the next hold.
    struct Banner: Equatable {
        let text: String
        let isError: Bool
    }

    private(set) var state: State = .idle
    private(set) var mode: Mode = .dictation
    private(set) var banner: Banner?
    /// Live transcript, updated as the engine revises it. Drives the HUD.
    private(set) var transcript = ""
    /// Smoothed 0…1 mic level for the waveform.
    private(set) var level: Float = 0

    /// True while a tap has locked the mic open. Drives the HUD's lock indicator.
    private(set) var isLatched = false

    /// Whether the push-to-talk event tap is actually installed.
    ///
    /// Observable because the app used to fail silently here: `tapCreate` returns nil
    /// without Accessibility, the failure went to the log, and the app then announced
    /// itself ready. The key did nothing and nothing on screen said why — which reads as a
    /// broken app rather than an ungranted one.
    private(set) var isHotkeyArmed = false

    /// Whether the Command Mode tap is installed. False whenever the feature is switched
    /// off, bound to the dictation key, or the tap itself failed.
    private(set) var isCommandKeyArmed = false

    private let hotkey = HotkeyMonitor()
    private let commandHotkey = HotkeyMonitor()
    private let shortcuts = ShortcutMonitor()
    private let capture = AudioCapture()
    private let makeEngine: @Sendable () -> any TranscriptionEngine

    /// Injected only by tests; production reads the setting per-utterance below.
    private let formatter: (any TextFormatter)?

    /// When the current capture began, and what it was started with — kept so a device
    /// change arriving moments later can restart it rather than end the utterance.
    private var captureStartedAt: Date?
    private var captureFormat: AVAudioFormat?
    /// One restart per utterance. A device that changes twice is genuinely changing.
    private var didRestartCapture = false

    /// How long after capture opens a device change is treated as the input settling.
    ///
    /// Measured: on a Mac with a Bluetooth device attached, the change lands ~130ms after
    /// `capture.start` returns. The window is wide enough to cover that and short enough
    /// that unplugging a headset mid-sentence still ends the utterance, which is what
    /// should happen — the audio really is gone.
    private static let captureSettleWindow: TimeInterval = 0.75

    /// Chosen per-utterance so the menu toggle applies to the very next hold.
    private var activeFormatter: any TextFormatter {
        if let formatter { return formatter }
        return Settings.shared.smartCleanup
            ? FoundationModelFormatter()
            : RuleBasedFormatter()
    }

    private var engine: (any TranscriptionEngine)?
    private var consumeTask: Task<Void, Never>?
    private var feedTask: Task<Void, Never>?
    private var audioContinuation: AsyncStream<AudioChunk>.Continuation?

    /// The text that was highlighted when the command key went down.
    ///
    /// Captured at key-down and confirmed again immediately before injection. The gap
    /// between them is seconds long — transcription plus a model call — and a selection does
    /// not reliably survive that.
    private var commandSelection: String?
    private var bannerTask: Task<Void, Never>?

    /// Timestamps for the history list: when the key went down, and when it came up.
    private var holdStarted: Date?
    private var releasedAt: Date?
    private var engineName = ""


    init(
        formatter: (any TextFormatter)? = nil,
        makeEngine: @escaping @Sendable () -> any TranscriptionEngine = engineForCurrentSetting
    ) {
        self.formatter = formatter
        self.makeEngine = makeEngine
    }

    // MARK: - Lifecycle

    /// Ends the current utterance when the audio hardware changes mid-recording.
    ///
    /// Capture is already gone by the time this runs; this exists so the state machine and
    /// the HUD don't sit waiting for audio that will never arrive.
    private func handleAudioConfigurationChange() {
        guard state.isActive else { return }

        // A change this soon after capture opened is the input settling, not the user
        // unplugging anything — so ending the utterance costs them a sentence they had
        // already started saying. Restart capture into the same stream instead; the engine
        // never sees the seam, because the continuation it is draining is unchanged.
        if !didRestartCapture,
           let startedAt = captureStartedAt,
           Date().timeIntervalSince(startedAt) < Self.captureSettleWindow,
           restartCapture() {
            didRestartCapture = true
            Log.audio.info("audio device settled after capture opened — restarted rather than cancelled")
            return
        }

        Log.audio.info("audio device changed mid-utterance — cancelling")
        fail("Audio device changed. Give it a moment and try again.")
    }

    /// - Returns: whether capture is running again.
    ///
    /// Deliberately reuses `audioContinuation`: the buffers have to keep arriving in the
    /// same stream the feed task is draining, or the restart would reorder the utterance
    /// instead of repairing it.
    private func restartCapture() -> Bool {
        guard let format = captureFormat, let continuation = audioContinuation else { return false }
        do {
            try capture.start(
                outputFormat: format,
                deviceID: AudioDevices.device(uid: Settings.shared.inputDeviceUID)?.id,
                onBuffer: { chunk in continuation.yield(chunk) },
                onLevel: { [weak self] level in
                    Task { @MainActor in self?.updateLevel(level) }
                }
            )
            captureStartedAt = Date()
            return true
        } catch {
            Log.audio.error("capture restart failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Installs both event taps.
    ///
    /// - Returns: `false` if the push-to-talk tap couldn't be installed (missing
    ///   Accessibility). Command Mode's tap is reported separately in `isCommandKeyArmed`,
    ///   because it can legitimately be off while dictation works fine.
    @discardableResult
    func activate() -> Bool {
        hotkey.key = Settings.shared.pushToTalkKey
        hotkey.latchOnTap = Settings.shared.latchOnTap
        // `assumeIsolated` is sound here specifically because `HotkeyMonitor` delivers
        // these on `DispatchQueue.main`. It is not what was crashing: the tap's `refcon`
        // was unretained, so the callback could revive a stale pointer, and the executor
        // check was simply the first thing to touch it.
        hotkey.onPress = { [weak self] in
            MainActor.assumeIsolated { self?.beginDictation() }
        }
        hotkey.onRelease = { [weak self] in
            MainActor.assumeIsolated { self?.endHold(for: .dictation) }
        }
        hotkey.onLatchChange = { [weak self] latched in
            MainActor.assumeIsolated { self?.isLatched = latched }
        }

        // Command Mode's own tap. Same delivery contract as the one above — `HotkeyMonitor`
        // hands both of these over on `DispatchQueue.main` — and deliberately never latched:
        // a latched command key would sit holding a selection that has long since moved on.
        commandHotkey.key = Settings.shared.commandKey
        commandHotkey.latchOnTap = false
        commandHotkey.onPress = { [weak self] in
            MainActor.assumeIsolated { self?.beginCommand() }
        }
        commandHotkey.onRelease = { [weak self] in
            MainActor.assumeIsolated { self?.endHold(for: .command) }
        }

        shortcuts.onUndo = { MainActor.assumeIsolated { TextInjector.undoLast() } }

        capture.onConfigurationChange = { [weak self] in
            MainActor.assumeIsolated { self?.handleAudioConfigurationChange() }
        }
        // Both taps need the same grant, so a failure here is the same failure — reported
        // once, by the push-to-talk tap, which is the one the user is waiting on.
        shortcuts.start()

        isHotkeyArmed = hotkey.start()

        // Refused rather than merely discouraged when the two keys collide: both taps would
        // fire on the same press, in an unspecified order, and the second session would be
        // dropped by the `.idle` guard with nothing on screen saying why.
        commandHotkey.stop()
        if Settings.shared.commandModeIsUsable {
            isCommandKeyArmed = commandHotkey.start()
        } else {
            isCommandKeyArmed = false
            if Settings.shared.commandModeEnabled {
                Log.hotkey.error("command mode is bound to the push-to-talk key — not armed")
            }
        }

        return isHotkeyArmed
    }

    func deactivate() {
        isHotkeyArmed = false
        isCommandKeyArmed = false
        hotkey.stop()
        commandHotkey.stop()
        shortcuts.stop()
        cancelDictation()
    }

    /// Re-arms the tap after the user picks a different push-to-talk key.
    @discardableResult
    func reloadHotkey() -> Bool {
        hotkey.stop()
        commandHotkey.stop()
        shortcuts.stop()
        return activate()
    }

    // MARK: - Button-driven recording

    /// Starts a recording from a Record button rather than the hotkey.
    ///
    func startButtonRecording() {
        guard case .idle = state else { return }
        // The button is always ordinary dictation, whatever the last hold was for.
        mode = .dictation
        commandSelection = nil
        clearBanner()
        beginDictation()
    }

    func stopButtonRecording() {
        hotkey.clearLatch()
        isLatched = false
        endDictation()
    }

    // MARK: - Command Mode

    /// Ends a hold only if it is the one that started the session in progress.
    ///
    /// Two keys can now be held, and only one session can exist. Press push-to-talk, then
    /// tap the command key while still talking: the command key's press is refused by the
    /// idle guard, but its *release* used to end the dictation mid-sentence — the key that
    /// did nothing on the way down cut the utterance short on the way up. Whichever mode the
    /// live session belongs to is the only key allowed to finish it.
    private func endHold(for mode: Mode) {
        guard self.mode == mode else { return }
        endDictation()
    }

    /// Starts a hold that will act on the selected text rather than type new text.
    ///
    /// The selection is read **here**, at key-down, and that is the whole design. "Make this
    /// more formal" is a sentence with an object, and the object is whatever was highlighted
    /// when the user reached for the key — not whatever is highlighted several seconds later,
    /// after they have finished talking and a model has finished thinking. Reading it late
    /// would mean occasionally rewriting something the user never pointed at.
    ///
    /// Nothing selected is a refusal with a reason, never a silent no-op. The alternative —
    /// falling through to ordinary dictation — types "rephrase this more formally" into the
    /// document, which is the one outcome nobody would ever want.
    private func beginCommand() {
        guard case .idle = state else { return }

        switch SelectionReader.read() {
        case .success(let selection):
            commandSelection = selection
            mode = .command
            clearBanner()
            beginDictation()
        case .failure(let reason):
            Log.speech.info("command mode: \(String(describing: reason), privacy: .public)")
            show(reason.message, isError: true)
        }
    }

    /// Applies the spoken instruction to the captured selection.
    private func finishCommand(instruction: String) async {
        defer {
            mode = .dictation
            commandSelection = nil
            state = .idle
            transcript = ""
        }

        guard let selection = commandSelection else {
            show("Nothing selected — highlight some text first", isError: true)
            return
        }

        let context = FormatContext.current()
        do {
            let outcome = try await CommandTransformer().transform(
                selection: selection,
                instruction: instruction,
                context: context
            )

            // The last gate before the user's text is replaced. Everything between the key
            // going down and this line is asynchronous, and any of it gives them time to
            // click elsewhere — at which point `TextInjector` would overwrite a different
            // selection with a rewrite of the old one, losing text that has no undo.
            guard SelectionReader.stillHolds(selection) else {
                Log.speech.info("command mode: selection moved before injection — nothing replaced")
                show("Selection changed — nothing was replaced", isError: true)
                return
            }

            recordRun(text: outcome.text)
            TextInjector.insert(outcome.text)
            if Settings.shared.soundEnabled { NSSound(named: "Pop")?.play() }
            show(outcome.attribution)
            Log.speech.info("command · \(outcome.attribution, privacy: .public)")
        } catch {
            let message = error.errorDescription ?? "Rewrite failed"
            Log.speech.info("command failed: \(message, privacy: .public)")
            show(message, isError: true)
        }
    }

    // MARK: - Banner

    /// How long a notice stays on screen after the key comes up.
    ///
    /// Long enough to read "Rewritten with Apple Intelligence" without being long enough to
    /// still be there when the next thought arrives.
    private static let bannerDuration: Duration = .seconds(2.4)

    private func show(_ text: String, isError: Bool = false) {
        bannerTask?.cancel()
        banner = Banner(text: text, isError: isError)
        bannerTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.bannerDuration)
            guard !Task.isCancelled else { return }
            self?.banner = nil
        }
    }

    private func clearBanner() {
        bannerTask?.cancel()
        bannerTask = nil
        banner = nil
    }

    // MARK: - Dictation

    private func beginDictation() {
        guard case .idle = state else { return }
        clearBanner()
        state = .starting
        transcript = ""
        holdStarted = Date()
        engineName = Settings.shared.engine.displayName

        Task { @MainActor in
            do {
                guard await Permissions.requestMicrophone() else {
                    fail("Microphone access is off. Enable it in System Settings ▸ Privacy & Security ▸ Microphone.")
                    return
                }

                let engine = makeEngine()
                self.engine = engine

                let chunks = try await engine.start()

                guard let format = await engine.preferredInputFormat() else {
                    throw TranscriptionError.noAudioFormat
                }

                // Audio must reach the engine in capture order. A stream plus a single
                // draining task guarantees that; spawning a Task per buffer would not.
                let (audioStream, audioContinuation) = AsyncStream<AudioChunk>.makeStream(
                    bufferingPolicy: .bufferingNewest(64)
                )
                self.audioContinuation = audioContinuation

                // Audio must reach the engine in capture order, which is what the single
                // draining task guarantees.
                self.feedTask = Task.detached(priority: .userInitiated) {
                    for await chunk in audioStream {
                        await engine.feed(chunk)
                    }
                }

                self.captureFormat = format
                self.didRestartCapture = false
                try capture.start(
                    outputFormat: format,
                    deviceID: AudioDevices.device(uid: Settings.shared.inputDeviceUID)?.id,
                    onBuffer: { chunk in
                        audioContinuation.yield(chunk)
                    },
                    onLevel: { [weak self] level in
                        Task { @MainActor in self?.updateLevel(level) }
                    }
                )
                self.captureStartedAt = Date()

                // Bail out if the user already let go while we were spinning up.
                guard case .starting = self.state else {
                    await self.teardown()
                    return
                }

                self.state = .listening
                if Settings.shared.soundEnabled { NSSound(named: "Tink")?.play() }

                self.consumeTask = Task { @MainActor in
                    do {
                        for try await chunk in chunks {
                            self.transcript = chunk.text
                        }
                    } catch {
                        self.fail(error.localizedDescription)
                    }
                }
            } catch {
                self.fail(error.localizedDescription)
            }
        }
    }

    private func endDictation() {
        // `.finishing` is "active", so without this a second press during processing would
        // run the whole tail again — re-reading `transcript` before the first pass cleared
        // it and pasting the same utterance twice. The window is wide: Parakeet transcribes
        // inside `finish()`, and smart cleanup adds up to 4s on top.
        guard state.isActive, state != .finishing else { return }
        state = .finishing
        capture.stop()
        level = 0
        releasedAt = Date()

        // Both Accessibility reads are kicked off here, not where their results are used, so
        // they overlap transcription and cleanup instead of adding to the wait. The pid is
        // read on this actor; neither read may touch AppKit.
        //
        // Neither runs in Command Mode. They exist to shape text being *typed* — which field
        // it lands in, what is above the caret, what words are on screen — and Command Mode
        // types nothing new: it replaces a selection the user already made. Running them
        // would be two Accessibility walks bought for nothing, in front of a model call the
        // user is already waiting on.
        let isCommand = mode == .command
        let frontmost = NSWorkspace.shared.frontmostApplication
        let pid = frontmost?.processIdentifier
        let bundleID = frontmost?.bundleIdentifier

        let screenTask: Task<[(hear: String, write: String)], Never>? =
            !isCommand && Settings.shared.screenContext
            ? Task.detached(priority: .userInitiated) {
                guard let pid else { return [] }
                return ScreenVocabulary.pairs(from: ScreenHarvester.visibleText(pid: pid))
            }
            : nil

        let fieldTask: Task<FieldSnapshot, Never>? =
            !isCommand && Settings.shared.fieldContext
            ? Task.detached(priority: .userInitiated) {
                guard let pid else { return .unknown }
                return FieldHarvester.snapshot(pid: pid, bundleID: bundleID)
            }
            : nil

        Task { @MainActor in
            // Drain every captured buffer into the engine before asking it to finalize,
            // or the tail of the utterance gets dropped.
            audioContinuation?.finish()
            audioContinuation = nil
            await feedTask?.value
            feedTask = nil

            await engine?.finish()
            await consumeTask?.value
            consumeTask = nil
            engine = nil


            let raw = transcript
            guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                if isCommand { show("Didn\u{2019}t catch an instruction", isError: true) }
                mode = .dictation
                commandSelection = nil
                state = .idle
                transcript = ""
                return
            }

            // Command Mode leaves the pipeline here. Everything below shapes a transcript
            // into text for a field — cleanup, lists, email shape, the dictionary — and none
            // of it applies to a sentence that is an instruction rather than content. Running
            // the dictionary over "make this more formal" would correct words in a string
            // nobody will ever read.
            if isCommand {
                await finishCommand(instruction: raw)
                return
            }

            // Resolved here rather than when the key went down: this is the moment before
            // injection, so the app it reads is the app the text is actually going into.
            let field = await fieldTask?.value ?? .unknown
            let context = FormatContext.current(field: field)
            let options = context.structureOptions

            // The structure pass runs in two halves around cleanup. Retraction and spoken
            // commands need the words exactly as spoken — a cleanup model tidies "scratch
            // that" into prose — while lists and email shape need the final punctuation and
            // capitalization that cleanup produces.
            let pre = StructurePass.preClean(raw, options: options)
            if pre.didRetract {
                Log.speech.info("retraction · \(pre.retracted.count, privacy: .public) span(s) taken back")
            }

            // An utterance of nothing but commands — a stray "new paragraph" — reduces to an
            // empty string, and injecting that means an empty pasteboard paste into the
            // user's document.
            guard !pre.text.isEmpty else {
                state = .idle
                transcript = ""
                return
            }

            let cleaned = Settings.shared.cleanupEnabled
                ? await activeFormatter.format(pre.text, context: context)
                : pre.text
            let structured = StructurePass.structure(cleaned, options: options)

            // The dictionary runs last, and runs regardless of the cleanup setting. Biasing
            // only raises the odds of the right word; this is the pass that guarantees it,
            // so it must not be something the user can accidentally switch off.
            var (output, corrections) = DictionaryStore.shared.corrector.apply(to: structured)
            if !corrections.isEmpty {
                Log.speech.info("dictionary · \(corrections.count, privacy: .public) correction(s) applied")
            }

            // Screen context runs *after* the dictionary, so an explicit rule the user
            // wrote always beats a guess made from what happened to be on screen.
            if let screenTask {
                let pairs = await Self.screenPairs(from: screenTask)
                if !pairs.isEmpty {
                    let (screened, hits) = DictionaryCorrector(matching: pairs, reportedAs: .screen)
                        .apply(to: output)
                    if !hits.isEmpty {
                        Log.speech.info("screen · \(hits.count, privacy: .public) match(es) from \(pairs.count, privacy: .public) candidate(s)")
                    }
                    output = screened
                    corrections += hits
                }
            }

            recordRun(text: output, corrections: corrections, retracted: pre.retracted)
            TextInjector.insert(output)
            if Settings.shared.soundEnabled { NSSound(named: "Pop")?.play() }

            state = .idle
            transcript = ""
        }
    }

    private func cancelDictation() {
        hotkey.clearLatch()
        commandHotkey.clearLatch()
        isLatched = false
        mode = .dictation
        commandSelection = nil
        capture.stop()
        audioContinuation?.finish()
        audioContinuation = nil
        feedTask?.cancel()
        feedTask = nil
        consumeTask?.cancel()
        consumeTask = nil

        let engine = self.engine
        self.engine = nil
        Task { await engine?.finish() }

        state = .idle
        transcript = ""
        level = 0
    }

    private func teardown() async {
        mode = .dictation
        commandSelection = nil
        capture.stop()
        audioContinuation?.finish()
        audioContinuation = nil
        await feedTask?.value
        feedTask = nil
        await engine?.finish()
        engine = nil
        consumeTask?.cancel()
        consumeTask = nil
        state = .idle
    }

    // MARK: - Helpers


    /// Files the finished utterance for the history list.
    ///
    /// `processSeconds` is measured from key release, not from capture start — that's the
    /// wait the user actually experiences, and it's the only number on which a streaming
    /// engine and a batch engine can be compared honestly.
    /// - Parameter retracted: spans a retraction erased.
    ///
    ///   Recorded because a retraction that fires on ordinary speech costs the speaker words
    ///   they cannot get back by any other means — the text was never injected, so there is
    ///   nothing to undo. The run log is the only place they still exist.
    private func recordRun(
        text: String,
        corrections: [AppliedCorrection] = [],
        retracted: [String] = []
    ) {
        guard let holdStarted, let releasedAt else { return }
        RunLog.record(
            DictationRun(
                date: releasedAt,
                engine: engineName,
                audioSeconds: releasedAt.timeIntervalSince(holdStarted),
                processSeconds: Date().timeIntervalSince(releasedAt),
                text: text,
                corrections: corrections.isEmpty ? nil : corrections,
                retracted: retracted.isEmpty ? nil : retracted
            )
        )
        self.holdStarted = nil
        self.releasedAt = nil
    }

    /// Awaits the screen harvest, or gives up and abandons it.
    ///
    /// Bounded, not merely expected to be fast. The walk measures in tens of milliseconds
    /// in practice, but it makes synchronous Accessibility calls into another process — and
    /// an unresponsive app is exactly the case where a "usually quick" call stops being
    /// quick. Nothing added for accuracy may hold up text the user has already spoken.
    ///
    /// Deliberately not a `TaskGroup` with a timeout child: a task group awaits **all** its
    /// children before returning, so a child that ignores cancellation keeps blocking past
    /// the deadline and the timeout buys nothing. Racing two continuations and walking away
    /// is the only shape that actually bounds the wait.
    private static func screenPairs(
        from task: Task<[(hear: String, write: String)], Never>
    ) async -> [(hear: String, write: String)] {
        let result: [(hear: String, write: String)]? = await withCheckedContinuation { continuation in
            let gate = ResumeGate(continuation)
            Task { gate.resume(await task.value) }
            Task {
                try? await Task.sleep(for: .milliseconds(400))
                gate.resume(nil)
            }
        }

        if result == nil {
            task.cancel()
            Log.speech.info("screen context timed out — skipped")
        }
        return result ?? []
    }

    /// Resumes a continuation exactly once. Resuming twice traps.
    private final class ResumeGate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<[(hear: String, write: String)]?, Never>?

        init(_ continuation: CheckedContinuation<[(hear: String, write: String)]?, Never>) {
            self.continuation = continuation
        }

        func resume(_ value: [(hear: String, write: String)]?) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: value)
        }
    }

    /// Light smoothing so the waveform glides instead of strobing at buffer rate.
    private func updateLevel(_ new: Float) {
        level += (new - level) * 0.35
    }

    private func fail(_ message: String) {
        Log.app.error("\(message)")
        hotkey.clearLatch()
        commandHotkey.clearLatch()
        isLatched = false
        mode = .dictation
        commandSelection = nil
        capture.stop()
        audioContinuation?.finish()
        audioContinuation = nil
        feedTask?.cancel()
        feedTask = nil
        engine = nil
        consumeTask?.cancel()
        consumeTask = nil
        state = .error(message)
        level = 0

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if case .error = state { state = .idle }
        }
    }
}
