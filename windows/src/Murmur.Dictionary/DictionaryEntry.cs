using System.Text;

namespace Murmur.Dictionary;

/// <summary>
/// One thing the dictionary knows.
/// </summary>
/// <remarks>
/// Mirrors <c>DictionaryEntry.swift</c> in the macOS app. The two implementations are
/// independent; <c>shared/dictionary-test-vectors.json</c> is what keeps them honest.
/// </remarks>
public enum EntryKind
{
    /// <summary>A word or phrase the engine should know exists. Biasing only.</summary>
    Term,

    /// <summary>A mapping: when you hear X, write Y. Biasing *and* the correction pass.</summary>
    Correction,

    /// <summary>
    /// An expansion: say X, get a whole block of Y. Deliberately invoked, where a correction
    /// repairs something the user did not ask for.
    /// </summary>
    /// <remarks>
    /// Never fed to engine biasing. A snippet's output is a body of prose the user already
    /// knows how to say, and putting it in a 40-phrase context list would make the model
    /// hallucinate from its priming on quiet audio.
    /// </remarks>
    Snippet,
}

/// <inheritdoc cref="EntryKind"/>
public sealed record DictionaryEntry
{
    /// <summary>Stable identity, so an entry can be edited or deleted unambiguously.</summary>
    public Guid Id { get; init; } = Guid.NewGuid();

    /// <summary>Which of the three kinds this entry is.</summary>
    public EntryKind Kind { get; init; }

    /// <summary>
    /// The text that gets written. For <see cref="EntryKind.Term"/> this is the word itself;
    /// for <see cref="EntryKind.Correction"/> and <see cref="EntryKind.Snippet"/> it is the Y
    /// in "when you hear X, write Y". Biased into the engine for the first two kinds only.
    /// </summary>
    public string Write { get; init; } = string.Empty;

    /// <summary>
    /// For <see cref="EntryKind.Correction"/> and <see cref="EntryKind.Snippet"/>: the X in
    /// "when you hear X".
    /// </summary>
    public string Hear { get; init; } = string.Empty;

    /// <summary>
    /// Disabled entries stay in the file but stop affecting anything, so a rule can be
    /// tested without being deleted.
    /// </summary>
    public bool IsEnabled { get; init; } = true;

    /// <summary>A word or phrase the engine should know exists.</summary>
    /// <param name="word">The correct spelling.</param>
    public static DictionaryEntry Term(string word) =>
        new() { Kind = EntryKind.Term, Write = word };

    /// <summary>A mapping from a mishearing to the correct text.</summary>
    /// <param name="hear">What the engine produces — the X in "when you hear X".</param>
    /// <param name="write">What should be written instead.</param>
    public static DictionaryEntry Correction(string hear, string write) =>
        new() { Kind = EntryKind.Correction, Hear = hear, Write = write };

    /// <summary>An expansion fired by a spoken trigger.</summary>
    /// <param name="hear">The spoken trigger — the X in "when you hear X".</param>
    /// <param name="write">The block of text it expands to. May contain newlines.</param>
    public static DictionaryEntry Snippet(string hear, string write) =>
        new() { Kind = EntryKind.Snippet, Hear = hear, Write = write };

    /// <summary>How this entry reads in the plain-text file.</summary>
    /// <remarks>
    /// <c>-&gt;</c> is a correction and <c>=&gt;</c> a snippet. Two arrows rather than a
    /// keyword because the file is meant to be edited by hand, and <c>my address =&gt; …</c>
    /// reads as what it does.
    /// </remarks>
    public string ToFileLine()
    {
        var body = Kind switch
        {
            EntryKind.Correction => $"{Hear} -> {Write}",
            EntryKind.Snippet => $"{Hear} => {Escape(Write)}",
            _ => Write,
        };
        return IsEnabled ? body : $"# off: {body}";
    }

    /// <summary>Encodes newlines and tabs so a multi-line snippet survives one line.</summary>
    /// <param name="text">The raw body.</param>
    /// <returns>The body with backslashes, newlines and tabs escaped.</returns>
    /// <remarks>
    /// Backslashes are escaped first, or a body ending in one would swallow the escape of
    /// whatever followed it.
    /// </remarks>
    public static string Escape(string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        return text
            .Replace("\\", "\\\\", StringComparison.Ordinal)
            .Replace("\n", "\\n", StringComparison.Ordinal)
            .Replace("\t", "\\t", StringComparison.Ordinal);
    }

    /// <summary>The inverse of <see cref="Escape"/>.</summary>
    /// <param name="text">An escaped body as read from the file.</param>
    /// <returns>The body with its newlines and tabs restored.</returns>
    /// <remarks>
    /// Scanned character by character rather than by three sequential replacements:
    /// unescaping in passes would turn a literal backslash-then-n into a newline, which is
    /// exactly the round trip this has to protect.
    /// </remarks>
    public static string Unescape(string text)
    {
        ArgumentNullException.ThrowIfNull(text);

        var result = new StringBuilder(text.Length);
        var isEscaped = false;

        foreach (var character in text)
        {
            if (isEscaped)
            {
                _ = character switch
                {
                    'n' => result.Append('\n'),
                    't' => result.Append('\t'),
                    '\\' => result.Append('\\'),
                    // Not an escape we know — keep both characters as written.
                    _ => result.Append('\\').Append(character),
                };
                isEscaped = false;
            }
            else if (character == '\\')
            {
                isEscaped = true;
            }
            else
            {
                _ = result.Append(character);
            }
        }

        if (isEscaped) _ = result.Append('\\');
        return result.ToString();
    }
}

/// <summary>
/// A reason an entry looks likely to fire on text it wasn't meant to.
/// </summary>
/// <remarks>
/// Never blocks. It is the user's dictionary, and rewriting a common word is occasionally
/// exactly what they want.
/// </remarks>
public sealed record DictionaryWarning(string Message)
{
    /// <summary>
    /// Ordinary English words that would fire constantly if used as a whole trigger.
    /// Deliberately short — this catches the obvious foot-guns, not every possible one.
    /// Kept byte-identical to the Swift list so both platforms warn about the same things.
    /// </summary>
    private static readonly HashSet<string> Common = new(StringComparer.OrdinalIgnoreCase)
    {
        "a", "about", "all", "also", "and", "any", "are", "as", "at", "back", "be", "because",
        "but", "by", "call", "can", "case", "check", "class", "close", "cloud", "code", "come",
        "could", "data", "day", "did", "do", "does", "down", "each", "even", "file", "find",
        "first", "for", "from", "get", "give", "go", "good", "great", "group", "had", "has",
        "have", "he", "her", "here", "him", "his", "how", "if", "in", "into", "is", "it",
        "its", "just", "key", "know", "like", "line", "list", "look", "make", "man", "many",
        "may", "me", "more", "most", "my", "need", "new", "no", "not", "now", "number", "of",
        "off", "on", "one", "only", "open", "or", "other", "our", "out", "over", "page",
        "part", "people", "point", "put", "read", "right", "run", "said", "same", "say",
        "see", "set", "she", "should", "show", "side", "so", "some", "state", "still", "such",
        "take", "team", "test", "than", "that", "the", "their", "them", "then", "there",
        "these", "they", "thing", "think", "this", "time", "to", "two", "type", "up", "us",
        "use", "user", "very", "want", "was", "way", "we", "well", "were", "what", "when",
        "where", "which", "who", "will", "with", "word", "work", "would", "year", "you",
        "your",
    };

    private static readonly char[] PhraseSeparators = [' ', '-', '\t'];

    /// <summary>Checks an entry for patterns likely to fire on unintended text.</summary>
    /// <param name="entry">The entry to inspect.</param>
    /// <returns>Warnings to show the user, or empty if the entry looks safe.</returns>
    public static IReadOnlyList<DictionaryWarning> Check(DictionaryEntry entry)
    {
        // Only the trigger side can misfire. A Term is never matched against text.
        if (entry.Kind == EntryKind.Term) return [];

        var trigger = entry.Hear.Trim();
        if (trigger.Length == 0) return [];

        var warnings = new List<DictionaryWarning>();
        var words = trigger.Split(PhraseSeparators, StringSplitOptions.RemoveEmptyEntries);

        if (words.Length == 1)
        {
            var only = words[0];
            if (Common.Contains(only))
            {
                warnings.Add(new DictionaryWarning(
                    $"“{trigger}” is an ordinary word. This will rewrite every use of it, "
                    + "not just the ones you mean. Consider a longer phrase."));
            }
            else if (only.Length <= 3)
            {
                warnings.Add(new DictionaryWarning(
                    $"“{trigger}” is very short and will match often. Consider a longer phrase."));
            }
        }

        if (string.Equals(entry.Write.Trim(), trigger, StringComparison.OrdinalIgnoreCase))
        {
            warnings.Add(new DictionaryWarning(
                $"This rewrites “{trigger}” to itself, so it will never change anything."));
        }

        return warnings;
    }
}
