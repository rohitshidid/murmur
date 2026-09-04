import Foundation

/// Email shape: the greeting at the top and the sign-off at the bottom.
///
/// Both are the same trick. Spoken, they arrive as "hi sarah I wanted to check" and "thanks
/// rohit" — one flat line each. Written, they are a line of their own with a comma and a
/// break. Nothing is added and nothing is rewritten; the words the speaker said are simply
/// laid out the way an email lays them out.
///
/// This is why the feature is safe to run without a model watching it. Every transformation
/// here is punctuation and line breaks over words that were spoken, so it cannot change what
/// was said — with exactly one exception, `autoSignOff`, which appends a configured name to
/// a bare closing. That is opt-in for precisely that reason.
public enum SignOff {
    /// Closings people actually say. Longest first at match time.
    static let closings = [
        "thanks so much", "thanks again", "thanks a lot", "many thanks", "thank you so much",
        "thank you again", "thank you", "thanks",
        "best regards", "kind regards", "warm regards", "with regards", "regards", "best",
        "all the best", "take care", "talk soon", "speak soon", "talk to you soon",
        "sincerely", "yours sincerely", "yours truly", "cheers",
    ]

    static let greetings = [
        "good morning", "good afternoon", "good evening",
        "hi there", "hey there", "hello there",
        "hi", "hey", "hello", "dear",
    ]

    /// Words that follow a greeting often enough to be mistaken for a name.
    ///
    /// "Hi, I wanted to ask…" must not address someone called I. There is no way to know a
    /// name from the text alone, so the rule is inverted: anything on this list is not one.
    private static let notNames: Set<String> = [
        "i", "we", "you", "he", "she", "they", "it", "this", "that", "there", "here",
        "the", "a", "an", "just", "quick", "hope", "hoping", "sorry", "thanks", "thank",
        "can", "could", "would", "will", "should", "do", "did", "does", "is", "are", "was",
        "were", "am", "have", "has", "had", "let", "lets", "please", "wanted", "wanting",
        "following", "regarding", "per", "attached", "good", "happy", "how", "what", "when",
        "where", "why", "who", "all", "everyone", "team", "folks", "again", "so", "and",
    ]

    public static func apply(to text: String, options: StructureOptions) -> String {
        guard options.signOffEnabled, options.field == .emailBody, !text.isEmpty else {
            return text
        }
        var result = text
        result = applyGreeting(to: result, options: options)
        result = applyClosing(to: result, options: options)
        return result
    }

    // MARK: - Greeting

    private static func applyGreeting(to text: String, options: StructureOptions) -> String {
        // Only at the very top of an empty body. Halfway down an email "hi" is a word.
        guard CaretContinuation.isFieldEmpty(options.textBeforeCaret) else { return text }

        let pattern = "^\\s*(?<greeting>" + phraseAlternation(greetings)
            + ")(?![\\p{L}\\p{N}])[,.!]?\\s*(?<name>[\\p{L}][\\p{L}'\u{2019}-]*)?[,.!]?\\s*"
        guard let regex = Rx.make(pattern),
              let match = Rx.firstMatch(regex, in: text),
              let whole = Range(match.range, in: text),
              let greeting = Rx.text(match, text, named: "greeting")
        else { return text }

        let body = String(text[whole.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        var line = capitalized(greeting)

        if let name = Rx.text(match, text, named: "name"), isPlausibleName(name) {
            line += " " + capitalized(name)
        } else if let name = Rx.text(match, text, named: "name") {
            // The captured word was a false positive — it belongs to the sentence, so put it
            // back rather than dropping it on the floor.
            return greetingLine(capitalized(greeting), body: capitalized(name) + " " + body)
        }

        return greetingLine(line, body: body)
    }

    private static func greetingLine(_ line: String, body: String) -> String {
        guard !body.isEmpty else { return line + "," }
        return line + ",\n\n" + body
    }

    private static func isPlausibleName(_ word: String) -> Bool {
        word.count >= 2 && !notNames.contains(word.lowercased())
    }

    // MARK: - Closing

    private static func applyClosing(to text: String, options: StructureOptions) -> String {
        let names = options.userNames.filter { !$0.isEmpty }
        let namePattern = names.isEmpty ? "" : "\\s*[,]?\\s*(?<name>" + phraseAlternation(names) + ")"

        // Anchored to the end: a closing word only closes when nothing follows it.
        let pattern = "(?<lead>^|[.!?\\n]\\s*|,\\s*)(?<closing>" + phraseAlternation(closings)
            + ")(?![\\p{L}\\p{N}])[,.!]?" + (namePattern.isEmpty ? "" : "(?:\(namePattern))?")
            + "[,.!]?\\s*$"

        // Cut at the closing word itself rather than at the start of the whole match: the
        // match begins on the punctuation that ends the previous sentence, and taking that
        // with it strips the full stop off the body.
        guard let regex = Rx.make(pattern),
              let match = Rx.firstMatch(regex, in: text),
              let closingRange = Rx.range(match, text, named: "closing"),
              let closing = Rx.text(match, text, named: "closing")
        else { return text }

        let spokenName = names.isEmpty ? nil : Rx.text(match, text, named: "name")

        // A closing with no name and no configured fallback is just the last words of a
        // sentence — "thanks" on its own is a thing people say mid-email.
        let signature: String?
        if let spokenName {
            signature = canonical(spokenName, among: names)
        } else if options.autoSignOff {
            signature = names.first
        } else {
            signature = nil
        }
        guard let signature else { return text }

        let body = String(text[text.startIndex..<closingRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let block = capitalized(closing) + ",\n" + signature
        return body.isEmpty ? block : body + "\n\n" + block
    }

    /// Prefers the spelling the user configured over the one the engine transcribed, so
    /// "rohit" signs as "Rohit" without a capitalisation rule that would also hit surnames
    /// like "de Souza".
    private static func canonical(_ spoken: String, among names: [String]) -> String {
        names.first { $0.compare(spoken, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
            ?? capitalized(spoken)
    }

    // MARK: - Shared

    private static func phraseAlternation(_ phrases: [String]) -> String {
        phrases
            .sorted { ($0.count, $0) > ($1.count, $1) }
            .map { phrase in
                phrase.split(separator: " ")
                    .map { NSRegularExpression.escapedPattern(for: String($0)) }
                    .joined(separator: "\\s+")
            }
            .joined(separator: "|")
    }

    private static func capitalized(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }
}
