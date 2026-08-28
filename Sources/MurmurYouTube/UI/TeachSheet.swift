import MurmurDictionary
import SwiftUI

/// Turns a wrong transcript into a dictionary entry.
///
/// The signal worth learning from is "text Murmur got wrong that you fixed by hand", and
/// this is the explicit way to capture it: pick the words it misheard, type what they
/// should have been, and the entry is built for you.
///
/// The alternative — watching the focused text field after an injection and diffing to
/// infer corrections — was rejected deliberately. It reads the user's text after the fact,
/// and `TextInjector` already documents that Electron and Chrome lie about Accessibility,
/// so it would be least reliable in exactly the apps most dictation lands in.
///
/// Words are picked rather than typed because the misheard phrase has to match the
/// transcript *exactly* to be worth a rule, and retyping it by hand is the one step where a
/// typo makes the rule silently never fire.
struct TeachSheet: View {
    let transcript: String

    @Environment(\.dismiss) private var dismiss
    @State private var store = DictionaryStore.shared

    /// Indices into `words`. Kept contiguous — a correction trigger is a phrase, not a set.
    @State private var selection: Range<Int>?
    @State private var write = ""
    @State private var kind: DictionaryEntry.Kind = .correction

    private var words: [String] {
        transcript.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    private var hear: String {
        guard let selection else { return "" }
        return words[selection].joined(separator: " ")
    }

    /// Trailing punctuation is stripped from the trigger.
    ///
    /// The engine's comma is not part of what it misheard, and leaving it in makes a rule
    /// that only fires when the phrase lands at the same place in a sentence.
    private var trigger: String {
        hear.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
    }

    private var draft: DictionaryEntry {
        DictionaryEntry(
            kind: kind,
            write: write.trimmingCharacters(in: .whitespacesAndNewlines),
            hear: trigger
        )
    }

    private var warnings: [DictionaryWarning] { DictionaryWarning.check(draft) }

    private var isValid: Bool { !draft.hear.isEmpty && !draft.write.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.roomy) {
            VStack(alignment: .leading, spacing: DS.Space.tight) {
                Silkscreen(text: "Teach the dictionary", large: true)
                Text(selection == nil
                    ? "Click the words it got wrong."
                    : "Click a neighbouring word to extend, or an end to shrink.")
                    .font(DS.Font.label)
                    .foregroundStyle(DS.Color.inkSecondary)
            }

            wordPicker

            VStack(alignment: .leading, spacing: DS.Space.base) {
                labelled("When you hear") {
                    Text(trigger.isEmpty ? "—" : trigger)
                        .font(DS.Font.body)
                        .foregroundStyle(trigger.isEmpty
                            ? DS.Color.inkOnDeck.opacity(0.4)
                            : DS.Color.inkOnDeck)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, DS.Space.snug)
                        .padding(.vertical, DS.Space.snug)
                        .background(DS.Color.deck, in: .rect(cornerRadius: DS.Radius.chip))
                }

                labelled(kind == .snippet ? "Expands to" : "Write instead") {
                    TextField(kind == .snippet ? "the block to insert" : "the right words", text: $write)
                        .textFieldStyle(.plain)
                        .font(DS.Font.body)
                        .foregroundStyle(DS.Color.inkOnDeck)
                        .padding(.horizontal, DS.Space.snug)
                        .padding(.vertical, DS.Space.snug)
                        .background(DS.Color.deck, in: .rect(cornerRadius: DS.Radius.chip))
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.Radius.chip)
                                .strokeBorder(DS.Color.seam, lineWidth: DS.Border.hairline)
                        )
                }
            }

            kindPicker

            ForEach(warnings) { warning in
                HStack(alignment: .top, spacing: DS.Space.snug) {
                    Lamp(color: DS.Color.meterAmber, isLit: true, size: 6)
                        .padding(.top, 3)
                    Text(warning.message)
                        .font(DS.Font.label)
                        .foregroundStyle(DS.Color.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(DS.Space.snug)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.chip)
                        .strokeBorder(DS.Color.meterAmber.opacity(0.4), lineWidth: DS.Border.hairline)
                )
            }

            HStack(spacing: DS.Space.snug) {
                Spacer()
                TransportKey(title: "Cancel") { dismiss() }
                TransportKey(title: "Add", isEngaged: isValid, engagedColor: DS.Color.ink) {
                    guard isValid else { return }
                    store.add(draft)
                    dismiss()
                }
                .disabled(!isValid)
            }
        }
        .padding(DS.Space.panel)
        .frame(width: 520)
        .background(BrushedPanel(radius: DS.Radius.window))
    }

    private var wordPicker: some View {
        WrapLayout(spacing: DS.Space.tight) {
            ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                let isSelected = selection?.contains(index) ?? false
                Button {
                    withAnimation(DS.Motion.panel) { toggle(index) }
                } label: {
                    Text(word)
                        .font(DS.Font.body)
                        .foregroundStyle(isSelected ? DS.Color.ink : DS.Color.inkOnDeck)
                        .padding(.horizontal, DS.Space.snug)
                        .padding(.vertical, DS.Space.tight)
                        .background(
                            isSelected ? DS.Color.selection : DS.Color.deck,
                            in: .rect(cornerRadius: DS.Radius.chip)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(DS.Space.snug)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Color.well, in: .rect(cornerRadius: DS.Radius.panel))
    }

    private var kindPicker: some View {
        HStack(spacing: DS.Space.snug) {
            ForEach([DictionaryEntry.Kind.correction, .snippet], id: \.self) { candidate in
                TransportKey(
                    title: candidate == .correction ? "Correction" : "Snippet",
                    isEngaged: kind == candidate,
                    engagedColor: DS.Color.ink
                ) {
                    withAnimation(DS.Motion.panel) { kind = candidate }
                }
                .background {
                    if kind == candidate {
                        RoundedRectangle(cornerRadius: DS.Radius.control).fill(DS.Color.selection)
                    }
                }
            }
            Spacer()
        }
    }

    /// Keeps the selection one contiguous run: extend at either edge, shrink from either
    /// edge, and jump elsewhere to start again.
    private func toggle(_ index: Int) {
        guard let current = selection else {
            selection = index..<(index + 1)
            return
        }

        if index == current.lowerBound - 1 {
            selection = index..<current.upperBound
        } else if index == current.upperBound {
            selection = current.lowerBound..<(index + 1)
        } else if index == current.lowerBound, current.count > 1 {
            selection = (current.lowerBound + 1)..<current.upperBound
        } else if index == current.upperBound - 1, current.count > 1 {
            selection = current.lowerBound..<(current.upperBound - 1)
        } else if current.contains(index) {
            selection = nil
        } else {
            selection = index..<(index + 1)
        }
    }

    private func labelled<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.tight) {
            Silkscreen(text: label)
            content()
        }
    }
}

/// Left-aligned wrapping row layout.
///
/// `LazyVGrid` can't do this: the words have wildly different widths and a grid would
/// either clip the long ones or leave a ragged column of whitespace after the short ones.
struct WrapLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = layout(subviews: subviews, in: width)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var y = bounds.minY
        for row in layout(subviews: subviews, in: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func layout(subviews: Subviews, in width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width

            if needed > width, !row.indices.isEmpty {
                rows.append(row)
                row = Row()
            }

            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }

        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}
