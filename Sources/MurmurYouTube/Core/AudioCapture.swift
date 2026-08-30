import AVFoundation
import CoreAudio
import Foundation

/// Microphone capture with on-the-fly conversion to whatever format the speech engine wants.
///
/// The tap runs on a real-time audio thread, so everything it touches lives behind
/// `nonisolated(unsafe)` and is only ever mutated from that one thread.
final class AudioCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private nonisolated(unsafe) var converter: AVAudioConverter?
    private nonisolated(unsafe) var outputFormat: AVAudioFormat?
    private var isRunning = false

    /// Called on the audio thread with each converted buffer.
    private nonisolated(unsafe) var onBuffer: (@Sendable (AudioChunk) -> Void)?
    /// Called on the audio thread with a 0…1 RMS level, for the HUD waveform.
    private nonisolated(unsafe) var onLevel: (@Sendable (Float) -> Void)?

    /// Called on the main thread after the engine was torn down because the audio hardware
    /// changed underneath it. Set once by the owner; survives `stop()`.
    var onConfigurationChange: (@Sendable () -> Void)?

    private var configObserver: NSObjectProtocol?

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
    }

    /// - Parameter deviceID: the microphone to record from, or nil for the system default.
    func start(
        outputFormat: AVAudioFormat,
        deviceID: AudioDeviceID? = nil,
        onBuffer: @escaping @Sendable (AudioChunk) -> Void,
        onLevel: @escaping @Sendable (Float) -> Void
    ) throws {
        guard !isRunning else { return }

        self.onBuffer = onBuffer
        self.onLevel = onLevel
        self.outputFormat = outputFormat

        let input = engine.inputNode

        // Must happen before the format is read: switching devices changes the input's
        // sample rate and channel count, and a converter built from the previous device's
        // format would quietly resample from the wrong rate.
        if let deviceID { setInputDevice(deviceID, on: input) }

        let nativeFormat = input.outputFormat(forBus: 0)

        converter = nativeFormat == outputFormat
            ? nil
            : AVAudioConverter(from: nativeFormat, to: outputFormat)

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: nativeFormat) { [weak self] buffer, _ in
            self?.handle(buffer)
        }

        // Connecting Bluetooth headphones, unplugging an interface, or the system changing
        // default device all reconfigure the engine *while the tap is running*. Left
        // unhandled, the audio thread keeps delivering buffers in the old format into state
        // the main thread is tearing down.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Log.audio.info("audio configuration changed — stopping capture")
            // Read before `stop()`, which is allowed to clear the audio-thread callbacks.
            let notify = self.onConfigurationChange
            self.stop()
            notify?()
        }

        engine.prepare()
        try engine.start()
        isRunning = true
        Log.audio.info("capture started — native \(nativeFormat.sampleRate)Hz → engine \(outputFormat.sampleRate)Hz")
    }

    /// Points the engine's input at one device, for this app only.
    ///
    /// Deliberately not `kAudioHardwarePropertyDefaultInputDevice` — that would repoint the
    /// microphone for every app on the machine.
    private func setInputDevice(_ deviceID: AudioDeviceID, on input: AVAudioInputNode) {
        guard let unit = input.audioUnit else { return }
        var id = deviceID
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            // Not fatal: the engine falls back to the system default, which still records.
            Log.audio.error("couldn't select input device \(deviceID) — status \(status)")
        }
    }

    func stop() {
        // Removed unconditionally, and first: leaving it registered would re-enter this
        // method on the next device change for an engine that is no longer running.
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }

        guard isRunning else { return }
        // The tap comes off before anything it reads is cleared, so an in-flight callback
        // can never see half-torn-down state.
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        converter = nil
        onBuffer = nil
        onLevel = nil
        Log.audio.info("capture stopped")
    }

    // MARK: - Audio thread

    private func handle(_ buffer: AVAudioPCMBuffer) {
        onLevel?(Self.rms(of: buffer))

        guard let outputFormat else { return }

        // AVAudioEngine reuses the tap's buffer as soon as this returns, so the engine
        // must never see it directly — copy when no conversion would otherwise allocate.
        guard let converter else {
            if let copy = Self.copy(buffer) {
                onBuffer?(AudioChunk(buffer: copy))
            }
            return
        }

        // Output frame count scales with the sample-rate ratio; round up so we never clip.
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }

        // The input block runs synchronously inside `convert`, on this thread.
        nonisolated(unsafe) let input = buffer
        let consumed = Latch()
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, outStatus in
            guard !consumed.take() else {
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            return input
        }

        if let error {
            Log.audio.error("conversion failed: \(error.localizedDescription)")
            return
        }
        guard status != .error, converted.frameLength > 0 else { return }
        onBuffer?(AudioChunk(buffer: converted))
    }

    /// Deep-copies a tap buffer into storage we own.
    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength)
        else { return nil }

        copy.frameLength = buffer.frameLength
        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)

        if let source = buffer.floatChannelData, let destination = copy.floatChannelData {
            for channel in 0..<channels {
                destination[channel].update(from: source[channel], count: frames)
            }
        } else if let source = buffer.int16ChannelData, let destination = copy.int16ChannelData {
            for channel in 0..<channels {
                destination[channel].update(from: source[channel], count: frames)
            }
        } else if let source = buffer.int32ChannelData, let destination = copy.int32ChannelData {
            for channel in 0..<channels {
                destination[channel].update(from: source[channel], count: frames)
            }
        } else {
            return nil
        }

        return copy
    }

    /// One-shot flag. Only touched from the audio thread inside a synchronous call.
    private final class Latch: @unchecked Sendable {
        private var fired = false
        /// - Returns: the value *before* this call, then latches to `true`.
        func take() -> Bool {
            defer { fired = true }
            return fired
        }
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
}
