import AVFoundation
import FluidAudio
import Foundation
import Observation

/// Records a meeting from two sources at once and turns it into an attributed transcript.
///
/// **Two tracks, not one mix.** The microphone is you; the system audio is everyone else.
/// Keeping them apart means "you" is attributed for free and exactly, and the diarizer only
/// has to separate the remote voices from each other — a much easier problem than pulling
/// your own voice out of a mixdown where it is also the loudest thing present.
///
/// Nothing is injected into any app. A meeting produces a document.
@MainActor
@Observable
final class MeetingRecorder {
    enum State: Equatable {
        case idle
        case recording
        /// Carries a 0…1 progress estimate for the transcription pass.
        case transcribing(Double)
        case error(String)

        var isRecording: Bool { self == .recording }
        var isBusy: Bool {
            switch self {
            case .recording, .transcribing: true
            case .idle, .error: false
            }
        }
    }

    private(set) var state: State = .idle
    /// Seconds recorded so far, for the panel's clock.
    private(set) var elapsed: TimeInterval = 0
    private(set) var level: Float = 0

    private let mic = AudioCapture()
    private let system = SystemAudioCapture()
    private let tracks = TrackBuffers()

    private var startedAt: Date?
    private var ticker: Task<Void, Never>?

    /// Parakeet's rate, and the diarizer's. Everything is normalized to it at capture.
    private static let sampleRate: Double = 16_000

    private static var captureFormat: AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )
    }

    // MARK: - Recording

    func start() {
        guard case .idle = state else { return }
        guard let format = Self.captureFormat else {
            state = .error("Couldn't build the capture format.")
            return
        }

        tracks.reset()

        Task { @MainActor in
            guard await Permissions.requestMicrophone() else {
                state = .error("Microphone access is off. Enable it in System Settings ▸ Privacy & Security ▸ Microphone.")
                return
            }

            do {
                // System audio first: it is the one that can fail on permissions, and
                // failing before the mic is running avoids a half-started recording.
                try system.start(outputFormat: format) { [tracks] samples in
                    tracks.appendSystem(samples)
                }

                try mic.start(
                    outputFormat: format,
                    onBuffer: { [tracks] chunk in tracks.appendMic(chunk.buffer) },
                    onLevel: { [weak self] level in
                        Task { @MainActor in self?.level = level }
                    }
                )
            } catch {
                system.stop()
                mic.stop()
                state = .error(error.localizedDescription)
                return
            }

            startedAt = Date()
            state = .recording
            startTicking()
            Log.audio.info("meeting recording started")
        }
    }

    /// Stops capture and transcribes. The meeting is saved when it completes.
    func stop() {
        guard state.isRecording else { return }

        mic.stop()
        system.stop()
        ticker?.cancel()
        ticker = nil
        level = 0

        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? elapsed
        let started = startedAt ?? Date()
        startedAt = nil
        state = .transcribing(0)

        let micSamples = tracks.micSamples()
        let systemSamples = tracks.systemSamples()
        tracks.reset()

        Task { @MainActor in
            do {
                let segments = try await Self.transcribe(
                    mic: micSamples,
                    system: systemSamples,
                    onProgress: { [weak self] progress in
                        Task { @MainActor in self?.state = .transcribing(progress) }
                    }
                )

                let meeting = Meeting(
                    date: started,
                    title: Self.defaultTitle(for: started),
                    duration: duration,
                    segments: segments
                )
                MeetingStore.shared.save(meeting)
                state = .idle
                Log.speech.info("meeting transcribed — \(segments.count) segments")
            } catch {
                state = .error(error.localizedDescription)
                Log.speech.error("meeting transcription failed: \(error.localizedDescription)")
                Task {
                    try? await Task.sleep(for: .seconds(4))
                    await MainActor.run { if case .error = self.state { self.state = .idle } }
                }
            }
        }
    }

    private func startTicking() {
        ticker = Task { @MainActor in
            while !Task.isCancelled, let startedAt {
                elapsed = Date().timeIntervalSince(startedAt)
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private static func defaultTitle(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE HH:mm"
        return "Meeting · \(formatter.string(from: date))"
    }

    // MARK: - Transcription

    /// Transcribes both tracks, diarizes the remote one, and merges them into one timeline.
    private static func transcribe(
        mic: [Float],
        system: [Float],
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> [MeetingSegment] {
        let manager = try await ParakeetModels.shared.manager()
        onProgress(0.1)

        var segments: [MeetingSegment] = []

        // Your own track needs no diarization: there is exactly one person on it.
        if mic.count >= 1_600 {
            var state = try TdtDecoderState()
            let result = try await manager.transcribe(mic, decoderState: &state)
            segments += group(
                timings: result.tokenTimings ?? [],
                fallbackText: result.text,
                speaker: "You",
                duration: Double(mic.count) / sampleRate
            )
        }
        onProgress(0.45)

        if system.count >= 1_600 {
            var state = try TdtDecoderState()
            let result = try await manager.transcribe(system, decoderState: &state)
            onProgress(0.75)

            let speakers = await diarize(system)
            segments += group(
                timings: result.tokenTimings ?? [],
                fallbackText: result.text,
                speaker: "Speaker 1",
                duration: Double(system.count) / sampleRate,
                speakerAt: { time in Self.speaker(at: time, in: speakers) }
            )
        }

        onProgress(1)
        return segments.sorted { $0.start < $1.start }
    }

    /// - Returns: diarized segments, or empty if the models aren't available — in which
    ///   case every remote voice is labelled "Speaker 1" rather than the meeting failing.
    private static func diarize(_ samples: [Float]) async -> [TimedSpeakerSegment] {
        do {
            let models = try await DiarizerModels.downloadIfNeeded()
            let diarizer = DiarizerManager()
            diarizer.initialize(models: consume models)
            return try diarizer.performCompleteDiarization(
                samples,
                sampleRate: Int(sampleRate)
            ).segments
        } catch {
            Log.speech.info("diarization unavailable (\(error.localizedDescription, privacy: .public)) — one speaker")
            return []
        }
    }

    private static func speaker(at time: TimeInterval, in segments: [TimedSpeakerSegment]) -> String? {
        guard !segments.isEmpty else { return nil }

        let match = segments.first {
            time >= TimeInterval($0.startTimeSeconds) && time <= TimeInterval($0.endTimeSeconds)
        }
        // A word landing in a gap between diarized segments belongs to whoever was
        // speaking most recently — silence doesn't change who has the floor.
        let resolved = match ?? segments.last { TimeInterval($0.endTimeSeconds) <= time }
        guard let resolved else { return nil }

        return Self.label(for: resolved.speakerId, in: segments)
    }

    /// Maps the diarizer's opaque speaker ids onto "Speaker N", numbered by first
    /// appearance so the labels read in the order people spoke.
    private static func label(for speakerID: String, in segments: [TimedSpeakerSegment]) -> String {
        var order: [String] = []
        for segment in segments.sorted(by: { $0.startTimeSeconds < $1.startTimeSeconds })
        where !order.contains(segment.speakerId) {
            order.append(segment.speakerId)
        }
        let index = (order.firstIndex(of: speakerID) ?? 0) + 1
        return "Speaker \(index)"
    }

    /// Groups word timings into readable segments.
    ///
    /// Split on a pause, on a speaker change, or once a segment has run long enough to be
    /// a paragraph — the three things that make a transcript scannable rather than a wall.
    private static func group(
        timings: [TokenTiming],
        fallbackText: String,
        speaker: String,
        duration: TimeInterval,
        speakerAt: ((TimeInterval) -> String?)? = nil
    ) -> [MeetingSegment] {
        let text = fallbackText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }

        // No timings means no way to split or attribute — keep the transcript rather than
        // dropping it, as one segment spanning the recording.
        guard !timings.isEmpty else {
            return [MeetingSegment(speaker: speaker, start: 0, end: duration, text: text)]
        }

        /// A gap longer than this reads as a new thought rather than a pause for breath.
        let pause: TimeInterval = 0.9
        /// Past this, split anyway — an unbroken monologue is still hard to read.
        let maxSegment: TimeInterval = 25

        var segments: [MeetingSegment] = []
        var words: [String] = []
        var start = TimeInterval(timings[0].startTime)
        var end = start
        var current = speakerAt?(start) ?? speaker

        func flush() {
            let joined = words.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !joined.isEmpty else { return }
            segments.append(MeetingSegment(speaker: current, start: start, end: end, text: joined))
            words.removeAll(keepingCapacity: true)
        }

        for (index, timing) in timings.enumerated() {
            let at = TimeInterval(timing.startTime)
            let who = speakerAt?(at) ?? speaker
            let gap = index == 0 ? 0 : at - end

            if !words.isEmpty, who != current || gap > pause || (end - start) > maxSegment {
                flush()
                start = at
                current = who
            }

            words.append(timing.token)
            end = TimeInterval(timing.endTime)
        }
        flush()

        return segments
    }
}

/// The two capture buffers.
///
/// A plain locked class rather than an actor: both writers are real-time audio threads,
/// which cannot `await`.
private final class TrackBuffers: @unchecked Sendable {
    private let lock = NSLock()
    private var micTrack: [Float] = []
    private var systemTrack: [Float] = []

    func appendMic(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        lock.lock()
        micTrack.append(contentsOf: samples)
        lock.unlock()
    }

    func appendSystem(_ samples: [Float]) {
        lock.lock()
        systemTrack.append(contentsOf: samples)
        lock.unlock()
    }

    func micSamples() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return micTrack
    }

    func systemSamples() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return systemTrack
    }

    func reset() {
        lock.lock()
        micTrack.removeAll(keepingCapacity: false)
        systemTrack.removeAll(keepingCapacity: false)
        lock.unlock()
    }
}
