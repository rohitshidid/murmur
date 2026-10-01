import AVFoundation
import AudioToolbox
import CoreAudio
import Synchronization

/// One open microphone: an input-only HAL audio unit on exactly one device.
///
/// **Why not `AVAudioEngine`.** On macOS the engine's input and output share one I/O unit,
/// so whenever the microphone and the default output are different devices the engine
/// quietly builds an aggregate of the two. With Bluetooth headphones as the output — the
/// normal case for anyone wearing them — every recording then depends on the headphones,
/// even when the built-in mic is the one in use. Headphones switch between music and headset
/// mode as microphones open and close, the aggregate reconfigures, and the engine:
///
/// - posts `AVAudioEngineConfigurationChange`, which ended the utterance;
/// - reports its input format from the *output* device (24 kHz, the AirPods' headset rate,
///   for a 48 kHz built-in mic), so the next `installTap` raises "Failed to create tap due
///   to format mismatch" — an Objective-C exception, which Swift cannot catch;
/// - and, rebuilt under a running I/O thread, can call a callback that has already gone —
///   the `EXC_BAD_ACCESS` at address 0 on `com.apple.audio.IOThread.client`.
///
/// This unit has its output side disabled. It never opens, aggregates or depends on any
/// output device, so none of that can happen.
///
/// **Lifetime.** Every input the audio thread reads is a `let` fixed at init, so stopping a
/// capture never races a callback that is mid-flight — the old capture cleared its closures
/// from the main thread while the audio thread could be reading them. The unit retains
/// itself for the I/O callback and releases that only after `AudioComponentInstanceDispose`,
/// which is CoreAudio's guarantee that the callback will not run again.
final class InputUnit: @unchecked Sendable {
    enum UnitError: LocalizedError {
        case noComponent
        case step(String, OSStatus)
        case unusableFormat(StreamShape)

        var errorDescription: String? {
            switch self {
            case .noComponent:
                return "This Mac has no audio input unit."
            case .step(let step, let status):
                return "Couldn't open the microphone (\(step), \(status))."
            case .unusableFormat(let shape):
                return "The microphone reported no usable format (\(shape))."
            }
        }
    }

    let device: AudioInputDevice
    /// What the device was delivering when this unit was opened.
    let hardwareShape: StreamShape

    /// Audio callbacks so far. Read from the main thread by the stall watchdog.
    let callbacks = Atomic<UInt64>(0)

    private let unit: AudioUnit
    private let clientFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter?
    private let renderBuffer: AVAudioPCMBuffer
    private let onBuffer: @Sendable (AudioChunk) -> Void
    private let onLevel: @Sendable (Float) -> Void

    private var selfRetain: Unmanaged<InputUnit>?
    private var isClosed = false

    init(
        device: AudioInputDevice,
        outputFormat: AVAudioFormat,
        onBuffer: @escaping @Sendable (AudioChunk) -> Void,
        onLevel: @escaping @Sendable (Float) -> Void
    ) throws {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else { throw UnitError.noComponent }

        var created: AudioUnit?
        try Self.check("create", AudioComponentInstanceNew(component, &created))
        guard let unit = created else { throw UnitError.noComponent }

        // Everything from here can fail; a half-built unit is still a live component.
        do {
            // Input on, output off — the line that keeps the headphones out of it.
            try Self.set(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, UInt32(1), "enable input")
            try Self.set(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, UInt32(0), "disable output")
            // Applied to this unit only. Never `kAudioHardwarePropertyDefaultInputDevice`,
            // which would repoint the microphone for every app on the machine.
            try Self.set(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, device.id, "select device")

            // The device side of the input bus: what the hardware is delivering right now.
            var hardware = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try Self.check("read format", AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hardware, &size))
            let shape = StreamShape(sampleRate: hardware.mSampleRate, channels: hardware.mChannelsPerFrame)
            guard shape.isUsable else { throw UnitError.unusableFormat(shape) }

            // The app side: mono float at the hardware's own rate. The unit takes the first
            // channel; rate conversion stays ours, because a HAL unit won't resample input.
            guard let client = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: hardware.mSampleRate,
                channels: 1,
                interleaved: false
            ) else { throw UnitError.unusableFormat(shape) }
            try Self.set(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, client.streamDescription.pointee, "set format")

            var maxFrames: UInt32 = 0
            size = UInt32(MemoryLayout<UInt32>.size)
            AudioUnitGetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, &size)
            guard let renderBuffer = AVAudioPCMBuffer(pcmFormat: client, frameCapacity: max(maxFrames, 8192)) else {
                throw UnitError.unusableFormat(shape)
            }

            self.unit = unit
            self.device = device
            self.hardwareShape = shape
            self.clientFormat = client
            self.outputFormat = outputFormat
            self.converter = client == outputFormat ? nil : AVAudioConverter(from: client, to: outputFormat)
            self.renderBuffer = renderBuffer
            self.onBuffer = onBuffer
            self.onLevel = onLevel
        } catch {
            AudioComponentInstanceDispose(unit)
            throw error
        }
    }

    deinit {
        close()
    }

    func start() throws {
        let retained = Unmanaged.passRetained(self)
        selfRetain = retained
        let callback = AURenderCallbackStruct(inputProc: inputProc, inputProcRefCon: retained.toOpaque())
        do {
            try Self.set(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, callback, "set callback")
            try Self.check("initialize", AudioUnitInitialize(unit))
            try Self.check("start", AudioOutputUnitStart(unit))
        } catch {
            close()
            throw error
        }
    }

    /// Stops and disposes the unit. Idempotent; must be called from one thread at a time
    /// (the capture calls it only from the main actor).
    func close() {
        guard !isClosed else { return }
        isClosed = true
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        // After this returns the I/O callback can't run again, so the self-retain it was
        // using can finally go.
        AudioComponentInstanceDispose(unit)
        selfRetain?.release()
        selfRetain = nil
    }

    /// What the device is delivering now, or nil if it can't be read — mid-switch, or gone.
    func currentHardwareShape() -> StreamShape? {
        guard !isClosed else { return nil }
        var hardware = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hardware, &size) == noErr else {
            return nil
        }
        return StreamShape(sampleRate: hardware.mSampleRate, channels: hardware.mChannelsPerFrame)
    }

    // MARK: - Audio thread

    fileprivate func render(
        _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        _ timeStamp: UnsafePointer<AudioTimeStamp>,
        _ bus: UInt32,
        _ frames: UInt32
    ) -> OSStatus {
        callbacks.add(1, ordering: .relaxed)
        guard frames > 0, frames <= renderBuffer.frameCapacity else { return noErr }

        let list = renderBuffer.mutableAudioBufferList
        list.pointee.mBuffers.mDataByteSize = frames * UInt32(MemoryLayout<Float>.size)
        let status = AudioUnitRender(unit, flags, timeStamp, bus, frames, list)
        guard status == noErr else { return status }
        renderBuffer.frameLength = frames

        onLevel(Self.rms(of: renderBuffer))
        deliver(renderBuffer)
        return noErr
    }

    /// Converts and hands over. `renderBuffer` is reused on the next callback, so the engine
    /// only ever receives a fresh copy.
    private func deliver(_ buffer: AVAudioPCMBuffer) {
        guard let converter else {
            if let copy = Self.copy(buffer) { onBuffer(AudioChunk(buffer: copy)) }
            return
        }

        // Output frame count scales with the sample-rate ratio; round up so we never clip.
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }

        // The input block runs synchronously inside `convert`, on this thread.
        nonisolated(unsafe) let input = buffer
        let supplied = Latch()
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, outStatus in
            // Hand the buffer over once, then report the stream dry, or the converter spins
            // re-consuming the same frames.
            if supplied.take() {
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            return input
        }

        if let error {
            audioLog.error("conversion failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard status != .error, converted.frameLength > 0 else { return }
        onBuffer(AudioChunk(buffer: converted))
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0,
              let source = buffer.floatChannelData,
              let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength),
              let destination = copy.floatChannelData
        else { return nil }

        copy.frameLength = buffer.frameLength
        for channel in 0..<Int(buffer.format.channelCount) {
            destination[channel].update(from: source[channel], count: Int(buffer.frameLength))
        }
        return copy
    }

    private static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }

        var sum: Float = 0
        for i in 0..<count {
            let sample = channel[i]
            sum += sample * sample
        }
        let rms = (sum / Float(count)).squareRoot()

        // Map roughly -50…0 dBFS onto 0…1 so quiet speech still moves the meter.
        let db = 20 * log10(max(rms, 1e-7))
        return max(0, min(1, (db + 50) / 50))
    }

    // MARK: - CoreAudio plumbing

    private static func check(_ step: String, _ status: OSStatus) throws {
        guard status == noErr else { throw UnitError.step(step, status) }
    }

    private static func set<T: BitwiseCopyable>(
        _ unit: AudioUnit,
        _ property: AudioUnitPropertyID,
        _ scope: AudioUnitScope,
        _ element: AudioUnitElement,
        _ value: T,
        _ step: String
    ) throws {
        var value = value
        try check(step, AudioUnitSetProperty(unit, property, scope, element, &value, UInt32(MemoryLayout<T>.size)))
    }
}

/// The I/O callback. A plain C function: it may not capture anything, so the unit arrives
/// through `refCon`, which `start()` retained.
private let inputProc: AURenderCallback = { refCon, flags, timeStamp, bus, frames, _ in
    Unmanaged<InputUnit>.fromOpaque(refCon).takeUnretainedValue().render(flags, timeStamp, bus, frames)
}

/// One-shot flag for an `AVAudioConverter` input block. Only touched from the audio thread,
/// inside a synchronous `convert` call.
final class Latch: @unchecked Sendable {
    private var fired = false
    /// - Returns: the value *before* this call, then latches to `true`.
    func take() -> Bool {
        defer { fired = true }
        return fired
    }
}
