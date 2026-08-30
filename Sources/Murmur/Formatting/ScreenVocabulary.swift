import MurmurDictionary
import Foundation

/// Turns text harvested off the screen into "when you hear X, write Y" pairs.
///
/// The job is narrow on purpose: find the **code-shaped** tokens on screen — `HUDPanel`,
/// `dictation_controller`, `MainWindow.swift`, `com.apple.mail` — work out how each one
/// would be *said*, and offer that as a correction. Say "hud panel dot swift" and get
/// `HUDPanel.swift`, because it was on your screen when you said it.
///
/// Everything here is shaped by one risk: rewriting ordinary speech into an identifier
/// because it happened to resemble something visible. Three rules keep that in check.
///
/// 1. **Code shape only.** A token has to look like code — a camel hump, an underscore, a
///    dot, a path separator. A plain word on screen is never a candidate, however often it
///    appears.
/// 2. **Never a single word.** A spoken form of one word is discarded, so no rule can ever
///    rewrite a lone ordinary word.
/// 3. **Something distinctive.** A two-word form made entirely of common English —
///    "get data", "for each" — is discarded too. Three or more words, or at least one word
///    that isn't ordinary English, is the bar.
enum ScreenVocabulary {
    /// How many pairs to compile. Post-hoc matching can't make the model hallucinate the
    /// way priming can, so this cap is about time spent matching, not accuracy.
    static let limit = 250

    /// - Parameter strings: raw text from `ScreenHarvester`, most significant first.
    /// - Returns: pairs ready for `DictionaryCorrector(matching:reportedAs:)`.
    static func pairs(from strings: [String]) -> [(hear: String, write: String)] {
        var scores: [String: Int] = [:]

        for (index, text) in strings.enumerated() {
            // Earlier strings are the window title and the focused element — the file you
            // are actually in — so they outrank the same token appearing deep in a tree.
            let weight = index == 0 ? 10 : 1
            for token in identifiers(in: text) {
                scores[token, default: 0] += weight
            }
        }

        var seen = Set<String>()
        var result: [(hear: String, write: String)] = []

        for token in scores.keys.sorted(by: { (scores[$0] ?? 0, $0.count) > (scores[$1] ?? 0, $1.count) }) {
            for spoken in spokenForms(for: token) {
                guard isUsable(spoken) else { continue }
                // First writer wins: the highest-scoring identifier keeps the phrase.
                guard seen.insert(spoken).inserted else { continue }
                result.append((hear: spoken, write: token))
                if result.count >= limit { return result }
            }
        }

        return result
    }

    // MARK: - Extraction

    /// Characters that can be part of an identifier. Everything else is a separator.
    private static let identifierCharacters = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-/"
    )

    static func identifiers(in text: String) -> [String] {
        text
            .components(separatedBy: identifierCharacters.inverted)
            .flatMap { candidate -> [String] in
                // A path contributes its leaf as well as itself: people say "main dot
                // swift", not the whole path they can see in the tab bar.
                guard candidate.contains("/") else { return [candidate] }
                let leaf = candidate.split(separator: "/").last.map(String.init) ?? ""
                return [candidate, leaf]
            }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".-/_")) }
            .filter(isCodeShaped)
    }

    /// Whether a token looks like code rather than like a word.
    static func isCodeShaped(_ token: String) -> Bool {
        guard token.count >= 3, token.count <= 80 else { return false }
        // Must contain a letter — version numbers and timestamps are not identifiers.
        guard token.contains(where: \.isLetter) else { return false }

        if token.contains("_") { return true }

        // A dot between two alphanumerics: `main.swift`, `com.apple.mail`, `foo.bar`.
        if token.range(of: "[A-Za-z0-9]\\.[A-Za-z0-9]", options: .regularExpression) != nil {
            return true
        }

        // A camel hump: `startRecording`, `mainWindow`.
        if token.range(of: "[a-z0-9][A-Z]", options: .regularExpression) != nil { return true }

        // An acronym run followed by a word: `HUDPanel`, `URLSession`, `ASRResult`. These
        // have no lowercase-to-uppercase transition at all, so the check above misses them
        // — and they are exactly the identifiers a codebase full of initialisms is made of.
        if token.range(of: "[A-Z]{2}[a-z]", options: .regularExpression) != nil { return true }

        // A hyphen only counts alongside another code signal, which the checks above would
        // already have caught — an ordinary hyphenated word like "well-known" is not code.
        return false
    }

    // MARK: - Spoken forms

    /// How a token would be read aloud. Dotted tokens get two forms, because people say
    /// both "main swift" and "main dot swift".
    static func spokenForms(for token: String) -> [String] {
        let words = self.words(in: token)
        guard words.count >= 2 else { return [] }

        var forms = [words.joined(separator: " ")]

        if token.contains(".") {
            let spelled = token
                .split(separator: ".", omittingEmptySubsequences: true)
                .map { self.words(in: String($0)).joined(separator: " ") }
                .joined(separator: " dot ")
            if spelled != forms[0] { forms.append(spelled) }
        }

        return forms
    }

    /// Splits an identifier into its spoken words.
    ///
    /// The camel split has to handle acronym runs: `HUDPanel` is "hud panel", not
    /// "h u d panel", and `URLSession` is "url session". That means breaking between a
    /// lowercase or digit and an uppercase, *and* between an uppercase and an uppercase
    /// followed by a lowercase.
    static func words(in token: String) -> [String] {
        let separated = token
            .replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression)
            .replacingOccurrences(of: "([A-Z]+)([A-Z][a-z])", with: "$1 $2", options: .regularExpression)
            .replacingOccurrences(of: "[._\\-/]+", with: " ", options: .regularExpression)

        return separated
            .split(whereSeparator: \.isWhitespace)
            .map { $0.lowercased() }
            .filter { !$0.isEmpty }
    }

    /// Rejects spoken forms that would be dangerous to match against ordinary speech.
    static func isUsable(_ spoken: String) -> Bool {
        let words = spoken.split(separator: " ").map(String.init)
        guard words.count >= 2 else { return false }
        if words.count >= 3 { return true }
        // Two words: at least one has to be something you wouldn't say by accident.
        return words.contains { !ordinary.contains($0) }
    }

    /// Words common enough that a two-word phrase made only of them is far more likely to
    /// be speech than a reference to a symbol.
    ///
    /// Deliberately weighted toward the English that also shows up in code — `get`, `set`,
    /// `data`, `value`, `item` — because those are exactly the pairs that misfire.
    private static let ordinary: Set<String> = [
        "a", "add", "all", "and", "any", "app", "are", "as", "at", "back", "base", "be",
        "body", "by", "call", "can", "case", "check", "class", "clear", "close", "code",
        "color", "count", "data", "date", "day", "delete", "do", "down", "edit", "end",
        "error", "event", "file", "find", "first", "for", "from", "full", "get", "go",
        "group", "has", "have", "help", "here", "hide", "id", "if", "in", "index", "info",
        "input", "is", "it", "item", "key", "kind", "last", "left", "length", "line",
        "link", "list", "load", "log", "main", "make", "map", "mark", "max", "menu", "min",
        "mode", "more", "move", "name", "new", "next", "no", "not", "now", "of", "off",
        "on", "one", "only", "open", "or", "order", "out", "page", "path", "print", "put",
        "read", "right", "row", "run", "save", "search", "see", "select", "send", "set",
        "show", "side", "size", "sort", "start", "state", "stop", "style", "tab", "take",
        "test", "text", "the", "then", "this", "time", "title", "to", "top", "type", "up",
        "update", "url", "use", "user", "value", "view", "was", "when", "which", "width",
        "with", "work", "write", "you", "your",
    ]
}
