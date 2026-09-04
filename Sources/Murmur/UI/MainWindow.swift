import MurmurDictionary
import AppKit
import SwiftUI

/// The app's main window.
///
/// One column: a compact transport strip, a segmented switch, and the selected section in
/// a well below it. The strip is deliberately short — the app's real surface is the
/// transcript list, and a control panel taller than the content it controls is a shape
/// that only makes sense on hardware.
struct MainWindow: View {
    @Bindable var controller: DictationController

    @State private var section: Section = .transcriptions

    enum Section: String, CaseIterable, Identifiable {
        case transcriptions
        case meetings
        case dictionary

        var id: String { rawValue }

        var title: String {
            switch self {
            case .transcriptions: "Transcriptions"
            case .meetings: "Meetings"
            case .dictionary: "Dictionary"
            }
        }

        var icon: String {
            switch self {
            case .transcriptions: "waveform"
            case .meetings: "person.wave.2"
            case .dictionary: "character.book.closed"
            }
        }
    }

    var body: some View {
        ZStack {
            DS.Color.chassis.ignoresSafeArea()

            VStack(spacing: DS.Space.base) {
                if !controller.isHotkeyArmed { permissionBanner }

                TransportPanel(controller: controller)

                sectionSwitch

                Well {
                    Group {
                        switch section {
                        case .transcriptions: TranscriptionList()
                        case .meetings: MeetingsPanel()
                        case .dictionary: DictionaryPanel()
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .padding(DS.Space.roomy)
        }
        .frame(minWidth: 760, minHeight: 560)
    }

    /// Shown whenever the push-to-talk tap isn't installed.
    ///
    /// The app used to say nothing here. Without Accessibility the key is simply inert, and
    /// the only clue was a menu item you had to go looking for — so the app looked broken
    /// rather than ungranted. It says what is off, what still works, and what to do.
    ///
    /// It disappears on its own: `retryActivation` polls for the grant and arms the tap,
    /// which flips `isHotkeyArmed` and takes this with it. No restart, no button to press
    /// twice.
    private var permissionBanner: some View {
        HStack(spacing: DS.Space.base) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(DS.Color.meterAmber)

            VStack(alignment: .leading, spacing: DS.Space.hair) {
                Text("Push-to-talk is off")
                    .font(DS.Font.bodyEmphasis)
                    .foregroundStyle(DS.Color.ink)
                Text("Murmur needs Accessibility to see the key. The Record button below "
                    + "still works in the meantime.")
                    .font(DS.Font.label)
                    .foregroundStyle(DS.Color.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: DS.Space.snug)

            TransportKey(title: "Grant\u{2026}", isEngaged: true, engagedColor: DS.Color.ink) {
                Permissions.openAccessibilitySettings()
            }
        }
        .padding(DS.Space.roomy)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BrushedPanel())
    }

    /// A segmented switch: one track, the selection sliding between segments.
    ///
    /// The slide is a `matchedGeometryEffect` rather than three independently animating
    /// backgrounds, so the indicator reads as one object moving instead of one fading out
    /// while another fades in.
    private var sectionSwitch: some View {
        HStack(spacing: DS.Space.hair) {
            ForEach(Section.allCases) { candidate in
                let isSelected = section == candidate
                Button {
                    withAnimation(DS.Motion.panel) { section = candidate }
                } label: {
                    HStack(spacing: DS.Space.tight) {
                        Image(systemName: candidate.icon)
                            .font(.system(size: 10, weight: .semibold))
                        Text(candidate.title)
                            .font(DS.Font.body)
                    }
                    .foregroundStyle(isSelected ? DS.Color.ink : DS.Color.inkSecondary)
                    .padding(.horizontal, DS.Space.base)
                    .frame(height: DS.Material.keyHeight)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: DS.Radius.control - 2, style: .continuous)
                                .fill(DS.Color.panel)
                                .shadow(
                                    color: DS.Shadow.raised.color,
                                    radius: DS.Shadow.raised.radius,
                                    y: DS.Shadow.raised.y
                                )
                                .matchedGeometryEffect(id: "section", in: sectionNamespace)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(DS.Space.hair)
        .background(DS.Color.well, in: .rect(cornerRadius: DS.Radius.control))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                .strokeBorder(DS.Color.seam, lineWidth: DS.Border.hairline)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @Namespace private var sectionNamespace
}

// MARK: - Transport

/// Record / stop, the level meter, and the elapsed clock, on one line.
private struct TransportPanel: View {
    @Bindable var controller: DictationController

    @State private var elapsed: TimeInterval = 0
    @State private var startedAt: Date?

    private var isRecording: Bool { controller.state.isActive }

    var body: some View {
        HStack(spacing: DS.Space.base) {
            TransportKey(
                title: isRecording ? "Stop" : "Record",
                systemImage: isRecording ? "stop.fill" : "circle.fill",
                isEngaged: isRecording,
                engagedColor: DS.Color.record
            ) {
                if isRecording {
                    controller.stopButtonRecording()
                } else {
                    controller.startButtonRecording()
                }
            }

            // The lock only appears while a tap has latched the mic open. It sits next to
            // the transport because that is where you look to find out whether the app is
            // still listening.
            if controller.isLatched {
                HStack(spacing: DS.Space.tight) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9, weight: .semibold))
                    Silkscreen(text: "Locked", color: DS.Color.accent)
                }
                .foregroundStyle(DS.Color.accent)
                .transition(.opacity)
            }

            VUMeter(level: controller.level, isActive: isRecording)
                .frame(height: DS.Material.meterHeight)
                .frame(maxWidth: .infinity)

            Readout(text: counterText)
                .foregroundStyle(isRecording ? DS.Color.ink : DS.Color.inkSecondary)
                .monospacedDigit()
        }
        .padding(.horizontal, DS.Space.roomy)
        .padding(.vertical, DS.Space.base)
        .background(BrushedPanel())
        .animation(DS.Motion.panel, value: controller.isLatched)
        .onChange(of: controller.state.isActive) { _, active in
            startedAt = active ? Date() : nil
            if !active { elapsed = 0 }
        }
        .task(id: startedAt) {
            guard let startedAt else { return }
            while !Task.isCancelled {
                elapsed = Date().timeIntervalSince(startedAt)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// Minutes and seconds, zero-padded, the way a tape counter reads.
    private var counterText: String {
        let total = Int(elapsed)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

// MARK: - Transcriptions

/// Past transcriptions, searchable, each copyable.
private struct TranscriptionList: View {
    @State private var store = RunStore.shared
    @State private var query = ""
    @State private var isConfirmingClear = false

    private var runs: [DictationRun] {
        let all = store.runs.reversed().map { $0 }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return all }
        return all.filter { $0.text.localizedStandardContains(trimmed) }
    }

    var body: some View {
        VStack(spacing: 0) {
            SearchField(text: $query, placeholder: "Search transcriptions")

            if runs.isEmpty {
                EmptyPanel(
                    label: store.runs.isEmpty ? "No recordings" : "No matches",
                    detail: store.runs.isEmpty ? "Press Record to start." : "Try a different search."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: DS.Space.snug) {
                        ForEach(runs) { run in
                            TranscriptionRow(run: run) {
                                withAnimation(DS.Motion.panel) { RunLog.delete(run) }
                            }
                        }
                    }
                    .padding(DS.Space.base)
                }
                footer
            }
        }
    }

    private var footer: some View {
        HStack {
            Silkscreen(
                text: "\(store.runs.count) recording\(store.runs.count == 1 ? "" : "s")",
                color: DS.Color.inkOnDeck.opacity(0.5)
            )
            Spacer()
            Button { isConfirmingClear = true } label: {
                Silkscreen(text: "Delete all", color: DS.Color.inkOnDeck.opacity(0.5))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, DS.Space.base)
        .padding(.vertical, DS.Space.snug)
        .background(DS.Color.deck)
        .overlay(alignment: .top) {
            Rectangle().fill(DS.Color.seam).frame(height: DS.Border.seam)
        }
        // Confirmed, unlike a single row: one row is trivially re-recorded, the whole
        // history is not, and there's no undo.
        .confirmationDialog(
            "Delete all \(store.runs.count) recordings?",
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button("Delete All", role: .destructive) { RunLog.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone.")
        }
    }
}

private struct TranscriptionRow: View {
    let run: DictationRun
    let onDelete: () -> Void

    @State private var didCopy = false
    @State private var isHovering = false
    @State private var isTeaching = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.snug) {
            HStack(spacing: DS.Space.snug) {
                Silkscreen(text: run.engine, color: DS.Color.inkOnDeck.opacity(0.7))
                Readout(text: String(format: "%.2fs", run.processSeconds))
                    .foregroundStyle(DS.Color.inkOnDeck.opacity(0.6))
                Spacer()
                Text(run.date, style: .time)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.inkOnDeck.opacity(0.5))
                copyButton
                teachButton
                    .opacity(isHovering ? 1 : 0)
                deleteButton
                    .opacity(isHovering ? 1 : 0)
            }

            Text(run.text)
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.inkOnDeck)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let corrections = run.corrections, !corrections.isEmpty {
                CorrectionBadges(corrections: corrections)
            }
        }
        .padding(DS.Space.base)
        .background {
            DeckWindow { Color.clear }
                .opacity(isHovering ? 0.85 : 1)
        }
        .onHover { isHovering = $0 }
        .sheet(isPresented: $isTeaching) {
            TeachSheet(transcript: run.text)
        }
    }

    /// The whole of the learned-vocabulary feature: a wrong word in history is the one
    /// place where both halves of a rule — what was heard and what was meant — are known.
    private var teachButton: some View {
        Button { isTeaching = true } label: {
            Silkscreen(text: "Teach", color: DS.Color.inkOnDeck.opacity(0.6))
                .padding(.horizontal, DS.Space.snug)
                .padding(.vertical, DS.Space.tight)
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.chip)
                        .strokeBorder(DS.Color.inkOnDeck.opacity(0.3), lineWidth: DS.Border.hairline)
                )
        }
        .buttonStyle(.plain)
        .help("Add a dictionary entry from this transcript")
    }

    private var copyButton: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(run.text, forType: .string)
            didCopy = true
            Task {
                try? await Task.sleep(for: .seconds(1.4))
                didCopy = false
            }
        } label: {
            Silkscreen(
                text: didCopy ? "Copied" : "Copy",
                color: DS.Color.inkOnDeck.opacity(didCopy ? 1 : 0.6)
            )
            .padding(.horizontal, DS.Space.snug)
            .padding(.vertical, DS.Space.tight)
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.chip)
                    .strokeBorder(DS.Color.inkOnDeck.opacity(0.3), lineWidth: DS.Border.hairline)
            )
        }
        .buttonStyle(.plain)
    }

    /// Appears on hover only, and deletes without a confirmation — a single transcript is
    /// cheap to redo, and a dialog on every row would make tidying up tedious. The
    /// irreversible one is "Delete all", which does confirm.
    private var deleteButton: some View {
        Button(action: onDelete) {
            Image(systemName: "trash")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(DS.Color.inkOnDeck.opacity(0.55))
                .padding(.horizontal, DS.Space.snug)
                .padding(.vertical, DS.Space.tight)
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.chip)
                        .strokeBorder(DS.Color.inkOnDeck.opacity(0.3), lineWidth: DS.Border.hairline)
                )
        }
        .buttonStyle(.plain)
        .help("Delete this transcription")
    }
}

/// Shows that the dictionary fired, and on what. Without this the dictionary is invisible
/// and you can't tell a rule that works from one that never matches.
private struct CorrectionBadges: View {
    let corrections: [AppliedCorrection]

    /// Named after where the change came from, because "why did that word change?" is the
    /// only question this row exists to answer.
    private var label: String {
        let kinds = Set(corrections.map(\.kind))
        if kinds == [.screen] { return "From screen" }
        if kinds == [.snippet] { return "Applied" }
        return "Corrected"
    }

    var body: some View {
        HStack(spacing: DS.Space.snug) {
            Silkscreen(text: label, color: DS.Color.meterAmber)
            ForEach(corrections, id: \.self) { correction in
                HStack(spacing: DS.Space.tight) {
                    Text(correction.from)
                        .strikethrough()
                        .foregroundStyle(DS.Color.inkOnDeck.opacity(0.5))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(DS.Color.inkOnDeck.opacity(0.4))
                    Text(correction.to)
                        .foregroundStyle(DS.Color.inkOnDeck)
                    if correction.count > 1 {
                        Text("×\(correction.count)")
                            .foregroundStyle(DS.Color.inkOnDeck.opacity(0.5))
                    }
                }
                .font(DS.Font.caption)
                .padding(.horizontal, DS.Space.snug)
                .padding(.vertical, DS.Space.hair)
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.chip)
                        .strokeBorder(
                            (correction.kind == .screen ? DS.Color.accent : DS.Color.meterAmber)
                                .opacity(0.35),
                            lineWidth: DS.Border.hairline
                        )
                )
            }
            Spacer()
        }
    }
}

// MARK: - Shared

struct SearchField: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        HStack(spacing: DS.Space.snug) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(DS.Color.inkOnDeck.opacity(0.5))
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.inkOnDeck)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(DS.Color.inkOnDeck.opacity(0.4))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, DS.Space.base)
        .padding(.vertical, DS.Space.snug)
        .background(DS.Color.panelShade)
        .overlay(alignment: .bottom) {
            Rectangle().fill(DS.Color.seam).frame(height: DS.Border.seam)
        }
    }
}

struct EmptyPanel: View {
    let label: String
    let detail: String

    var body: some View {
        VStack(spacing: DS.Space.snug) {
            Silkscreen(text: label, large: true, color: DS.Color.inkOnDeck.opacity(0.55))
            Text(detail)
                .font(DS.Font.label)
                .foregroundStyle(DS.Color.inkOnDeck.opacity(0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
