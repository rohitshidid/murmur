import AppKit
import SwiftUI

/// Per-app tone rules: what the cleanup pass is told about where the text is going.
///
/// A sheet rather than another panel in Settings because the list grows with the number of
/// apps you use, and Settings is a fixed-height window of short controls.
struct ProfilesPanel: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store = ProfileStore.shared
    @State private var selection: String = ""

    private var profiles: [AppProfile] { store.all }

    private var selected: AppProfile {
        profiles.first { $0.bundleID == selection } ?? profiles[0]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.roomy) {
            VStack(alignment: .leading, spacing: DS.Space.tight) {
                Silkscreen(text: "Tone by app", large: true)
                Text("Cleanup is told where the text is going, so the same sentence can be a "
                    + "paragraph in Mail and one line in Slack.")
                    .font(DS.Font.label)
                    .foregroundStyle(DS.Color.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .top, spacing: DS.Space.base) {
                list
                editor
            }

            HStack(spacing: DS.Space.snug) {
                TransportKey(title: "Add app…") { addApp() }
                Spacer()
                TransportKey(title: "Done", isEngaged: true, engagedColor: DS.Color.ink) {
                    dismiss()
                }
            }
        }
        .padding(DS.Space.panel)
        .frame(width: 620, height: 460)
        .background(BrushedPanel(radius: DS.Radius.window))
        .onAppear { if selection.isEmpty { selection = profiles[0].bundleID } }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DS.Space.hair) {
                ForEach(profiles) { profile in
                    Button {
                        selection = profile.bundleID
                    } label: {
                        HStack(spacing: DS.Space.snug) {
                            Lamp(
                                color: DS.Color.meterGreen,
                                isLit: store.isOverridden(profile.bundleID),
                                size: 5
                            )
                            Text(profile.name)
                                .font(DS.Font.body)
                                .foregroundStyle(DS.Color.inkOnDeck)
                                .lineLimit(1)
                            Spacer()
                        }
                        .padding(.horizontal, DS.Space.snug)
                        .padding(.vertical, DS.Space.tight)
                        .background(
                            profile.bundleID == selection ? DS.Color.selection : .clear,
                            in: .rect(cornerRadius: DS.Radius.chip)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(DS.Space.snug)
        }
        .frame(width: 200)
        .background(DS.Color.well, in: .rect(cornerRadius: DS.Radius.panel))
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: DS.Space.snug) {
            Silkscreen(text: selected.isGlobal ? "Default instruction" : selected.bundleID)

            TextEditor(text: Binding(
                get: { selected.instruction },
                set: { store.save(AppProfile(
                    bundleID: selected.bundleID,
                    name: selected.name,
                    instruction: $0
                )) }
            ))
            .textEditorStyle(.plain)
            .font(DS.Font.body)
            .foregroundStyle(DS.Color.inkOnDeck)
            .scrollContentBackground(.hidden)
            .padding(DS.Space.snug)
            .background(DS.Color.deck, in: .rect(cornerRadius: DS.Radius.chip))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.chip)
                    .strokeBorder(DS.Color.seam, lineWidth: DS.Border.hairline)
            )

            // The one rule a user writing their own instruction has to know, because
            // breaking it fails silently: the cleanup guard rejects any output containing
            // words that weren't spoken, and a rejected response falls back to the plain
            // rule-based pass with nothing to show for it.
            Text("Say how to shape what was said — length, punctuation, paragraphs. Asking "
                + "for text that wasn't spoken (a greeting, a sign-off) is rejected and "
                + "quietly falls back to plain cleanup.")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if store.isOverridden(selected.bundleID) {
                Button { store.reset(selected.bundleID) } label: {
                    Silkscreen(text: "Reset to built-in", color: DS.Color.inkSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Picks an app by file rather than asking for a bundle identifier, which nobody knows
    /// off the top of their head.
    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"

        guard panel.runModal() == .OK,
              let url = panel.url,
              let bundle = Bundle(url: url),
              let id = bundle.bundleIdentifier
        else { return }

        let name = FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")

        // Seeded from whatever already applies to this app, so an added profile starts as
        // its current behaviour rather than as an empty box.
        store.save(AppProfile(bundleID: id, name: name, instruction: store.instruction(for: id)))
        selection = id
    }
}
