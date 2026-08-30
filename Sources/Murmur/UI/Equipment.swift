import SwiftUI

/// The component library.
///
/// One rule holds the set together: a component draws a surface, a hairline, and its
/// content — nothing else. No gradients, no inner glows, no decorative detail. Anything
/// that wants to stand out does it with type, spacing or the accent.
///
/// The names are inherited from the previous, deliberately skeuomorphic design. They're
/// kept because every call site in the app spells them, and renaming twenty views is churn
/// that changes nothing a user can see.

// MARK: - Surfaces

/// A card. The primary raised surface: a fill, a hairline, a soft shadow.
struct BrushedPanel: View {
    var radius: CGFloat = DS.Radius.panel

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(DS.Color.panel)
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(DS.Color.seam, lineWidth: DS.Border.hairline)
            )
            .shadow(
                color: DS.Shadow.panel.color,
                radius: DS.Shadow.panel.radius,
                x: DS.Shadow.panel.x,
                y: DS.Shadow.panel.y
            )
    }
}

/// A recessed region — where a scrolling list lives.
///
/// Reads as *below* the window rather than above it, which is the only depth cue the
/// system uses: a card is lighter than its backdrop, a well is darker.
struct Well<Content: View>: View {
    var radius: CGFloat = DS.Radius.panel
    @ViewBuilder var content: Content

    var body: some View {
        content
            .background(DS.Color.well)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(DS.Color.seam, lineWidth: DS.Border.hairline)
            )
    }
}

/// A row inside a well.
struct DeckWindow<Content: View>: View {
    var radius: CGFloat = DS.Radius.chip
    @ViewBuilder var content: Content

    var body: some View {
        content
            .background(DS.Color.deck)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(DS.Color.seam, lineWidth: DS.Border.hairline)
            )
    }
}

// MARK: - Type

/// A small uppercase label: section headings, field labels, metadata.
///
/// Uppercase with a little tracking is the one typographic mannerism the design keeps —
/// it separates a label from content at a glance without needing a heavier weight or a
/// second color.
struct Silkscreen: View {
    let text: String
    var large = false
    var color: Color = DS.Color.silkscreen

    var body: some View {
        Text(text.uppercased())
            .font(large ? DS.Font.silkscreenLarge : DS.Font.silkscreen)
            .tracking(DS.Font.silkscreenTracking)
            .foregroundStyle(color)
    }
}

/// A number that changes in place — a duration, a count.
struct Readout: View {
    let text: String
    var large = false

    var body: some View {
        Text(text)
            .font(large ? DS.Font.counterLarge : DS.Font.counter)
            .foregroundStyle(DS.Color.ink)
    }
}

// MARK: - Indicators

/// A status dot. Lit dots carry a faint halo so the state reads without needing a label.
struct Lamp: View {
    let color: Color
    var isLit: Bool
    var size: CGFloat = DS.Material.lampSize

    var body: some View {
        Circle()
            .fill(isLit ? color : DS.Color.seam)
            .frame(width: size, height: size)
            .shadow(
                color: isLit ? color.opacity(DS.Material.lampGlow) : .clear,
                radius: size * 0.6
            )
            .animation(DS.Motion.lamp, value: isLit)
    }
}

/// Input level, as a row of bars that fill from the left.
///
/// A bar meter rather than the old swinging needle: it reads instantly at a glance, it
/// scales down to the HUD, and it doesn't ask the eye to decode an angle.
struct VUMeter: View {
    let level: Float
    var isActive: Bool

    private static let barCount = 24

    var body: some View {
        GeometryReader { geometry in
            let lit = Int((Double(min(max(level, 0), 1)) * Double(Self.barCount)).rounded())
            HStack(spacing: DS.Material.meterBarGap) {
                ForEach(0..<Self.barCount, id: \.self) { index in
                    Capsule()
                        .fill(color(at: index, lit: lit))
                        .frame(width: DS.Material.meterBarWidth)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
            .animation(.easeOut(duration: DS.Motion.levelRelease), value: lit)
        }
    }

    /// Warms toward amber near the top of the scale — the one place amber is allowed.
    private func color(at index: Int, lit: Int) -> Color {
        guard isActive, index < lit else { return DS.Color.seam }
        let fraction = Double(index) / Double(Self.barCount)
        return fraction >= DS.Material.meterWarmPoint ? DS.Color.meterAmber : DS.Color.accent
    }
}

// MARK: - Controls

/// The app's button.
///
/// One shape for every action: a pill that tints when engaged. `engagedColor` decides
/// whether it reads as a selection (accent) or as recording (red).
struct TransportKey: View {
    let title: String
    var systemImage: String?
    var isEngaged = false
    var engagedColor: Color = DS.Color.accent
    var isEnabled = true
    let action: () -> Void

    @State private var isPressed = false
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.tight) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(title)
                    .font(DS.Font.body)
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, DS.Space.base)
            .frame(height: DS.Material.keyHeight)
            .frame(minWidth: DS.Material.keyMinWidth)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                    .strokeBorder(
                        isEngaged ? engagedColor.opacity(0.35) : DS.Color.seam,
                        lineWidth: DS.Border.hairline
                    )
            )
            .scaleEffect(isPressed ? DS.Material.keyPressScale : 1)
            .opacity(isEnabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .animation(DS.Motion.press, value: isPressed)
        .animation(DS.Motion.release, value: isEngaged)
        .onHover { isHovering = $0 }
        // A plain button style gives no pressed state, and a control with no feedback on
        // click feels broken however fast it responds.
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
    }

    private var foreground: Color {
        isEngaged ? engagedColor : DS.Color.ink
    }

    private var background: Color {
        if isEngaged { return engagedColor.opacity(0.12) }
        return isHovering ? DS.Color.hover : DS.Color.cap
    }
}
