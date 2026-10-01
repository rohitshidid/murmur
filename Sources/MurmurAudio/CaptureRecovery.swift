import Foundation

/// Why a running capture had to be rebuilt.
public enum CaptureDisruption: String, Sendable, Equatable {
    /// The device's sample rate or channel count changed underneath the capture. AirPods do
    /// this every time a microphone opens on them: 48 kHz music mode becomes 24 or 16 kHz
    /// headset mode, usually within a second of the first buffer.
    case formatChanged
    /// The device was unplugged, powered off, or walked out of Bluetooth range.
    case deviceLost
    /// The device stopped delivering audio without saying anything at all. Rare, and the
    /// one disruption only a watchdog can see.
    case stalled
}

/// The sample rate and channel count a device is delivering — the two things that, if they
/// change, make the running capture's converter wrong.
public struct StreamShape: Sendable, Equatable, CustomStringConvertible {
    public let sampleRate: Double
    public let channels: UInt32

    public init(sampleRate: Double, channels: UInt32) {
        self.sampleRate = sampleRate
        self.channels = channels
    }

    /// Whether this is something a capture can actually be built on. A device mid-switch
    /// reports 0 Hz or 0 channels, and building a converter from that fails later and less
    /// legibly.
    public var isUsable: Bool { sampleRate > 0 && channels > 0 }

    public var description: String { "\(Int(sampleRate))Hz/\(channels)ch" }

    /// Whether a property notification on the device actually requires a rebuild.
    ///
    /// CoreAudio announces sample-rate and stream-configuration changes generously — often
    /// several times for one switch, and sometimes for a "change" to the value the device
    /// already had. Rebuilding on every one would drop audio for nothing.
    ///
    /// - Parameter current: the shape read back from the device now; nil if it can't be read,
    ///   which is itself a reason to rebuild.
    public static func needsRebuild(running: StreamShape, current: StreamShape?) -> Bool {
        guard let current, current.isUsable else { return true }
        return current != running
    }
}

/// Paces restarts after a disruption, and decides when to stop trying.
///
/// The limit is a sliding window rather than a per-session count. A one-hour meeting should
/// survive the user's AirPods dropping and reconnecting three times; a device that is
/// flapping several times a second should not be chased forever. Both fall out of "at most
/// `maxAttempts` within `window` seconds".
///
/// Attempts back off, so that the gap while Bluetooth renegotiates — during which the system
/// default can briefly name a device that no longer exists — is waited out rather than spent.
///
/// Pure: the caller supplies the clock, so the checks can drive it without sleeping.
public struct RecoveryPolicy: Sendable, Equatable {
    public let maxAttempts: Int
    public let window: TimeInterval
    public let initialDelay: TimeInterval
    public let maxDelay: TimeInterval

    private var attempts: [TimeInterval] = []

    public init(
        maxAttempts: Int = 5,
        window: TimeInterval = 15,
        initialDelay: TimeInterval = 0.2,
        maxDelay: TimeInterval = 2
    ) {
        self.maxAttempts = maxAttempts
        self.window = window
        self.initialDelay = initialDelay
        self.maxDelay = maxDelay
    }

    /// Records an attempt at `now`.
    ///
    /// - Returns: how long to wait before rebuilding, or nil to give up.
    public mutating func nextDelay(at now: TimeInterval) -> TimeInterval? {
        attempts.removeAll { now - $0 >= window }
        guard attempts.count < maxAttempts else { return nil }
        let delay = min(maxDelay, initialDelay * pow(2, Double(attempts.count)))
        attempts.append(now)
        return delay
    }
}

/// Notices a capture that has gone quiet at the hardware level — no callbacks at all, which
/// is different from a silent room (silence still arrives as buffers of zeros).
///
/// Pure for the same reason `RecoveryPolicy` is.
public struct StallDetector: Sendable, Equatable {
    public let timeout: TimeInterval

    private var lastCount: UInt64 = 0
    private var lastProgress: TimeInterval

    /// - Parameter timeout: generous on purpose. Opening AirPods' microphone switches them
    ///   into headset mode, and the first buffer can take over a second to arrive.
    public init(timeout: TimeInterval = 3, now: TimeInterval) {
        self.timeout = timeout
        self.lastProgress = now
    }

    /// - Parameter callbacks: the capture's running count of audio callbacks.
    /// - Returns: true once no callback has arrived for `timeout` seconds.
    public mutating func isStalled(callbacks: UInt64, at now: TimeInterval) -> Bool {
        if callbacks != lastCount {
            lastCount = callbacks
            lastProgress = now
            return false
        }
        return now - lastProgress >= timeout
    }
}
