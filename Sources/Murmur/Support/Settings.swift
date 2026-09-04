import AppKit
import Foundation
import MurmurFormatting
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

    // MARK: - Structure

    /// Read which field the text is going into, and what is already in front of the caret.
    ///
    /// Separate from `screenContext`, which reads the whole window looking for vocabulary.
    /// This is one element and a handful of attributes, and turning it off costs the
    /// difference between knowing you're in Mail and knowing you're in Mail's subject line.
    var fieldContext: Bool {
        didSet { defaults.set(fieldContext, forKey: Keys.fieldContext) }
    }

    /// Spoken structure commands — "new paragraph", "bullet point", "all caps".
    var voiceCommands: Bool {
        didSet { defaults.set(voiceCommands, forKey: Keys.voiceCommands) }
    }

    /// Take back what was said before "scratch that".
    var retraction: Bool {
        didSet { defaults.set(retraction, forKey: Keys.retraction) }
    }

    var retractionScope: RetractionScope {
        didSet { defaults.set(retractionScope.rawValue, forKey: Keys.retractionScope) }
    }

    /// Extra retraction phrases, on top of the built-in list.
    var extraRetractionPhrases: [String] {
        didSet { defaults.set(extraRetractionPhrases, forKey: Keys.extraRetractionPhrases) }
    }

    /// Recognise a list read out loud and mark it up.
    var smartLists: Bool {
        didSet { defaults.set(smartLists, forKey: Keys.smartLists) }
    }

    /// Lay a greeting and a sign-off out the way an email lays them out.
    var emailShape: Bool {
        didSet { defaults.set(emailShape, forKey: Keys.emailShape) }
    }

    /// Append the configured name to a closing that didn't include one.
    var autoSignOff: Bool {
        didSet { defaults.set(autoSignOff, forKey: Keys.autoSignOff) }
    }

    /// How the user signs their name. Prefilled from the macOS account, because that is
    /// right often enough to be worth not asking, and wrong often enough to be editable.
    var userName: String {
        didSet { defaults.set(userName, forKey: Keys.userName) }
    }

    /// Every form of the name a sign-off might use, longest first.
    ///
    /// "Rohit Shidid" and "Rohit" both have to match, and the longer one has to be tried
    /// first or "Thanks Rohit Shidid" signs itself "Rohit" and leaves a stray surname.
    var signatureNames: [String] {
        let trimmed = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let first = trimmed.split(separator: " ").first.map(String.init)
        return [trimmed, first].compactMap { $0 }.reduced()
    }

    /// Let the on-device model repair grammar as well as clean up, at the cost of being
    /// allowed to change words.
    ///
    /// Off by default and dependent on `smartCleanup`: this is the one pass that may write
    /// something other than what was said, so it is opted into rather than out of.
    var polishEnabled: Bool {
        didSet { defaults.set(polishEnabled, forKey: Keys.polishEnabled) }
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
        static let fieldContext = "fieldContext"
        static let voiceCommands = "voiceCommands"
        static let retraction = "retraction"
        static let retractionScope = "retractionScope"
        static let extraRetractionPhrases = "extraRetractionPhrases"
        static let smartLists = "smartLists"
        static let emailShape = "emailShape"
        static let autoSignOff = "autoSignOff"
        static let userName = "userName"
        static let polishEnabled = "polishEnabled"
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

        fieldContext = defaults.object(forKey: Keys.fieldContext) as? Bool ?? true
        voiceCommands = defaults.object(forKey: Keys.voiceCommands) as? Bool ?? true
        retraction = defaults.object(forKey: Keys.retraction) as? Bool ?? true
        retractionScope = RetractionScope(rawValue: defaults.string(forKey: Keys.retractionScope) ?? "")
            ?? .sentence
        extraRetractionPhrases = defaults.stringArray(forKey: Keys.extraRetractionPhrases) ?? []
        smartLists = defaults.object(forKey: Keys.smartLists) as? Bool ?? true
        emailShape = defaults.object(forKey: Keys.emailShape) as? Bool ?? true
        autoSignOff = defaults.object(forKey: Keys.autoSignOff) as? Bool ?? true
        userName = defaults.string(forKey: Keys.userName) ?? NSFullUserName()
        // Off by default: the only pass allowed to write a word the speaker didn't say.
        polishEnabled = defaults.object(forKey: Keys.polishEnabled) as? Bool ?? false
    }
}

private extension Array where Element == String {
    /// Drops duplicates and empties while keeping order.
    func reduced() -> [String] {
        var seen = Set<String>()
        return filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
}
