import Foundation
import Testing

@testable import MurmurFormatting

/// Runs the shared behavioural contract in `shared/formatting-test-vectors.json`.
///
/// Same arrangement as `VectorTests` for the dictionary, and for the same reason: the
/// structure pass is the part of the app that can only be exercised by hand by talking into
/// a microphone, which is the part most in need of a specification something can check.
struct FormattingVectorTests {
    struct Vectors: Decodable {
        let version: Int
        let cases: [Case]
        let polishGuardCases: [GuardCase]
    }

    struct Case: Decodable {
        let name: String
        let phase: Phase
        var options: Options?
        let input: String
        let expected: String

        enum Phase: String, Decodable {
            case preClean
            case structure
        }
    }

    struct GuardCase: Decodable {
        let name: String
        let original: String
        let polished: String
        let accepted: Bool
    }

    /// Every key optional, so a case states only what it changes.
    struct Options: Decodable {
        var field: String?
        var listStyle: String?
        var retractionScope: String?
        var commandsEnabled: Bool?
        var listsEnabled: Bool?
        var retractionEnabled: Bool?
        var signOffEnabled: Bool?
        var autoSignOff: Bool?
        var userNames: [String]?
        var extraRetractionPhrases: [String]?
        var textBeforeCaret: String?
    }

    static func resolve(_ options: Options?) -> StructureOptions {
        StructureOptions(
            field: options?.field.flatMap(FieldKind.init(rawValue:)) ?? .unknown,
            listStyle: options?.listStyle.flatMap(ListMarkerStyle.init(rawValue:)) ?? .numbered,
            retractionScope: options?.retractionScope.flatMap(RetractionScope.init(rawValue:)) ?? .sentence,
            commandsEnabled: options?.commandsEnabled ?? true,
            listsEnabled: options?.listsEnabled ?? true,
            retractionEnabled: options?.retractionEnabled ?? true,
            signOffEnabled: options?.signOffEnabled ?? true,
            autoSignOff: options?.autoSignOff ?? true,
            userNames: options?.userNames ?? [],
            extraRetractionPhrases: options?.extraRetractionPhrases ?? [],
            textBeforeCaret: options?.textBeforeCaret ?? ""
        )
    }

    static func load() throws -> Vectors {
        let url = try #require(
            Bundle.module.url(forResource: "formatting-test-vectors", withExtension: "json")
        )
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }

    @Test("every shared vector produces the contracted output")
    func vectors() throws {
        let vectors = try Self.load()
        #expect(vectors.version == 1)

        for testCase in vectors.cases {
            let options = Self.resolve(testCase.options)
            let actual = switch testCase.phase {
            case .preClean: StructurePass.preClean(testCase.input, options: options).text
            case .structure: StructurePass.structure(testCase.input, options: options)
            }
            #expect(
                actual == testCase.expected,
                """
                \(testCase.name)
                  input:    \(testCase.input.debugDescription)
                  expected: \(testCase.expected.debugDescription)
                  actual:   \(actual.debugDescription)
                """
            )
        }
    }

    @Test("the polish guard accepts repair and rejects drift")
    func polishGuard() throws {
        for testCase in try Self.load().polishGuardCases {
            let verdict = PolishGuard.check(original: testCase.original, polished: testCase.polished)
            #expect(
                verdict.isAcceptable == testCase.accepted,
                """
                \(testCase.name)
                  expected accepted: \(testCase.accepted)
                  actual:            \(verdict.isAcceptable) — \(verdict.reason ?? "accepted")
                """
            )
        }
    }

    /// A retraction that fires on ordinary speech costs the speaker words they can't get
    /// back, so what it erased is kept rather than dropped.
    @Test("a retraction reports what it took away")
    func retractionReportsRemovals() {
        let result = StructurePass.preClean(
            "Let's go with the blue one. Scratch that. Let's go with the green one.",
            options: .none
        )
        #expect(result.didRetract)
        #expect(result.retracted.count == 1)
        #expect(result.retracted[0].contains("blue"))
    }
}
