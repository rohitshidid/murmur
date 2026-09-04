import SwiftUI

/// Settings — hotkey and model, per the brief. Opens on ⌘, via the standard `Settings` scene,
/// so the system wires up the menu item and the shortcut.
struct SettingsWindow: View {
    @Bindable var controller: DictationController
    @State private var settings = Settings.shared
    @State private var isEditingProfiles = false
    @State private var isEditingStructure = false

    var body: some View {
        ZStack {
            DS.Color.chassis.ignoresSafeArea()

            // Scrollable, with the window height fixed below rather than grown to fit it.
            // Settings has outgrown any height that also fits a laptop display, and a fixed
            // frame taller than its content clips silently — no scrollbar, and no way to
            // reach what is underneath.
            ScrollView {
                panels.padding(DS.Space.panel)
            }
        }
        .frame(width: 520, height: 700)
        .sheet(isPresented: $isEditingProfiles) { ProfilesPanel() }
        .sheet(isPresented: $isEditingStructure) { StructurePanel() }
    }

    private var panels: some View {
        VStack(alignment: .leading, spacing: DS.Space.wide) {
            panel(label: "Push to talk") {
                HStack(spacing: DS.Space.snug) {
                    ForEach(PushToTalkKey.allCases, id: \.self) { key in
                        TransportKey(
                            title: key.displayName,
                            isEngaged: settings.pushToTalkKey == key,
                            engagedColor: DS.Color.ink
                        ) {
                            settings.pushToTalkKey = key
                            controller.reloadHotkey()
                        }
                        .background {
                            if settings.pushToTalkKey == key {
                                RoundedRectangle(cornerRadius: DS.Radius.control)
                                    .fill(DS.Color.selection)
                            }
                        }
                    }
                }
                note("Hold this key anywhere to dictate. The window's Record button works "
                    + "regardless of what's focused.")

                Toggle(isOn: $settings.latchOnTap) {
                    Silkscreen(text: "Tap to lock on")
                }
                .toggleStyle(.switch)
                .onChange(of: settings.latchOnTap) { _, _ in controller.reloadHotkey() }
                note("A quick tap keeps the mic open until you tap again; holding still "
                    + "works as push-to-talk. ⌥⌘Z takes back the last thing dictated.")
            }

            panel(label: "Model") {
                HStack(spacing: DS.Space.snug) {
                    ForEach(SpeechEngineChoice.allCases, id: \.self) { choice in
                        TransportKey(
                            title: choice == .apple ? "Apple" : "Parakeet",
                            isEngaged: settings.engine == choice,
                            engagedColor: DS.Color.ink
                        ) {
                            settings.engine = choice
                        }
                        .background {
                            if settings.engine == choice {
                                RoundedRectangle(cornerRadius: DS.Radius.control)
                                    .fill(DS.Color.selection)
                            }
                        }
                    }
                }
                note(settings.engine == .apple
                    ? "Apple's on-device transcriber. Streams text while you speak; no download."
                    : "Parakeet on the Neural Engine. Resolves on release; ~470 MB model.")
            }

            panel(label: "Cleanup") {
                Toggle(isOn: $settings.cleanupEnabled) {
                    Silkscreen(text: "Clean up transcripts")
                }
                .toggleStyle(.switch)
                note("Strips fillers, fixes spacing and punctuation. The dictionary's "
                    + "corrections run either way.")

                // Also in the menu bar, and deliberately in both places: everything
                // below it does nothing without it, and a switch whose prerequisite
                // lives on another screen reads as a switch that doesn't work.
                Toggle(isOn: $settings.smartCleanup) {
                    Silkscreen(text: "Smart cleanup (on-device AI)")
                }
                .toggleStyle(.switch)
                .disabled(!settings.cleanupEnabled || !FoundationModelFormatter.isAvailable)
                if let reason = FoundationModelFormatter.unavailableReason {
                    note(reason)
                }

                Toggle(isOn: $settings.polishEnabled) {
                    Silkscreen(text: "Repair grammar")
                }
                .toggleStyle(.switch)
                .disabled(!settings.cleanupEnabled || !settings.smartCleanup)
                note("Lets smart cleanup fix agreement, tense and half-finished "
                    + "sentences instead of only tidying them. Numbers, dates, names, "
                    + "links and code are checked afterwards and the result is thrown "
                    + "away if any of them moved. On in every app until you switch it "
                    + "off in Tone by app.")

                HStack(spacing: DS.Space.snug) {
                    TransportKey(title: "Tone by app…") { isEditingProfiles = true }
                    Spacer()
                }
                note("Smart cleanup matches the app you're dictating into — longer "
                    + "sentences in Mail, one line in Slack, verbatim in an editor.")

                Toggle(isOn: $settings.screenContext) {
                    Silkscreen(text: "Read what's on screen")
                }
                .toggleStyle(.switch)
                note("Checks names against the app you're dictating into, so "
                    + "\u{201C}hud panel dot swift\u{201D} comes out as HUDPanel.swift. Only "
                    + "code-shaped names are matched, and the screen text is used for one "
                    + "transcript and discarded.")
            }

            panel(label: "Structure") {
                HStack(spacing: DS.Space.snug) {
                    TransportKey(title: "Structure\u{2026}") { isEditingStructure = true }
                    Spacer()
                }
                note("Spoken commands, lists, email greetings and sign-offs, and taking "
                    + "back what you retract. Rules, not a model \u{2014} they work with "
                    + "cleanup switched off.")
            }

        }
    }

    private func panel<Content: View>(
        label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.base) {
            Silkscreen(text: label, large: true)
            content()
        }
        .padding(DS.Space.roomy)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BrushedPanel())
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(DS.Font.label)
            .foregroundStyle(DS.Color.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
