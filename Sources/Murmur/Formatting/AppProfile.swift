import AppKit
import Foundation
import MurmurFormatting
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
    /// Which field inside that app, and what is already in front of the caret.
    let field: FieldSnapshot
    /// How this destination marks a list.
    let listStyle: ListMarkerStyle
    /// Whether the grammar-repair pass may run here.
    let polish: Bool

    /// The destination-free context, used by tests and by any path with no focused app.
    static let none = FormatContext(
        bundleID: nil,
        appName: nil,
        instruction: "",
        field: .unknown,
        listStyle: .numbered,
        polish: false
    )

    /// Reads the app that currently has focus.
    ///
    /// Safe to call while the HUD is on screen precisely because `HUDPanel` is a
    /// non-activating panel — focus never left the user's app, so "frontmost" is still
    /// the app the text is going into.
    ///
    /// - Parameter field: read off the main actor while transcription was still running, so
    ///   the Accessibility calls don't land in the gap between release and injection.
    @MainActor
    static func current(field: FieldSnapshot = .unknown) -> FormatContext {
        let app = NSWorkspace.shared.frontmostApplication
        let bundleID = app?.bundleIdentifier
        let profile = ProfileStore.shared.profile(for: bundleID, host: field.host)
        return FormatContext(
            bundleID: bundleID,
            appName: app?.localizedName,
            instruction: profile.instruction,
            field: field,
            listStyle: profile.listStyle,
            polish: profile.polish
        )
    }

    /// Everything the deterministic structure pass needs, assembled from the destination and
    /// the user's settings.
    @MainActor
    var structureOptions: StructureOptions {
        let settings = Settings.shared
        return StructureOptions(
            field: field.kind,
            listStyle: listStyle,
            retractionScope: settings.retractionScope,
            commandsEnabled: settings.voiceCommands,
            listsEnabled: settings.smartLists,
            retractionEnabled: settings.retraction,
            signOffEnabled: settings.emailShape,
            autoSignOff: settings.autoSignOff,
            userNames: settings.signatureNames,
            extraRetractionPhrases: settings.extraRetractionPhrases,
            textBeforeCaret: field.textBeforeCaret
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
    /// How a spoken list is marked here. `.none` turns list detection off for this app.
    var listStyle: ListMarkerStyle
    /// Whether the grammar-repair pass may run here. On everywhere by default; this is the
    /// switch for the apps where being rewritten is unwelcome.
    var polish: Bool

    var id: String { bundleID }
    var isGlobal: Bool { bundleID.isEmpty }

    init(
        bundleID: String,
        name: String,
        instruction: String,
        listStyle: ListMarkerStyle = .numbered,
        polish: Bool = true
    ) {
        self.bundleID = bundleID
        self.name = name
        self.instruction = instruction
        self.listStyle = listStyle
        self.polish = polish
    }

    /// Hand-written because Swift's synthesized decoder throws on a missing key rather than
    /// using the property's default — and profiles saved before these two fields existed are
    /// sitting in every existing install's user defaults.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bundleID = try container.decode(String.self, forKey: .bundleID)
        name = try container.decode(String.self, forKey: .name)
        instruction = try container.decode(String.self, forKey: .instruction)
        listStyle = try container.decodeIfPresent(ListMarkerStyle.self, forKey: .listStyle) ?? .numbered
        polish = try container.decodeIfPresent(Bool.self, forKey: .polish) ?? true
    }
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

    /// The profile for one destination: its own entry, else its family's, else the global
    /// default.
    ///
    /// - Parameter host: the page's host when the destination is a browser. Checked before
    ///   the bundle ID, because one browser bundle covers Gmail, Linear and everything else,
    ///   and the page is what the writing is actually going into.
    func profile(for bundleID: String?, host: String? = nil) -> AppProfile {
        if let exact = bundleID, !exact.isEmpty,
           let match = overrides[exact] ?? Self.builtIn.first(where: { $0.bundleID == exact }) {
            return match
        }
        if let family = AppFamily.of(bundleID: bundleID, host: host) {
            // A user override on the family's representative profile applies to the whole
            // family, which is what makes "fix how it writes in chat apps" a single edit.
            if let match = overrides[family.profileBundleID]
                ?? Self.builtIn.first(where: { $0.bundleID == family.profileBundleID }) {
                return match
            }
        }
        return global
    }

    /// The instruction for one app. Kept as its own entry point because most callers want
    /// only this.
    func instruction(for bundleID: String?, host: String? = nil) -> String {
        profile(for: bundleID, host: host).instruction
    }

    private var global: AppProfile {
        overrides[""] ?? Self.builtIn[0]
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(overrides) else { return }
        defaults.set(data, forKey: Self.key)
    }

    // MARK: - Built-ins

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
                + "lines. No sign-off and no salutation. Do not add a closing sentence.",
            listStyle: .bullet
        ),
        AppProfile(
            bundleID: "com.microsoft.VSCode",
            name: "Code editors & terminals",
            instruction: "This is going into a code editor or terminal. Keep it terse. "
                + "Leave identifiers, file paths, flags and command names exactly as spoken, "
                + "including their capitalization. Do not add trailing punctuation to a line "
                + "that reads as code.",
            // No lists: an identifier is not a sentence. Polish stays on, like every other
            // profile — a code editor is also where release notes and commit messages get
            // written, and turning it off there by default guesses at which of those you're
            // doing.
            listStyle: .none
        ),
        AppProfile(
            bundleID: "com.apple.Notes",
            name: "Notes & documents",
            instruction: "This is going into a document. Use paragraph breaks where the "
                + "speaker paused between thoughts, and format a spoken list as a list."
        ),
    ]
}
