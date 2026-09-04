import Foundation

/// A group of apps that want the same register.
///
/// This exists twice over: `ProfileStore` uses it so one tone rule covers every chat app
/// without listing them, and `FieldHarvester` uses it to work out whether a text area is an
/// email body or just a text area.
///
/// The host matching is the part that earns its keep. A bundle ID identifies Mail and
/// Slack, but every browser is a single bundle ID standing in for a hundred destinations —
/// so Gmail, which is how most people actually write email, looked exactly like a search
/// engine. Matching the page's host first fixes that, and costs one Accessibility read.
enum AppFamily: String, CaseIterable, Sendable {
    case mail
    case chat
    case code
    case notes

    /// The built-in profile whose instruction this family uses, and which a user override
    /// edits for the whole family at once.
    var profileBundleID: String {
        switch self {
        case .mail: "com.apple.mail"
        case .chat: "com.tinyspeck.slackmacgap"
        case .code: "com.microsoft.VSCode"
        case .notes: "com.apple.Notes"
        }
    }

    private var bundleMatches: [String] {
        switch self {
        case .mail: ["mail", "outlook", "sparkmailapp", "airmail", "superhuman", "canary"]
        case .chat: ["slack", "discord", "messages", "whatsapp", "telegram", "signal", "teams"]
        case .code:
            ["vscode", "cursor", "xcode", "jetbrains", "intellij", "zed", "sublime", "nova",
             "terminal", "iterm", "ghostty", "warp", "alacritty", "kitty", "wezterm"]
        case .notes:
            ["notes", "obsidian", "bear", "notion", "craft", "word", "pages", "things",
             "linear", "drafts", "ulysses"]
        }
    }

    /// Web hosts, matched before bundle IDs so a browser resolves to what's on the page.
    private var hostMatches: [String] {
        switch self {
        case .mail:
            ["mail.google.com", "outlook.office", "outlook.live", "mail.yahoo",
             "superhuman.com", "mail.proton", "mail.zoho", "fastmail.com", "app.hey.com"]
        case .chat:
            ["slack.com", "discord.com", "web.whatsapp.com", "teams.microsoft.com",
             "messenger.com", "web.telegram.org", "chat.google.com"]
        case .code:
            ["vscode.dev", "github.dev", "replit.com", "codesandbox.io", "stackblitz.com"]
        case .notes:
            ["notion.so", "docs.google.com", "linear.app", "coda.io", "quip.com",
             "app.asana.com", "atlassian.net"]
        }
    }

    /// - Parameter host: the page's host when the destination is a browser, else nil.
    static func of(bundleID: String?, host: String? = nil) -> AppFamily? {
        if let host = host?.lowercased(), !host.isEmpty,
           let match = allCases.first(where: { family in
               family.hostMatches.contains { host.contains($0) }
           }) {
            return match
        }
        guard let bundleID = bundleID?.lowercased(), !bundleID.isEmpty else { return nil }
        return allCases.first { family in
            family.bundleMatches.contains { bundleID.contains($0) }
        }
    }

    /// Terminals live in the code family for tone, but they are not text editors — a
    /// terminal has no notion of a line you can go back and fix, so nothing structural
    /// should ever be typed into one.
    static func isTerminal(bundleID: String?) -> Bool {
        guard let bundleID = bundleID?.lowercased() else { return false }
        return ["terminal", "iterm", "ghostty", "warp", "alacritty", "kitty", "wezterm", "tabby"]
            .contains { bundleID.contains($0) }
    }

    static func isBrowser(bundleID: String?) -> Bool {
        guard let bundleID = bundleID?.lowercased() else { return false }
        return ["chrome", "safari", "firefox", "arc", "brave", "edge", "opera", "vivaldi", "orion", "dia"]
            .contains { bundleID.contains($0) }
    }
}
