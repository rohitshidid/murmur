import AppKit
import Foundation
import Observation

/// Where a transcript is about to land, and how it should read when it gets there.
///
/// The same sentence wants to be a paragraph in Mail, one lowercase line in Slack, and a
/// bare comment in an editor. Nothing but the destination app can tell you which.
struct FormatContext: Sendable {
    /// The app the text will be injected into, resolved at injection time.
    let bundleID: String?
    let appName: String?
    /// The tone instruction for that app, already resolved from built-ins and overrides.
    let instruction: String

    /// The destination-free context, used by tests and by any path with no focused app.
    static let none = FormatContext(bundleID: nil, appName: nil, instruction: "")

    /// Reads the app that currently has focus.
    ///
    /// Safe to call while the HUD is on screen precisely because `HUDPanel` is a
    /// non-activating panel — focus never left the user's app, so "frontmost" is still
    /// the app the text is going into.
    @MainActor
    static func current() -> FormatContext {
        let app = NSWorkspace.shared.frontmostApplication
        let bundleID = app?.bundleIdentifier
        return FormatContext(
            bundleID: bundleID,
            appName: app?.localizedName,
            instruction: ProfileStore.shared.instruction(for: bundleID)
        )
    }
}

/// A tone rule for one app, or for everything without a rule of its own.
///
/// **Instructions must be subtractive or structural, never additive.** The cleanup guard in
/// `FoundationModelFormatter` rejects any output containing content words that weren't
/// spoken — so an instruction like "add a greeting" doesn't produce a friendlier email, it
/// produces a rejected response and a silent fall back to the rule-based pass. Say how to
/// shape what was said; never ask for anything new.
struct AppProfile: Codable, Identifiable, Hashable, Sendable {
    /// The bundle identifier this applies to. Empty means the global default.
    var bundleID: String
    /// What to call it in Settings.
    var name: String
    /// Appended to the cleanup instructions when this profile is the match.
    var instruction: String

    var id: String { bundleID }
    var isGlobal: Bool { bundleID.isEmpty }
}

/// The built-in profiles and the user's overrides.
///
/// Built-ins mean the feature works on first launch instead of needing to be configured
/// into existence; overrides mean a wrong guess about an app you use daily is fixable.
@MainActor
@Observable
final class ProfileStore {
    static let shared = ProfileStore()

    /// Edits keyed by bundle ID. An entry here replaces the built-in instruction, and an
    /// entry with no built-in behind it is a profile the user added.
    private(set) var overrides: [String: AppProfile] = [:]

    private let defaults = UserDefaults.standard
    private static let key = "appProfiles"

    private init() {
        if let data = defaults.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([String: AppProfile].self, from: data) {
            overrides = decoded
        }
    }

    /// Every profile Settings should show: the built-ins, with overrides applied, plus any
    /// app the user added.
    var all: [AppProfile] {
        var result = Self.builtIn.map { overrides[$0.bundleID] ?? $0 }
        let builtInIDs = Set(Self.builtIn.map(\.bundleID))
        result.append(contentsOf: overrides.values.filter { !builtInIDs.contains($0.bundleID) })
        // Global first, then alphabetical — the default is the one you read first.
        return result.sorted {
            if $0.isGlobal != $1.isGlobal { return $0.isGlobal }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func save(_ profile: AppProfile) {
        overrides[profile.bundleID] = profile
        persist()
    }

    /// Drops an override. A built-in reverts to its shipped instruction; a user-added
    /// profile disappears.
    func reset(_ bundleID: String) {
        overrides.removeValue(forKey: bundleID)
        persist()
    }

    func isOverridden(_ bundleID: String) -> Bool { overrides[bundleID] != nil }

    /// The instruction for one app: its own profile, else a family match, else the global
    /// default.
    func instruction(for bundleID: String?) -> String {
        guard let bundleID, !bundleID.isEmpty else { return global.instruction }

        if let exact = overrides[bundleID] ?? Self.builtIn.first(where: { $0.bundleID == bundleID }) {
            return exact.instruction
        }
        if let family = Self.families.first(where: { family in
            family.matches.contains { bundleID.localizedCaseInsensitiveContains($0) }
        }) {
            // A user override on the family's representative profile applies to the whole
            // family, which is what makes "fix how it writes in chat apps" a single edit.
            return (overrides[family.bundleID]
                ?? Self.builtIn.first { $0.bundleID == family.bundleID })?.instruction
                ?? global.instruction
        }
        return global.instruction
    }

    private var global: AppProfile {
        overrides[""] ?? Self.builtIn[0]
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(overrides) else { return }
        defaults.set(data, forKey: Self.key)
    }

    // MARK: - Built-ins

    /// A family is matched by substring against the bundle ID, which is how one entry can
    /// cover Slack, Discord and Messages without listing every chat app ever shipped.
    private struct Family {
        /// The profile whose instruction the family uses, and which an override edits.
        let bundleID: String
        let matches: [String]
    }

    private static let families: [Family] = [
        Family(bundleID: "com.apple.mail", matches: ["mail", "outlook", "sparkmailapp", "airmail", "superhuman"]),
        Family(bundleID: "com.tinyspeck.slackmacgap", matches: ["slack", "discord", "messages", "whatsapp", "telegram", "signal"]),
        Family(bundleID: "com.microsoft.VSCode", matches: ["vscode", "cursor", "xcode", "jetbrains", "intellij", "zed", "sublime", "terminal", "iterm", "ghostty", "warp"]),
        Family(bundleID: "com.apple.Notes", matches: ["notes", "obsidian", "bear", "notion", "craft", "word", "pages", "things", "linear"]),
    ]

    /// The global default is first, and is the only entry that must exist.
    static let builtIn: [AppProfile] = [
        AppProfile(
            bundleID: "",
            name: "Everywhere else",
            instruction: ""
        ),
        AppProfile(
            bundleID: "com.apple.mail",
            name: "Mail",
            instruction: "This is going into an email. Write it as complete sentences in "
                + "paragraphs, with standard punctuation. Keep contractions as spoken."
        ),
        AppProfile(
            bundleID: "com.tinyspeck.slackmacgap",
            name: "Chat",
            instruction: "This is going into a chat message. Keep it to one or two short "
                + "lines. No sign-off and no salutation. Do not add a closing sentence."
        ),
        AppProfile(
            bundleID: "com.microsoft.VSCode",
            name: "Code editors & terminals",
            instruction: "This is going into a code editor or terminal. Keep it terse. "
                + "Leave identifiers, file paths, flags and command names exactly as spoken, "
                + "including their capitalization. Do not add trailing punctuation to a line "
                + "that reads as code."
        ),
        AppProfile(
            bundleID: "com.apple.Notes",
            name: "Notes & documents",
            instruction: "This is going into a document. Use paragraph breaks where the "
                + "speaker paused between thoughts, and format a spoken list as a list."
        ),
    ]
}
