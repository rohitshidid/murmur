import Foundation

/// The small classes of word a spoken repair swaps one member of for another.
///
/// "Send it Tuesday, no wait Wednesday" carries no shared word for `Retraction` to align on
/// — the only thing linking Wednesday to Tuesday is that both are weekdays. This is that
/// link, kept deliberately narrow: a class is only listed when swapping one member for
/// another is what a speaker correcting themselves actually does.
enum Lexicon {
    enum Kind: Sendable {
        case number
        case weekday
        case month
    }

    static func kind(of word: String) -> Kind? {
        let word = word.lowercased()
        if word.allSatisfy(\.isNumber) || numbers.contains(word) { return .number }
        if weekdays.contains(word) { return .weekday }
        if months.contains(word) { return .month }
        return nil
    }

    /// Spelled numbers a speaker says out loud. Deliberately stops at the point where people
    /// start saying digits instead.
    private static let numbers: Set<String> = [
        "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
        "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen",
        "eighteen", "nineteen", "twenty", "thirty", "forty", "fifty", "sixty", "seventy",
        "eighty", "ninety", "hundred", "thousand", "million",
        "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth",
        "ninth", "tenth",
    ]

    private static let weekdays: Set<String> = [
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "mon", "tue", "tues", "wed", "thu", "thur", "thurs", "fri", "sat", "sun",
        "today", "tomorrow", "yesterday", "tonight",
    ]

    private static let months: Set<String> = [
        "january", "february", "march", "april", "may", "june", "july", "august",
        "september", "october", "november", "december",
        "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec",
    ]
}
