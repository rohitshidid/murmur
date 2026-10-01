import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// Captures what the *other* participants say — everything the Mac is playing — using a
/// CoreAudio process tap.
///
/// **Why a process tap and not ScreenCaptureKit.** `SCStream` will hand over system audio
/// with much less code, but it is a screen-recording API: it asks the user for Screen
/// Recording permission, and a dictation app requesting the right to watch your display is
/// a bad trade for a feature that only needs sound. A process tap asks for audio and
/// nothing else.
///
/// The shape is fixed by CoreAudio: a tap is not itself readable. It has to be wrapped in a
/// private aggregate device, which is then read with an IO proc like any other device.
///
/// The IO proc reads only an immutable `IOState` built per start, so a stop on the main
/// thread can never race a callback that is mid-flight.
///
/// **Output changes.** The tap needs a real output device as its clock, so the aggregate is
/// built around the default output. When that changes — Bluetooth headphones connecting, or
/// disconnecting and taking their clock with them — the whole tap and aggregate are rebuilt
/// on the new one, feeding the same `onSamples`.
@MainActor
public final class SystemAudioCapture {
    /// Raised when the tap can't be created, which on a modern macOS almost always means
    /// the user hasn't allowed audio recording for this app.
    public enum CaptureError: LocalizedError {
        case tapCreationFailed(OSStatus)
        case aggregateCreationFailed(OSStatus)
        case tapFormatUnavailable
        case ioProcFailed(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .tapCreationFailed(let status):
                return "Couldn't tap system audio (\(status)). Allow audio recording for "
                    + "Murmur in System Settings ▸ Privacy & Security."
            case .aggregateCreationFailed(let status):
                return "Couldn't create the capture device (\(status))."
            case .tapFormatUnavailable:
                return "The system audio tap reported no usable format."
            case .ioProcFailed(let status):
                return "Couldn't start reading system audio (\(status))."
            }
        }
    }

    /// Called when a rebuild after an output change failed and system audio is no longer
    /// being recorded. Set once by the owner; survives `stop()`.
    public var onFailure: ((String) -> Void)?
    /// Successful rebuilds since `start`. Diagnostics only.
    public private(set) var rebuilds = 0

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var tapUUID = UUID()
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var isRunning = false

    private var outputFormat: AVAudioFormat?
    private var onSamples: (@Sendable ([Float]) -> Void)?
    private var outputListener: AudioObjectPropertyListenerBlock?
    private var pendingRebuild: Task<Void, Never>?

    public init() {}

    /// - Parameter onSamples: called on the audio thread with mono samples already at
    ///   `outputFormat`'s rate.
    public func start(
        outputFormat: AVAudioFormat,
        onSamples: @escaping @Sendable ([Float]) -> Void
    ) throws {
        guard !isRunning else { return }

        self.onSamples = onSamples
        self.outputFormat = outputFormat

        try build()
        rebuilds = 0
        isRunning = true
        watchDefaultOutput()
        audioLog.info("system audio capture started")
    }

    public func stop() {
        pendingRebuild?.cancel()
        pendingRebuild = nil
        unwatchDefaultOutput()
        let wasRunning = isRunning
        isRunning = false
        teardown()
        onSamples = nil
        if wasRunning { audioLog.info("system audio capture stopped") }
    }

    /// Tap, aggregate, IO proc — in that order, and all undone if any step fails. The old
    /// version only cleaned up after a *successful* start, so a failure halfway left a
    /// process tap and a private aggregate device alive for the rest of the session.
    private func build() throws {
        guard let outputFormat, let onSamples else { throw CaptureError.tapFormatUnavailable }
        do {
            let tapFormat = try createTap()
            try createAggregateDevice()
            try startIOProc(state: IOState(tapFormat: tapFormat, outputFormat: outputFormat, onSamples: onSamples))
        } catch {
            teardown()
            throw error
        }
    }

    /// Releases every CoreAudio object this capture created. Safe on a half-built capture.
    private func teardown() {
        if let ioProcID {
            // Stop and destroy are synchronous: once they return, the IO proc is not running.
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil

        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    // MARK: - Output changes

    private func watchDefaultOutput() {
        // `@Sendable` for the same reason as the IO proc: never assume which queue CoreAudio
        // calls back on.
        let block: AudioObjectPropertyListenerBlock = { @Sendable [weak self] _, _ in
            Task { @MainActor in self?.defaultOutputChanged() }
        }
        var address = Self.defaultOutputAddress
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block) == noErr {
            outputListener = block
        }
    }

    private func unwatchDefaultOutput() {
        guard let outputListener else { return }
        var address = Self.defaultOutputAddress
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, outputListener)
        self.outputListener = nil
    }

    private func defaultOutputChanged() {
        guard isRunning, pendingRebuild == nil else { return }
        audioLog.info("default output changed — rebuilding system audio capture")
        teardown()
        // A short wait: the new output is often still negotiating its format when the
        // default flips, and an aggregate built on it then reports no channels.
        pendingRebuild = Task { @MainActor [weak self] in
            for delay in [0.3, 0.7, 1.5] {
                try? await Task.sleep(for: .seconds(delay))
                guard let self, !Task.isCancelled, self.isRunning else { return }
                do {
                    try self.build()
                    self.pendingRebuild = nil
                    self.rebuilds += 1
                    audioLog.info("system audio capture rebuilt")
                    return
                } catch {
                    audioLog.error("system audio rebuild failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            guard let self, self.isRunning else { return }
            self.pendingRebuild = nil
            self.stop()
            self.onFailure?("System audio stopped recording after the output device changed.")
        }
    }

    private static var defaultOutputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    // MARK: - Setup

    /// - Returns: the tap's format, which the IO proc's buffers arrive in.
    private func createTap() throws -> AVAudioFormat {
        // Our own process is excluded so the capture never picks up Murmur's own start and
        // stop ticks — which would otherwise be transcribed as part of the meeting.
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: Self.ownProcessObjects())
        description.name = "Murmur system capture"
        description.uuid = UUID()
        // Private: the tap belongs to this process and shouldn't appear in other apps'
        // device lists. Unmuted: the user must still hear the meeting they're in.
        description.isPrivate = true
        description.muteBehavior = .unmuted

        let status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr, tapID != AudioObjectID(kAudioObjectUnknown) else {
            throw CaptureError.tapCreationFailed(status)
        }

        tapUUID = description.uuid
        return try readTapFormat()
    }

    private func readTapFormat() throws -> AVAudioFormat {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var streamDescription = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &streamDescription)

        guard status == noErr, let format = AVAudioFormat(streamDescription: &streamDescription) else {
            throw CaptureError.tapFormatUnavailable
        }
        return format
    }

    private func createAggregateDevice() throws {
        // The tap has to ride on a real output device for its clock, so the aggregate is
        // built around whatever the system is currently playing through.
        let outputUID = Self.defaultOutputDeviceUID() ?? ""

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Murmur Capture",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            // Private so it never appears in Sound settings as a selectable device.
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapUUID.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]

        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID)
        guard status == noErr, aggregateID != AudioObjectID(kAudioObjectUnknown) else {
            throw CaptureError.aggregateCreationFailed(status)
        }
    }

    private func startIOProc(state: IOState) throws {
        // The block holds `state` strongly and nothing else: no `self`, nothing mutable.
        //
        // `@Sendable` is load-bearing. This class is `@MainActor`, so a plain closure written
        // here inherits main-actor isolation, and Swift 6 checks that on entry — on the
        // CoreAudio IO thread, which traps (`dispatch_assert_queue` → SIGTRAP) the first time
        // anything plays.
        let status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) { @Sendable _, inputData, _, _, _ in
            state.handle(inputData)
        }
        guard status == noErr, let ioProcID else { throw CaptureError.ioProcFailed(status) }

        let started = AudioDeviceStart(aggregateID, ioProcID)
        guard started == noErr else { throw CaptureError.ioProcFailed(started) }
    }
    // MARK: - CoreAudio lookups

    /// This process, as a CoreAudio process object, so the tap can exclude it.
    private static func ownProcessObjects() -> [AudioObjectID] {
        var pid = getpid()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &pid,
            &size,
            &object
        )

        // Excluding nothing is a worse capture, not a broken one — the meeting is still
        // recorded, with our own ticks in it.
        guard status == noErr, object != AudioObjectID(kAudioObjectUnknown) else { return [] }
        return [object]
    }

    private static func defaultOutputDeviceUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        ) == noErr else { return nil }

        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: CFString = "" as CFString
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &uidSize, &uid) == noErr else {
            return nil
        }
        return uid as String
    }
}

/// Everything the IO proc reads, fixed when the capture is built. Rebuilt — never mutated —
/// when the capture is.
private final class IOState: @unchecked Sendable {
    private let tapFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter?
    private let onSamples: @Sendable ([Float]) -> Void

    init(tapFormat: AVAudioFormat, outputFormat: AVAudioFormat, onSamples: @escaping @Sendable ([Float]) -> Void) {
        self.tapFormat = tapFormat
        self.outputFormat = outputFormat
        self.converter = tapFormat == outputFormat ? nil : AVAudioConverter(from: tapFormat, to: outputFormat)
        self.onSamples = onSamples
    }

    // MARK: Audio thread

    func handle(_ inputData: UnsafePointer<AudioBufferList>) {
        let frames = AVAudioFrameCount(
            inputData.pointee.mBuffers.mDataByteSize
                / max(1, tapFormat.streamDescription.pointee.mBytesPerFrame)
        )
        guard frames > 0 else { return }

        guard let wrapped = AVAudioPCMBuffer(
            pcmFormat: tapFormat,
            bufferListNoCopy: inputData,
            deallocator: nil
        ) else { return }
        // The input block runs synchronously inside `convert`, on this thread.
        nonisolated(unsafe) let source = wrapped

        guard let converter else {
            onSamples(Self.mono(from: source))
            return
        }

        let ratio = outputFormat.sampleRate / tapFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(frames) * ratio).rounded(.up)) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return
        }

        let supplied = Latch()
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            // The converter asks repeatedly; hand over the buffer once and then report the
            // stream as dry, or it will spin re-consuming the same frames.
            if supplied.take() {
                status.pointee = .noDataNow
                return nil
            }
            status.pointee = .haveData
            return source
        }

        guard error == nil, converted.frameLength > 0 else { return }
        onSamples(Self.mono(from: converted))
    }

    /// Flattens to mono by averaging channels — the meeting mix matters, not its stereo
    /// image, and both the ASR and the diarizer want one channel.
    private static func mono(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channels = buffer.floatChannelData else { return [] }
        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frames > 0, channelCount > 0 else { return [] }

        if channelCount == 1 {
            return Array(UnsafeBufferPointer(start: channels[0], count: frames))
        }

        var result = [Float](repeating: 0, count: frames)
        for channel in 0..<channelCount {
            let samples = channels[channel]
            for frame in 0..<frames { result[frame] += samples[frame] }
        }
        let scale = 1 / Float(channelCount)
        for frame in 0..<frames { result[frame] *= scale }
        return result
    }
}
