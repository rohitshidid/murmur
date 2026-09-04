import MurmurFormatting
import SwiftUI

/// The structure settings: what the deterministic pass is allowed to do to a transcript.
///
/// A sheet rather than another panel in Settings for the same reason `ProfilesPanel` is one
/// — Settings is a fixed-height window of short controls, and this is a dozen switches that
/// most people set once and never open again.
struct StructurePanel: View {
    @Environment(\.dismiss) private var dismiss
    @State private var settings = Settings.shared
    @State private var phrases: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.roomy) {
            VStack(alignment: .leading, spacing: DS.Space.tight) {
                Silkscreen(text: "Structure", large: true)
                note("Punctuation, lists and email shape, applied by rules rather than by a "
                    + "model — so they work with cleanup off and on every Mac.")
            }

            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.wide) {
                    identity
                    commands
                    lists
                    email
                    retraction
                }
                .padding(.trailing, DS.Space.snug)
            }

            HStack {
                Spacer()
                TransportKey(title: "Done", isEngaged: true, engagedColor: DS.Color.ink) {
                    commitPhrases()
                    dismiss()
                }
            }
        }
        .padding(DS.Space.panel)
        .frame(width: 560, height: 620)
        .background(BrushedPanel(radius: DS.Radius.window))
        .onAppear { phrases = settings.extraRetractionPhrases.joined(separator: ", ") }
    }

    // MARK: - Sections

    private var identity: some View {
        section("Signature") {
            field("Sign as", text: $settings.userName, prompt: NSFullUserName())
            note("Used to lay out a sign-off: say \u{201C}thanks\u{201D} and your name and it "
                + "becomes two lines. Both the full name and the first name are matched. "
                + "Leave it empty to switch sign-offs off entirely.")

            Toggle(isOn: $settings.fieldContext) {
                Silkscreen(text: "Know which field I'm in")
            }
            .toggleStyle(.switch)
            note("Reads the field's label and the text before the cursor, so a subject line, "
                + "a search box and an email body are told apart. Nothing is stored.")
        }
    }

    private var commands: some View {
        section("Spoken commands") {
            Toggle(isOn: $settings.voiceCommands) {
                Silkscreen(text: "Listen for commands")
            }
            .toggleStyle(.switch)
            note("New paragraph · new line · bullet point · next item · number one · "
                + "end list · question mark · em dash · open quote · all caps <word> · "
                + "<word> cap that.")
        }
    }

    private var lists: some View {
        section("Lists") {
            Toggle(isOn: $settings.smartLists) {
                Silkscreen(text: "Recognise a spoken list")
            }
            .toggleStyle(.switch)
            note("\u{201C}First, buy milk. Second, call the bank\u{201D} becomes a list. It "
                + "takes at least two items counting up from one, so an ordinary sentence "
                + "with \u{201C}first\u{201D} in it is left alone. Each app's marker style is "
                + "set in Tone by app.")
        }
    }

    private var email: some View {
        section("Email") {
            Toggle(isOn: $settings.emailShape) {
                Silkscreen(text: "Lay out greetings and sign-offs")
            }
            .toggleStyle(.switch)
            note("In an email body only. \u{201C}Hi Sarah I wanted to check\u{201D} gets its "
                + "own line; \u{201C}thanks Rohit\u{201D} becomes a signature block.")

            Toggle(isOn: $settings.autoSignOff) {
                Silkscreen(text: "Add my name to a bare closing")
            }
            .toggleStyle(.switch)
            .disabled(!settings.emailShape || settings.signatureNames.isEmpty)
            note("The one place a word you didn't say gets typed, so it has its own switch. "
                + "Off, a sign-off only appears when you speak your name.")
        }
    }

    private var retraction: some View {
        section("Taking things back") {
            Toggle(isOn: $settings.retraction) {
                Silkscreen(text: "Listen for retractions")
            }
            .toggleStyle(.switch)
            note("Scratch that · strike that · delete that · no wait · never mind that · "
                + "let me start that again. Say \u{201C}scratch all that\u{201D} to drop "
                + "everything said so far.")

            Silkscreen(text: "How much to erase")
            HStack(spacing: DS.Space.snug) {
                ForEach(RetractionScope.allCases, id: \.self) { scope in
                    TransportKey(
                        title: scope.displayName,
                        isEngaged: settings.retractionScope == scope,
                        engagedColor: DS.Color.ink
                    ) {
                        settings.retractionScope = scope
                    }
                    .background {
                        if settings.retractionScope == scope {
                            RoundedRectangle(cornerRadius: DS.Radius.control).fill(DS.Color.selection)
                        }
                    }
                }
            }
            .disabled(!settings.retraction)
            note(scopeNote)

            field("Also treat as a retraction", text: $phrases, prompt: "forget that, drop that")
                .onSubmit { commitPhrases() }
            note("Comma separated. Keep them distinctive — a phrase that turns up in ordinary "
                + "speech will eat words you meant to keep. What a retraction erased is kept "
                + "in History.")
        }
    }

    private var scopeNote: String {
        switch settings.retractionScope {
        case .clause:
            "Back to the last comma. Tightest, and leaves most of a long sentence behind."
        case .sentence:
            "Back to the start of the sentence. If the retraction is a sentence of its own, "
                + "it reaches back to the one before it."
        case .utterance:
            "Everything said before the retraction, every time."
        }
    }

    // MARK: - Plumbing

    private func commitPhrases() {
        settings.extraRetractionPhrases = phrases
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func section<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.snug) {
            Silkscreen(text: label)
            content()
        }
        .padding(DS.Space.roomy)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Color.well, in: .rect(cornerRadius: DS.Radius.panel))
    }

    private func field(_ label: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.tight) {
            Silkscreen(text: label)
            TextField(prompt, text: text)
                .textFieldStyle(.plain)
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.inkOnDeck)
                .padding(DS.Space.snug)
                .background(DS.Color.deck, in: .rect(cornerRadius: DS.Radius.chip))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.chip)
                        .strokeBorder(DS.Color.seam, lineWidth: DS.Border.hairline)
                )
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(DS.Font.caption)
            .foregroundStyle(DS.Color.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
