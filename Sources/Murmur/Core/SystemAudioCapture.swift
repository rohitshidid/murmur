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
/// Everything the IO proc touches is `nonisolated(unsafe)` and mutated only from the audio
/// thread, exactly as `AudioCapture` does it.
final class SystemAudioCapture: @unchecked Sendable {
    /// Raised when the tap can't be created, which on a modern macOS almost always means
    /// the user hasn't allowed audio recording for this app.
    enum CaptureError: LocalizedError {
        case tapCreationFailed(OSStatus)
        case aggregateCreationFailed(OSStatus)
        case tapFormatUnavailable
        case ioProcFailed(OSStatus)

        var errorDescription: String? {
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

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var isRunning = false

    private nonisolated(unsafe) var converter: AVAudioConverter?
    private nonisolated(unsafe) var tapFormat: AVAudioFormat?
    private nonisolated(unsafe) var outputFormat: AVAudioFormat?
    private nonisolated(unsafe) var onSamples: (@Sendable ([Float]) -> Void)?

    /// - Parameter onSamples: called on the audio thread with mono samples already at
    ///   `outputFormat`'s rate.
    func start(
        outputFormat: AVAudioFormat,
        onSamples: @escaping @Sendable ([Float]) -> Void
    ) throws {
        guard !isRunning else { return }

        self.onSamples = onSamples
        self.outputFormat = outputFormat

        try createTap()
        try createAggregateDevice()
        try startIOProc()

        isRunning = true
        Log.audio.info("system audio capture started")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false

        if let ioProcID {
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

        converter = nil
        onSamples = nil
        Log.audio.info("system audio capture stopped")
    }

    // MARK: - Setup

    private func createTap() throws {
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
        tapFormat = try readTapFormat()
    }

    private var tapUUID = UUID()

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

    private func startIOProc() throws {
        guard let tapFormat, let outputFormat else { throw CaptureError.tapFormatUnavailable }
        converter = tapFormat == outputFormat ? nil : AVAudioConverter(from: tapFormat, to: outputFormat)

        let status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) {
            [weak self] _, inputData, _, _, _ in
            self?.handle(inputData)
        }
        guard status == noErr, let ioProcID else { throw CaptureError.ioProcFailed(status) }

        let started = AudioDeviceStart(aggregateID, ioProcID)
        guard started == noErr else { throw CaptureError.ioProcFailed(started) }
    }

    // MARK: - Audio thread

    private func handle(_ inputData: UnsafePointer<AudioBufferList>) {
        guard let tapFormat, let outputFormat, let onSamples else { return }

        let frames = AVAudioFrameCount(
            inputData.pointee.mBuffers.mDataByteSize
                / max(1, tapFormat.streamDescription.pointee.mBytesPerFrame)
        )
        guard frames > 0 else { return }

        guard let source = AVAudioPCMBuffer(
            pcmFormat: tapFormat,
            bufferListNoCopy: inputData,
            deallocator: nil
        ) else { return }

        guard let converter else {
            onSamples(Self.mono(from: source))
            return
        }

        let ratio = outputFormat.sampleRate / tapFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(frames) * ratio).rounded(.up)) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return
        }

        var supplied = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            // The converter asks repeatedly; hand over the buffer once and then report the
            // stream as dry, or it will spin re-consuming the same frames.
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
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
