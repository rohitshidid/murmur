import Foundation
import UniformTypeIdentifiers

/// Turns a meeting into a file someone else can read.
///
/// A transcript nobody can get out of the app is a transcript that only exists for you,
/// which is the opposite of what meeting notes are for.
enum MeetingExport {
    enum Format: String, CaseIterable, Identifiable, Sendable {
        case markdown
        case text
        case srt
        case vtt

        var id: String { rawValue }

        var title: String {
            switch self {
            case .markdown: "Markdown"
            case .text: "Plain text"
            case .srt: "SubRip (.srt)"
            case .vtt: "WebVTT (.vtt)"
            }
        }

        var fileExtension: String {
            switch self {
            case .markdown: "md"
            case .text: "txt"
            case .srt: "srt"
            case .vtt: "vtt"
            }
        }

        var contentType: UTType {
            switch self {
            case .markdown: .init(filenameExtension: "md") ?? .plainText
            case .text: .plainText
            case .srt: .init(filenameExtension: "srt") ?? .plainText
            case .vtt: .init(filenameExtension: "vtt") ?? .plainText
            }
        }
    }

    static func render(_ meeting: Meeting, as format: Format) -> String {
        switch format {
        case .markdown: markdown(meeting)
        case .text: plainText(meeting)
        case .srt: subRip(meeting)
        case .vtt: webVTT(meeting)
        }
    }

    // MARK: - Formats

    private static func markdown(_ meeting: Meeting) -> String {
        var lines = [
            "# \(meeting.title)",
            "",
            "\(meeting.date.formatted(date: .long, time: .shortened)) · \(clock(meeting.duration)) · "
                + "\(meeting.speakers.count) speaker\(meeting.speakers.count == 1 ? "" : "s")",
            "",
        ]

        // Consecutive turns by one speaker are merged under a single heading — a new
        // heading every time someone pauses makes the document unreadable.
        var lastSpeaker: String?
        for segment in meeting.segments {
            if segment.speaker != lastSpeaker {
                lines.append("")
                lines.append("**\(segment.speaker)** · `\(clock(segment.start))`")
                lines.append("")
                lastSpeaker = segment.speaker
            }
            lines.append(segment.text)
        }

        return lines.joined(separator: "\n").appending("\n")
    }

    private static func plainText(_ meeting: Meeting) -> String {
        meeting.segments
            .map { "[\(clock($0.start))] \($0.speaker): \($0.text)" }
            .joined(separator: "\n")
            .appending("\n")
    }

    private static func subRip(_ meeting: Meeting) -> String {
        meeting.segments.enumerated().map { index, segment in
            """
            \(index + 1)
            \(timecode(segment.start, separator: ",")) --> \(timecode(segment.end, separator: ","))
            \(segment.speaker): \(segment.text)
            """
        }
        .joined(separator: "\n\n")
        .appending("\n")
    }

    private static func webVTT(_ meeting: Meeting) -> String {
        let cues = meeting.segments.map { segment in
            """
            \(timecode(segment.start, separator: ".")) --> \(timecode(segment.end, separator: "."))
            <v \(segment.speaker)>\(segment.text)
            """
        }
        return (["WEBVTT", ""] + cues).joined(separator: "\n\n").appending("\n")
    }

    // MARK: - Time

    /// `mm:ss`, or `h:mm:ss` once a meeting runs past the hour.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let (hours, minutes, secs) = (total / 3600, (total % 3600) / 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }

    /// `HH:MM:SS,mmm` for SubRip and `HH:MM:SS.mmm` for WebVTT — the only difference
    /// between the two timecodes is that separator.
    private static func timecode(_ seconds: TimeInterval, separator: String) -> String {
        let clamped = max(0, seconds)
        let total = Int(clamped)
        let milliseconds = Int((clamped - Double(total)) * 1000)
        return String(
            format: "%02d:%02d:%02d\(separator)%03d",
            total / 3600,
            (total % 3600) / 60,
            total % 60,
            milliseconds
        )
    }
}
