import Foundation
import Testing

@testable import MurmurDictionary

/// Runs the shared behavioural contract in `shared/dictionary-test-vectors.json`.
///
/// The Windows app reimplements this logic in C# and runs the identical file. That's the
/// only thing keeping two independent implementations honest — there's no shared binary, and
/// no Windows machine to check against by hand.
struct VectorTests {
    struct Vectors: Decodable {
        let version: Int
        let cases: [Case]
    }

    struct Case: Decodable {
        let name: String
        let entries: [Entry]
        let input: String
        let expected: String
        let expectedCorrections: [ExpectedCorrection]
    }

    struct Entry: Decodable {
        let kind: String
        var hear: String?
        let write: String
        var isEnabled: Bool?

        var asEntry: DictionaryEntry {
            DictionaryEntry(
                kind: DictionaryEntry.Kind(rawValue: kind) ?? .term,
                write: write,
                hear: hear ?? "",
                isEnabled: isEnabled ?? true
            )
        }
    }

    struct ExpectedCorrection: Decodable {
        let to: String
        let count: Int
        /// Absent means `.correction` — the vectors predating snippets don't carry it.
        var kind: String?

        var expectedKind: AppliedCorrection.Kind {
            AppliedCorrection.Kind(rawValue: kind ?? "correction") ?? .correction
        }
    }

    static func load() throws -> Vectors {
        let url = try #require(
            Bundle.module.url(forResource: "dictionary-test-vectors", withExtension: "json")
        )
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }

    @Test("every shared vector produces the contracted output")
    func vectors() throws {
        let vectors = try Self.load()
        #expect(vectors.cases.isEmpty == false)

        for testCase in vectors.cases {
            let corrector = DictionaryCorrector(entries: testCase.entries.map(\.asEntry))
            let (text, applied) = corrector.apply(to: testCase.input)

            #expect(text == testCase.expected, "\(testCase.name): text")
            #expect(
                applied.count == testCase.expectedCorrections.count,
                "\(testCase.name): correction count — got \(applied.map(\.to))"
            )

            // Order-insensitive: which rule fires first is an implementation detail of the
            // longest-first sort, but *what* fired and how often is contractual.
            for expected in testCase.expectedCorrections {
                let match = applied.first { $0.to == expected.to }
                #expect(match != nil, "\(testCase.name): expected a correction to “\(expected.to)”")
                #expect(match?.count == expected.count, "\(testCase.name): count for “\(expected.to)”")
                #expect(match?.kind == expected.expectedKind, "\(testCase.name): kind for “\(expected.to)”")
            }
        }
    }

    @Test("bias list is capped and de-duplicated")
    func biasList() {
        let entries = (0..<100).map { DictionaryEntry.term("Word\($0)") }
            + [DictionaryEntry.term("Word0")]
        let phrases = DictionaryCorrector.biasPhrases(from: entries)

        #expect(phrases.count == DictionaryCorrector.biasLimit)
        #expect(Set(phrases).count == phrases.count)
    }

    @Test("disabled entries are excluded from biasing")
    func biasSkipsDisabled() {
        let entries = [
            DictionaryEntry(kind: .term, write: "Kept"),
            DictionaryEntry(kind: .term, write: "Skipped", isEnabled: false),
        ]
        #expect(DictionaryCorrector.biasPhrases(from: entries) == ["Kept"])
    }

    @Test("an ordinary word used as a trigger is flagged")
    func warnsOnCommonWord() {
        let entry = DictionaryEntry.correction(hear: "cloud", write: "Claude")
        #expect(DictionaryWarning.check(entry).isEmpty == false)
    }

    @Test("a distinctive phrase is not flagged")
    func doesNotWarnOnDistinctivePhrase() {
        let entry = DictionaryEntry.correction(hear: "clawed code", write: "Claude Code")
        #expect(DictionaryWarning.check(entry).isEmpty)
    }

    @Test("a snippet's own trigger is checked for misfires too")
    func warnsOnCommonSnippetTrigger() {
        let entry = DictionaryEntry.snippet(hear: "my", write: "12 Main Street")
        #expect(DictionaryWarning.check(entry).isEmpty == false)
    }

    @Test("a snippet body survives a round trip through the file format")
    func snippetFileLineRoundTrips() {
        let body = "Thanks,\nRohit\tX\\Y"
        let escaped = DictionaryEntry.escape(body)
        #expect(escaped.contains("\n") == false)
        #expect(DictionaryEntry.unescape(escaped) == body)
    }

    @Test("snippet bodies are kept out of the engine bias list")
    func biasSkipsSnippetBodies() {
        let entries = [
            DictionaryEntry.term("Anthropic"),
            DictionaryEntry.snippet(hear: "my address", write: "12 Main Street, Pune"),
        ]
        #expect(DictionaryCorrector.biasPhrases(from: entries) == ["Anthropic"])
    }
}
