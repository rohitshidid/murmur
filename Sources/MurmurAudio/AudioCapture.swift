import AVFoundation
import CoreAudio
import Foundation

/// Microphone capture with on-the-fly conversion to whatever format the speech engine wants,
/// which **repairs itself** when the hardware changes underneath it.
///
/// Bluetooth headphones change constantly while in use: they drop from 48 kHz to headset
/// rate the moment a microphone opens on them, disconnect when walked away from, and become
/// the system default when they reconnect. Each of those used to end the utterance (or
/// crash — see `InputUnit`). Now the capture closes the device, waits for it to settle,
/// reopens whichever device is right at that moment, and keeps delivering into the **same**
/// `onBuffer` — so the speech engine sees a few hundred milliseconds of missing audio rather
/// than a failure. The caller hears about a hardware change only if repair fails
/// repeatedly; that is what `onFailure` is for.
///
/// Main-actor only. The audio thread never touches this object — everything it reads lives
/// immutably on the `InputUnit`.
@MainActor
public final class AudioCapture {
    /// Called when the capture stopped because the hardware changed and couldn't be
    /// recovered. Set once by the owner; survives `stop()`. Never called for `stop()` itself.
    public var onFailure: ((String) -> Void)?

    public private(set) var isRunning = false
    /// The microphone actually being recorded right now — which, after a recovery, may not
    /// be the one the capture started on.
    public var currentDevice: AudioInputDevice? { unit?.device }
    /// Successful repairs since `start`. Diagnostics only.
    public private(set) var recoveries = 0

    private struct Request {
        let outputFormat: AVAudioFormat
        let preferredDeviceUID: String?
        let onBuffer: @Sendable (AudioChunk) -> Void
        let onLevel: @Sendable (Float) -> Void
    }

    private var request: Request?
    private var unit: InputUnit?
    private var watch: DeviceWatch?
    private var recovery = RecoveryPolicy()
    private var pendingRecovery: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?

    public init() {}

    /// - Parameter preferredDeviceUID: the chosen microphone, or nil for the system default.
    ///   Resolved now *and on every recovery*, so a mic that is unplugged mid-utterance falls
    ///   back to the default and the preferred one is picked up again the next time.
    public func start(
        outputFormat: AVAudioFormat,
        preferredDeviceUID: String?,
        onBuffer: @escaping @Sendable (AudioChunk) -> Void,
        onLevel: @escaping @Sendable (Float) -> Void
    ) throws {
        guard !isRunning else { return }

        request = Request(
            outputFormat: outputFormat,
            preferredDeviceUID: preferredDeviceUID,
            onBuffer: onBuffer,
            onLevel: onLevel
        )
        recovery = RecoveryPolicy()
        recoveries = 0
        do {
            try open()
        } catch {
            request = nil
            throw error
        }
        isRunning = true
        startWatchdog()
    }

    public func stop() {
        pendingRecovery?.cancel()
        pendingRecovery = nil
        watchdog?.cancel()
        watchdog = nil
        let wasRunning = isRunning
        close()
        request = nil
        isRunning = false
        if wasRunning { audioLog.info("capture stopped") }
    }

    // MARK: - Opening and closing

    private func open() throws {
        guard let request else { return }
        guard let device = AudioDevices.resolveNow(preferredUID: request.preferredDeviceUID) else {
            throw CaptureError.noInputDevice
        }

        let unit = try InputUnit(
            device: device,
            outputFormat: request.outputFormat,
            onBuffer: request.onBuffer,
            onLevel: request.onLevel
        )
        try unit.start()
        self.unit = unit

        // Delivered on the main queue, then hopped onto the actor: the notification is
        // never trusted to already be there.
        watch = DeviceWatch(deviceID: device.id) { [weak self] disruption in
            Task { @MainActor in self?.handle(disruption) }
        }

        audioLog.info("capture started — \(device.name, privacy: .public) \(unit.hardwareShape.description, privacy: .public) → \(Int(request.outputFormat.sampleRate))Hz")
    }

    /// Releases the device. Listeners go first so the teardown itself can't be reported
    /// back as a disruption.
    private func close() {
        watch?.cancel()
        watch = nil
        unit?.close()
        unit = nil
    }

    // MARK: - Recovery

    private func handle(_ disruption: CaptureDisruption) {
        // One repair at a time: a single Bluetooth switch fires several notifications.
        guard isRunning, pendingRecovery == nil, let unit else { return }

        switch disruption {
        case .formatChanged:
            // Often announced for a "change" to the value the device already had.
            guard StreamShape.needsRebuild(running: unit.hardwareShape, current: unit.currentHardwareShape()) else {
                return
            }
        case .deviceLost:
            guard !AudioDevices.isAlive(unit.device.id) else { return }
        case .stalled:
            break
        }

        audioLog.info("capture disrupted (\(disruption.rawValue, privacy: .public)) on \(unit.device.name, privacy: .public) — rebuilding")
        // Closed immediately, not after the delay: nothing should keep running on a device
        // that is mid-switch.
        close()
        scheduleRecovery(after: disruption)
    }

    private func scheduleRecovery(after disruption: CaptureDisruption) {
        guard let delay = recovery.nextDelay(at: ProcessInfo.processInfo.systemUptime) else {
            fail(disruption)
            return
        }

        pendingRecovery = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, self.isRunning else { return }
            self.pendingRecovery = nil
            do {
                try self.open()
                self.startWatchdog()
                self.recoveries += 1
                audioLog.info("capture recovered on \(self.unit?.device.name ?? "?", privacy: .public)")
            } catch {
                audioLog.error("capture rebuild failed: \(error.localizedDescription, privacy: .public)")
                self.scheduleRecovery(after: disruption)
            }
        }
    }

    private func fail(_ disruption: CaptureDisruption) {
        audioLog.error("capture gave up after repeated \(disruption.rawValue, privacy: .public)")
        stop()
        onFailure?(
            disruption == .deviceLost
                ? "The microphone disconnected and no other microphone is available."
                : "The microphone kept changing and couldn't be reopened."
        )
    }

    /// Watches for a device that has stopped delivering without announcing anything.
    private func startWatchdog() {
        watchdog?.cancel()
        let started = ProcessInfo.processInfo.systemUptime
        watchdog = Task { @MainActor [weak self] in
            var detector = StallDetector(now: started)
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled else { return }
                guard let unit = self.unit else { continue }
                let count = unit.callbacks.load(ordering: .relaxed)
                if detector.isStalled(callbacks: count, at: ProcessInfo.processInfo.systemUptime) {
                    self.handle(.stalled)
                    return
                }
            }
        }
    }
}

public enum CaptureError: LocalizedError {
    case noInputDevice

    public var errorDescription: String? {
        switch self {
        case .noInputDevice:
            return "No microphone is available. Connect one, or check System Settings ▸ Sound ▸ Input."
        }
    }
}

/// CoreAudio property listeners for one capture's device.
///
/// Main-actor confined: listeners are added, delivered (on the main queue) and removed on the
/// main thread. Removal needs the identical block object, so each one is stored.
@MainActor
final class DeviceWatch {
    private let deviceID: AudioDeviceID
    private var registrations: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    init(deviceID: AudioDeviceID, onDisruption: @escaping @Sendable (CaptureDisruption) -> Void) {
        self.deviceID = deviceID

        // `@Sendable` so these don't inherit this type's main-actor isolation: Swift 6 would
        // check it on entry, and a listener is CoreAudio's to call from wherever it likes.
        let format: AudioObjectPropertyListenerBlock = { @Sendable _, _ in onDisruption(.formatChanged) }
        let lost: AudioObjectPropertyListenerBlock = { @Sendable _, _ in onDisruption(.deviceLost) }

        listen(deviceID, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, format)
        listen(deviceID, kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyScopeInput, format)
        listen(deviceID, kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal, lost)
        // Some Bluetooth stacks remove the device outright without flipping IsAlive first.
        listen(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, lost)
    }

    func cancel() {
        for (object, address, block) in registrations {
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, DispatchQueue.main, block)
        }
        registrations.removeAll()
    }

    private func listen(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope,
        _ block: @escaping AudioObjectPropertyListenerBlock
    ) {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectAddPropertyListenerBlock(object, &address, DispatchQueue.main, block)
        if status == noErr {
            registrations.append((object, address, block))
        } else {
            audioLog.error("couldn't watch device property \(selector) — status \(status)")
        }
    }
}
