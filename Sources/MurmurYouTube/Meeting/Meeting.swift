import Foundation
import Observation

/// One attributed stretch of speech in a meeting.
struct MeetingSegment: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    /// "You" for the microphone track; "Speaker 1", "Speaker 2"… for the diarized system
    /// track. Renameable, because a label is only useful once it's a person's name.
    var speaker: String
    /// Seconds from the start of the recording.
    var start: TimeInterval
    var end: TimeInterval
    var text: String
}

/// A recorded meeting and its transcript.
///
/// The audio is deliberately **not** kept. A meeting is minutes of everyone in the room,
/// and storing it means a dictation app quietly accumulating recordings of other people;
/// the transcript is what the feature is for.
struct Meeting: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var date: Date
    var title: String
    var duration: TimeInterval
    var segments: [MeetingSegment]

    /// Distinct speakers in the order they first spoke.
    var speakers: [String] {
        var seen = Set<String>()
        return segments.compactMap { seen.insert($0.speaker).inserted ? $0.speaker : nil }
    }

    var wordCount: Int {
        segments.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
    }

    /// Renames one speaker everywhere it appears.
    mutating func rename(_ speaker: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        for index in segments.indices where segments[index].speaker == speaker {
            segments[index].speaker = trimmed
        }
    }
}

/// Meetings on disk, one JSON file each.
///
/// A file per meeting rather than one combined log — unlike a dictation, a meeting is large
/// and is deleted as a unit, and rewriting a 200 KB file to delete one of forty is the kind
/// of thing that eventually loses someone's transcript.
@MainActor
@Observable
final class MeetingStore {
    static let shared = MeetingStore()

    private(set) var meetings: [Meeting] = []

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MurmurYouTube/Meetings", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private init() { load() }

    func load() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: Self.directory,
            includingPropertiesForKeys: nil
        )) ?? []

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        meetings = urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(Meeting.self, from: data)
            }
            .sorted { $0.date > $1.date }
    }

    func save(_ meeting: Meeting) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        guard let data = try? encoder.encode(meeting) else { return }
        try? data.write(to: url(for: meeting), options: .atomic)

        if let index = meetings.firstIndex(where: { $0.id == meeting.id }) {
            meetings[index] = meeting
        } else {
            meetings.insert(meeting, at: 0)
        }
    }

    func delete(_ meeting: Meeting) {
        try? FileManager.default.removeItem(at: url(for: meeting))
        meetings.removeAll { $0.id == meeting.id }
    }

    private func url(for meeting: Meeting) -> URL {
        Self.directory.appendingPathComponent("\(meeting.id.uuidString).json")
    }
}
