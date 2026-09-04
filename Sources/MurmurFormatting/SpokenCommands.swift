import Foundation

/// Things you say to shape the text rather than to be part of it.
///
/// These run on the raw transcript, before any cleanup pass, for two reasons. The rules
/// have to see the words exactly as spoken — a cleanup model will happily rewrite "new
/// paragraph" into prose — and the structure they produce is what the cleanup pass is then
/// told to preserve.
///
/// The list is deliberately short and multi-word. Bare "comma", "period" and "dash" are
/// absent: they are ordinary English, they appear in ordinary sentences, and a dictation
/// tool that cannot type the word "dash" is worse than one that needs you to say "em dash".
public enum SpokenCommands {
    /// Phrase → literal replacement. Longer phrases match first, which `Rx.phrases` handles.
    static let punctuation: [(phrases: [String], replacement: String)] = [
        (["new paragraph"], "\n\n"),
        (["new line", "next line"], "\n"),
        (["open paren", "open parenthesis"], " ("),
        (["close paren", "close parenthesis"], ") "),
        (["open quote"], " \u{201C}"),
        (["close quote"], "\u{201D} "),
        (["question mark"], "? "),
        (["exclamation mark", "exclamation point"], "! "),
        (["em dash"], " \u{2014} "),
        (["ellipsis", "dot dot dot"], "\u{2026} "),
        (["percent sign"], "% "),
        (["at sign"], " @ "),
    ]

    /// The four spoken punctuation rules that predate this module, kept as their own list so
    /// `RuleBasedFormatter` goes on applying exactly those when it runs standalone.
    public static let legacyPunctuation: [(String, String)] = [
        ("new paragraph", "\n\n"),
        ("new line", "\n"),
        ("open paren", " ("),
        ("close paren", ") "),
    ]

    /// Starts a new list item in whatever style the destination uses.
    static let neutralItemMarkers = ["next point", "next item", "new item"]

    /// Starts a new item and insists on a bullet, whatever the destination prefers.
    static let bulletMarkers = ["bullet point", "new bullet", "next bullet"]

    /// Leaves list mode. Emits a paragraph break so the following sentence isn't read as
    /// another item.
    static let listTerminators = ["end list", "end of list", "end the list"]

    static let spokenNumbers: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "eleven": 11, "twelve": 12,
    ]

    /// - Parameter startingItemNumber: what a neutral "next item" should be numbered, so a
    ///   list continued below one already in the field carries on counting.
    public static func apply(
        to text: String,
        options: StructureOptions,
        startingItemNumber: Int = 1
    ) -> String {
        guard options.commandsEnabled, !text.isEmpty else { return text }

        var result = text
        for rule in punctuation {
            result = Rx.replacing(
                Rx.phrases(rule.phrases),
                in: result,
                with: NSRegularExpression.escapedTemplate(for: rule.replacement)
            )
        }

        result = applyItemMarkers(to: result, options: options, startingItemNumber: startingItemNumber)
        result = applyCasing(to: result)

        // Every replacement above is written with padding so it reads correctly whatever it
        // lands next to, which leaves spaces stranded around the line breaks. Tidied here
        // rather than left for the cleanup pass, because the cleanup pass is optional.
        result = Rx.replacing("[ \\t]*\\n[ \\t]*", in: result, with: "\n")
        result = Rx.replacing("\\n{3,}", in: result, with: "\n\n")
        result = Rx.replacing("[ \\t]{2,}", in: result, with: " ")

        // A newline in a single-line field is a submit, not a line break — it sends the
        // half-written message. Everything above is still worth running there; only the
        // line breaks have to be walked back.
        if !options.field.allowsLineBreaks {
            result = Rx.replacing("\\s*\\n+\\s*", in: result, with: " ")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - List items

    private static func applyItemMarkers(
        to text: String,
        options: StructureOptions,
        startingItemNumber: Int
    ) -> String {
        let numberWords = spokenNumbers.keys
            .sorted { ($0.count, $0) > ($1.count, $1) }
            .joined(separator: "|")
        let pattern = [
            "(?<neutral>" + Rx.phrases(neutralItemMarkers) + ")",
            "(?<bullet>" + Rx.phrases(bulletMarkers) + ")",
            "(?<terminator>" + Rx.phrases(listTerminators) + ")",
            "(?<numbered>" + Rx.phrases(["number", "item number", "point number"])
                + "\\s+(?<word>" + numberWords + ")(?![\\p{L}\\p{N}]))",
        ].joined(separator: "|")

        guard let regex = Rx.make(pattern) else { return text }

        var counter = startingItemNumber
        return rewrite(text, regex) { match, source in
            if match.range(withName: "terminator").location != NSNotFound {
                return "\n\n"
            }
            if match.range(withName: "bullet").location != NSNotFound {
                counter += 1
                return "\n\u{2022} "
            }
            if match.range(withName: "numbered").location != NSNotFound {
                let spoken = Rx.text(match, source, named: "word")?.lowercased()
                let value = spoken.flatMap { spokenNumbers[$0] } ?? counter
                counter = value + 1
                return "\n\(value). "
            }
            // Neutral: the destination decides. `.none` means the profile has lists off, but
            // an explicit spoken command is not an inference — the speaker asked for a list,
            // so give them the least presumptuous marker rather than nothing.
            let style = options.listStyle == .none ? ListMarkerStyle.bullet : options.listStyle
            let marker = style.marker(at: counter)
            counter += 1
            return "\n" + marker
        }
    }

    // MARK: - Casing

    private static func applyCasing(to text: String) -> String {
        var result = text

        // "all caps deadline" -> "DEADLINE"
        if let regex = Rx.make("(?<![\\p{L}\\p{N}])all\\s+caps\\s+(?<word>[\\p{L}\\p{N}'\u{2019}-]+)") {
            result = rewrite(result, regex) { match, source in
                Rx.text(match, source, named: "word")?.uppercased()
            }
        }

        // "murmur cap that" -> "Murmur"
        if let regex = Rx.make("(?<word>[\\p{L}][\\p{L}'\u{2019}-]*)\\s+cap\\s+that(?![\\p{L}\\p{N}])") {
            result = rewrite(result, regex) { match, source in
                guard let word = Rx.text(match, source, named: "word") else { return nil }
                return word.prefix(1).uppercased() + word.dropFirst()
            }
        }

        return result
    }

    /// Rebuilds the string front to back, substituting each match.
    ///
    /// Front to back rather than the usual reverse-order in-place edit because these
    /// replacements are stateful — the list counter advances as it goes — and because
    /// mutating one string through indices taken from another is only accidentally correct.
    static func rewrite(
        _ text: String,
        _ regex: NSRegularExpression,
        _ replacement: (NSTextCheckingResult, String) -> String?
    ) -> String {
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return text }

        var result = ""
        var cursor = text.startIndex
        for match in matches {
            guard let range = Range(match.range, in: text), range.lowerBound >= cursor else { continue }
            result += text[cursor..<range.lowerBound]
            result += replacement(match, text) ?? String(text[range])
            cursor = range.upperBound
        }
        result += text[cursor...]
        return result
    }
}
