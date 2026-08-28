import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Meetings: record the room, read the transcript, export it.
///
/// A different interaction from push-to-talk, and the layout says so — this section has its
/// own recorder at the top and produces documents rather than injecting text anywhere.
struct MeetingsPanel: View {
    @State private var store = MeetingStore.shared
    @State private var recorder = MeetingRecorder()
    @State private var selected: Meeting?
    @State private var query = ""

    private var meetings: [Meeting] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return store.meetings }
        return store.meetings.filter { meeting in
            meeting.title.localizedStandardContains(trimmed)
                || meeting.segments.contains { $0.text.localizedStandardContains(trimmed) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            recorderBar

            if let selected {
                MeetingDetail(meeting: selected) { self.selected = nil }
            } else if meetings.isEmpty {
                EmptyPanel(
                    label: store.meetings.isEmpty ? "No meetings" : "No matches",
                    detail: store.meetings.isEmpty
                        ? "Record one to capture both sides of the conversation."
                        : "Try a different search."
                )
            } else {
                SearchField(text: $query, placeholder: "Search meetings")
                list
            }
        }
    }

    // MARK: - Recorder

    private var recorderBar: some View {
        HStack(spacing: DS.Space.base) {
            TransportKey(
                title: recorder.state.isRecording ? "Stop" : "Record meeting",
                systemImage: recorder.state.isRecording ? "stop.fill" : "record.circle",
                isEngaged: recorder.state.isRecording,
                engagedColor: DS.Color.record,
                isEnabled: !isTranscribing
            ) {
                if recorder.state.isRecording {
                    recorder.stop()
                } else {
                    recorder.start()
                }
            }

            switch recorder.state {
            case .recording:
                Lamp(color: DS.Color.record, isLit: true)
                VUMeter(level: recorder.level, isActive: true)
                    .frame(height: DS.Material.meterHeight)
                    .frame(maxWidth: .infinity)
                Readout(text: MeetingExport.clock(recorder.elapsed))

            case .transcribing(let progress):
                Text("Transcribing…")
                    .font(DS.Font.label)
                    .foregroundStyle(DS.Color.inkSecondary)
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(DS.Color.accent)
                    .frame(maxWidth: .infinity)

            case .error(let message):
                Text(message)
                    .font(DS.Font.label)
                    .foregroundStyle(DS.Color.meterRed)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

            case .idle:
                Text("Captures your mic and the meeting audio as separate tracks.")
                    .font(DS.Font.label)
                    .foregroundStyle(DS.Color.inkSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, DS.Space.base)
        .padding(.vertical, DS.Space.snug)
        .background(DS.Color.panelShade)
        .overlay(alignment: .bottom) {
            Rectangle().fill(DS.Color.seam).frame(height: DS.Border.seam)
        }
        .animation(DS.Motion.panel, value: recorder.state)
    }

    private var isTranscribing: Bool {
        if case .transcribing = recorder.state { return true }
        return false
    }

    // MARK: - List

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: DS.Space.snug) {
                ForEach(meetings) { meeting in
                    Button {
                        withAnimation(DS.Motion.panel) { selected = meeting }
                    } label: {
                        MeetingRow(meeting: meeting)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Delete", role: .destructive) { store.delete(meeting) }
                    }
                }
            }
            .padding(DS.Space.base)
        }
    }
}

// MARK: - Row

private struct MeetingRow: View {
    let meeting: Meeting

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: DS.Space.base) {
            VStack(alignment: .leading, spacing: DS.Space.tight) {
                Text(meeting.title)
                    .font(DS.Font.bodyEmphasis)
                    .foregroundStyle(DS.Color.inkOnDeck)

                HStack(spacing: DS.Space.snug) {
                    Text(meeting.date, style: .date)
                    Text(MeetingExport.clock(meeting.duration))
                    Text("\(meeting.speakers.count) speaker\(meeting.speakers.count == 1 ? "" : "s")")
                    Text("\(meeting.wordCount) words")
                }
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.inkSecondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(DS.Color.inkSecondary.opacity(isHovering ? 1 : 0.4))
        }
        .padding(DS.Space.base)
        .background(isHovering ? DS.Color.panelHighlight : DS.Color.deck)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
                .strokeBorder(DS.Color.seam, lineWidth: DS.Border.hairline)
        )
        .onHover { isHovering = $0 }
    }
}

// MARK: - Detail

/// One meeting: the transcript, speaker labels you can rename, and export.
private struct MeetingDetail: View {
    let meeting: Meeting
    let onBack: () -> Void

    @State private var store = MeetingStore.shared
    @State private var renaming: String?
    @State private var newName = ""

    /// The store is the source of truth — a rename has to be read back from it or the view
    /// keeps showing the copy it was handed.
    private var current: Meeting {
        store.meetings.first { $0.id == meeting.id } ?? meeting
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.Space.base) {
                    ForEach(current.segments) { segment in
                        segmentRow(segment)
                    }
                }
                .padding(DS.Space.base)
            }
        }
        .sheet(item: Binding(
            get: { renaming.map(Speaker.init) },
            set: { renaming = $0?.name }
        )) { speaker in
            renameSheet(speaker.name)
        }
    }

    /// `sheet(item:)` needs an `Identifiable`, and a bare `String` isn't one.
    private struct Speaker: Identifiable {
        let name: String
        var id: String { name }
    }

    private var header: some View {
        HStack(spacing: DS.Space.snug) {
            Button(action: onBack) {
                HStack(spacing: DS.Space.tight) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Meetings").font(DS.Font.body)
                }
                .foregroundStyle(DS.Color.inkSecondary)
            }
            .buttonStyle(.plain)

            Text(current.title)
                .font(DS.Font.bodyEmphasis)
                .foregroundStyle(DS.Color.ink)
                .lineLimit(1)

            Spacer()

            Menu {
                ForEach(MeetingExport.Format.allCases) { format in
                    Button(format.title) { export(as: format) }
                }
            } label: {
                Text("Export").font(DS.Font.body)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, DS.Space.base)
        .padding(.vertical, DS.Space.snug)
        .background(DS.Color.panelShade)
        .overlay(alignment: .bottom) {
            Rectangle().fill(DS.Color.seam).frame(height: DS.Border.seam)
        }
    }

    private func segmentRow(_ segment: MeetingSegment) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.tight) {
            HStack(spacing: DS.Space.snug) {
                Button {
                    newName = segment.speaker
                    renaming = segment.speaker
                } label: {
                    Silkscreen(text: segment.speaker, color: color(for: segment.speaker))
                }
                .buttonStyle(.plain)
                .help("Rename this speaker")

                Readout(text: MeetingExport.clock(segment.start))
                    .foregroundStyle(DS.Color.inkSecondary)
            }

            Text(segment.text)
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.inkOnDeck)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(DS.Space.base)
        .background(DS.Color.deck)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
                .strokeBorder(DS.Color.seam, lineWidth: DS.Border.hairline)
        )
    }

    /// You are always the accent; everyone else is neutral. Two colours, not one per
    /// speaker — a transcript with six tinted labels is a transcript nobody can read.
    private func color(for speaker: String) -> Color {
        speaker == "You" ? DS.Color.accent : DS.Color.silkscreen
    }

    private func renameSheet(_ speaker: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.roomy) {
            Silkscreen(text: "Rename \(speaker)", large: true)

            TextField("Name", text: $newName)
                .textFieldStyle(.plain)
                .font(DS.Font.body)
                .padding(DS.Space.snug)
                .background(DS.Color.cap, in: .rect(cornerRadius: DS.Radius.chip))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.chip)
                        .strokeBorder(DS.Color.seam, lineWidth: DS.Border.hairline)
                )

            HStack {
                Spacer()
                TransportKey(title: "Cancel") { renaming = nil }
                TransportKey(title: "Rename", isEngaged: true) {
                    var updated = current
                    updated.rename(speaker, to: newName)
                    store.save(updated)
                    renaming = nil
                }
            }
        }
        .padding(DS.Space.panel)
        .frame(width: 360)
        .background(BrushedPanel(radius: DS.Radius.window))
    }

    private func export(as format: MeetingExport.Format) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = "\(current.title).\(format.fileExtension)"
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let rendered = MeetingExport.render(current, as: format)
        try? rendered.write(to: url, atomically: true, encoding: .utf8)
    }
}
