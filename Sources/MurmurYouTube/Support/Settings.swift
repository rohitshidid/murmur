import Foundation
import Observation

/// Which speech engine transcribes an utterance.
enum SpeechEngineChoice: String, CaseIterable, Sendable {
    case apple
    case parakeet

    var displayName: String {
        switch self {
        case .apple: "Apple (streaming)"
        case .parakeet: "Parakeet (batch)"
        }
    }

    /// Apple shows text while you talk; Parakeet only resolves on release.
    var showsLiveText: Bool { self == .apple }
}

@MainActor
@Observable
final class Settings {
    static let shared = Settings()

    var pushToTalkKey: PushToTalkKey {
        didSet { defaults.set(pushToTalkKey.rawValue, forKey: Keys.pushToTalkKey) }
    }

    /// Whether a quick tap of the push-to-talk key locks recording on until the next tap.
    ///
    /// On by default: holding a key down for a long thought is the thing that stops people
    /// dictating anything longer than a sentence. Off restores strict hold-to-talk.
    var latchOnTap: Bool {
        didSet { defaults.set(latchOnTap, forKey: Keys.latchOnTap) }
    }

    /// Which microphone to record from, by CoreAudio UID. `nil` follows the system default.
    ///
    /// Stored as a UID rather than an `AudioDeviceID` because ids are assigned at connect
    /// time and are reused — persisting one would eventually point at a different device.
    var inputDeviceUID: String? {
        didSet { defaults.set(inputDeviceUID, forKey: Keys.inputDeviceUID) }
    }

    /// Check each transcript against what's visible in the app you're dictating into, so
    /// filenames and symbols come out spelled the way they appear on screen.
    ///
    /// The screen text is read for one transcript and discarded — never written to disk,
    /// never added to history.
    var screenContext: Bool {
        didSet { defaults.set(screenContext, forKey: Keys.screenContext) }
    }

    var engine: SpeechEngineChoice {
        didSet { defaults.set(engine.rawValue, forKey: Keys.engine) }
    }


    /// Run the cleanup pass before injecting. Off = raw engine output.
    var cleanupEnabled: Bool {
        didSet { defaults.set(cleanupEnabled, forKey: Keys.cleanupEnabled) }
    }

    /// Use the on-device LLM for cleanup instead of the deterministic rule pass.
    var smartCleanup: Bool {
        didSet { defaults.set(smartCleanup, forKey: Keys.smartCleanup) }
    }

    /// Play a short tick when capture starts and stops.
    var soundEnabled: Bool {
        didSet { defaults.set(soundEnabled, forKey: Keys.soundEnabled) }
    }

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let pushToTalkKey = "pushToTalkKey"
        static let latchOnTap = "latchOnTap"
        static let inputDeviceUID = "inputDeviceUID"
        static let screenContext = "screenContext"
        static let cleanupEnabled = "cleanupEnabled"
        static let soundEnabled = "soundEnabled"
        static let engine = "engine"
        static let smartCleanup = "smartCleanup"
    }

    private init() {
        let raw = defaults.string(forKey: Keys.pushToTalkKey) ?? PushToTalkKey.rightCommand.rawValue
        pushToTalkKey = PushToTalkKey(rawValue: raw) ?? .rightCommand
        latchOnTap = defaults.object(forKey: Keys.latchOnTap) as? Bool ?? true
        inputDeviceUID = defaults.string(forKey: Keys.inputDeviceUID)
        screenContext = defaults.object(forKey: Keys.screenContext) as? Bool ?? true
        // Apple by default: no download, no dependency, live text while speaking.
        engine = SpeechEngineChoice(rawValue: defaults.string(forKey: Keys.engine) ?? "") ?? .apple
        cleanupEnabled = defaults.object(forKey: Keys.cleanupEnabled) as? Bool ?? true
        smartCleanup = defaults.object(forKey: Keys.smartCleanup) as? Bool ?? false
        soundEnabled = defaults.object(forKey: Keys.soundEnabled) as? Bool ?? true
    }
}
