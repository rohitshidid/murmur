import MurmurDictionary
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

    private(set) var state: State = .idle
    /// Live transcript, updated as the engine revises it. Drives the HUD.
    private(set) var transcript = ""
    /// Smoothed 0…1 mic level for the waveform.
    private(set) var level: Float = 0

    /// True while a tap has locked the mic open. Drives the HUD's lock indicator.
    private(set) var isLatched = false

    private let hotkey = HotkeyMonitor()
    private let shortcuts = ShortcutMonitor()
    private let capture = AudioCapture()
    private let makeEngine: @Sendable () -> any TranscriptionEngine

    /// Injected only by tests; production reads the setting per-utterance below.
    private let formatter: (any TextFormatter)?

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

    /// - Returns: `false` if the hotkey tap couldn't be installed (missing Accessibility).
    @discardableResult
    /// Ends the current utterance when the audio hardware changes mid-recording.
    ///
    /// Capture is already gone by the time this runs; this exists so the state machine and
    /// the HUD don't sit waiting for audio that will never arrive.
    private func handleAudioConfigurationChange() {
        guard state.isActive else { return }
        Log.audio.info("audio device changed mid-utterance — cancelling")
        fail("Audio device changed. Give it a moment and try again.")
    }

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
            MainActor.assumeIsolated { self?.endDictation() }
        }
        hotkey.onLatchChange = { [weak self] latched in
            MainActor.assumeIsolated { self?.isLatched = latched }
        }

        shortcuts.onUndo = { MainActor.assumeIsolated { TextInjector.undoLast() } }

        capture.onConfigurationChange = { [weak self] in
            MainActor.assumeIsolated { self?.handleAudioConfigurationChange() }
        }
        // Both taps need the same grant, so a failure here is the same failure — reported
        // once, by the push-to-talk tap, which is the one the user is waiting on.
        shortcuts.start()

        return hotkey.start()
    }

    func deactivate() {
        hotkey.stop()
        shortcuts.stop()
        cancelDictation()
    }

    /// Re-arms the tap after the user picks a different push-to-talk key.
    @discardableResult
    func reloadHotkey() -> Bool {
        hotkey.stop()
        shortcuts.stop()
        return activate()
    }

    // MARK: - Button-driven recording

    /// Starts a recording from a Record button rather than the hotkey.
    ///
    func startButtonRecording() {
        guard case .idle = state else { return }
        beginDictation()
    }

    func stopButtonRecording() {
        hotkey.clearLatch()
        isLatched = false
        endDictation()
    }

    // MARK: - Dictation

    private func beginDictation() {
        guard case .idle = state else { return }
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

        // Kicked off here, not where its result is used, so the Accessibility walk overlaps
        // transcription and cleanup instead of adding to the wait. The pid is read on this
        // actor; the walk itself must not touch AppKit.
        let screenTask: Task<[(hear: String, write: String)], Never>? = Settings.shared.screenContext
            ? Task.detached(priority: .userInitiated) { [pid = NSWorkspace.shared.frontmostApplication?.processIdentifier] in
                guard let pid else { return [] }
                return ScreenVocabulary.pairs(from: ScreenHarvester.visibleText(pid: pid))
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
                state = .idle
                transcript = ""
                return
            }

            // Resolved here rather than when the key went down: this is the moment before
            // injection, so the app it reads is the app the text is actually going into.
            let context = FormatContext.current()
            let cleaned = Settings.shared.cleanupEnabled
                ? await activeFormatter.format(raw, context: context)
                : raw

            // The dictionary runs last, and runs regardless of the cleanup setting. Biasing
            // only raises the odds of the right word; this is the pass that guarantees it,
            // so it must not be something the user can accidentally switch off.
            var (output, corrections) = DictionaryStore.shared.corrector.apply(to: cleaned)
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

            recordRun(text: output, corrections: corrections)
            TextInjector.insert(output)
            if Settings.shared.soundEnabled { NSSound(named: "Pop")?.play() }

            state = .idle
            transcript = ""
        }
    }

    private func cancelDictation() {
        hotkey.clearLatch()
        isLatched = false
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
    private func recordRun(text: String, corrections: [AppliedCorrection] = []) {
        guard let holdStarted, let releasedAt else { return }
        RunLog.record(
            DictationRun(
                date: releasedAt,
                engine: engineName,
                audioSeconds: releasedAt.timeIntervalSince(holdStarted),
                processSeconds: Date().timeIntervalSince(releasedAt),
                text: text,
                corrections: corrections.isEmpty ? nil : corrections
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
        isLatched = false
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
