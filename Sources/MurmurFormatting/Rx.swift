import Foundation

/// Regex plumbing shared by the structure passes.
///
/// Every pattern in this module stays inside the subset that behaves identically in ICU and
/// .NET — `\b`-style boundaries written as fixed-length lookarounds, character classes,
/// alternation, named groups, lookahead and fixed-length lookbehind. That constraint is the
/// same one `MurmurDictionary` lives under and for the same reason: the Windows app
/// reimplements this logic in C# against the same vectors, and a pattern that only works in
/// one engine is a silent divergence.
enum Rx {
    static func make(_ pattern: String, _ options: NSRegularExpression.Options = [.caseInsensitive]) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: options)
    }

    /// A word-boundary-safe alternation over spoken phrases.
    ///
    /// Three things make this different from joining the phrases with `|`:
    ///
    /// - **Longest first**, so "scratch all that" is never matched as "scratch that" with
    ///   stray words around it.
    /// - **Flexible whitespace**, because a transcript may glue or split the words.
    /// - **Both apostrophes**, because speech engines emit `’` and hand-written settings
    ///   contain `'`, and a phrase list that only spells one of them silently half-works.
    static func phrases(_ phrases: [String]) -> String {
        let alternatives = phrases
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted { ($0.count, $0) > ($1.count, $1) }
            .map { phrase in
                phrase
                    .split(separator: " ")
                    .map { NSRegularExpression.escapedPattern(for: String($0)) }
                    .joined(separator: "\\s+")
                    .replacingOccurrences(of: "'", with: "['\u{2019}]")
            }
            .joined(separator: "|")
        // A word character on either side means this is part of a longer word, not the
        // phrase. Both lookarounds are fixed length, which .NET requires for lookbehind.
        return "(?<![\\p{L}\\p{N}'\u{2019}])(?:\(alternatives))(?![\\p{L}\\p{N}'\u{2019}])"
    }

    static func range(_ match: NSTextCheckingResult, _ index: Int, in text: String) -> Range<String.Index>? {
        Range(match.range(at: index), in: text)
    }

    static func text(_ match: NSTextCheckingResult, _ index: Int, in text: String) -> String? {
        guard let range = range(match, index, in: text) else { return nil }
        return String(text[range])
    }

    static func firstMatch(_ regex: NSRegularExpression?, in text: String) -> NSTextCheckingResult? {
        guard let regex else { return nil }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }

    static func matches(_ regex: NSRegularExpression?, in text: String) -> [NSTextCheckingResult] {
        guard let regex else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    static func replacing(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = make(pattern) else { return text }
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: template
        )
    }
}

extension Rx {
    /// A named capture group's range, or nil when the group didn't participate.
    static func range(_ match: NSTextCheckingResult, _ source: String, named name: String) -> Range<String.Index>? {
        let range = match.range(withName: name)
        guard range.location != NSNotFound else { return nil }
        return Range(range, in: source)
    }

    /// A named capture group's text, or nil when the group didn't participate.
    static func text(_ match: NSTextCheckingResult, _ source: String, named name: String) -> String? {
        let range = match.range(withName: name)
        guard range.location != NSNotFound, let converted = Range(range, in: source) else { return nil }
        return String(source[converted])
    }
}
