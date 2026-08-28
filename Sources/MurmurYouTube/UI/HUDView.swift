import SwiftUI

/// The HUD's palette.
///
/// Kept as its own type rather than folded into `DS` because the HUD floats over other
/// apps rather than sitting in the window: it needs colors that hold up against an unknown
/// backdrop, which is a different problem from the rest of the design system.
enum Brand {
    static var accent: Color { DS.Color.accent }

    static var gradient: LinearGradient {
        LinearGradient(
            colors: [accent, accent.opacity(0.65)],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

/// The floating capsule that shows Murmur is listening.
///
/// Deliberately small. It sits over whatever you're working in, so it has to be readable
/// at a glance and forgettable the rest of the time — the previous version was a third
/// wider and nearly twice as tall for the same two pieces of information.
struct HUDView: View {
    @Bindable var controller: DictationController

    /// The capsule's dimensions. `HUDPanel` sizes its window to match.
    static let size = CGSize(width: 268, height: 44)

    var body: some View {
        HStack(spacing: DS.Space.base) {
            Waveform(level: controller.level, isActive: controller.state == .listening)
                .frame(width: 52, height: 16)

            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isError ? DS.Color.meterRed : .primary.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.easeOut(duration: 0.12), value: controller.transcript)

            // Latched recording looks identical to a held key from the outside, and the
            // difference matters: one stops when you let go, the other doesn't. Without
            // this the mic can stay open indefinitely with nothing on screen saying so.
            if controller.isLatched {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Brand.accent)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(DS.Motion.panel, value: controller.isLatched)
        .padding(.horizontal, DS.Space.roomy)
        .frame(width: Self.size.width, height: Self.size.height)
        .background {
            Capsule(style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(.primary.opacity(0.08), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.22), radius: 14, y: 5)
        }
    }

    private var isError: Bool {
        if case .error = controller.state { return true }
        return false
    }

    private var label: String {
        switch controller.state {
        case .starting: "Listening…"
        case .listening: controller.transcript.isEmpty ? "Listening…" : controller.transcript
        // Parakeet transcribes in one pass on release, so there's nothing to show until
        // it lands — say what's happening instead of leaving an empty pill.
        case .finishing: controller.transcript.isEmpty ? "Transcribing…" : controller.transcript
        case .error(let message): message
        case .idle: ""
        }
    }
}

/// A level-reactive bar meter.
///
/// Each bar has a fixed phase offset so the group ripples rather than pumping in unison,
/// and a weighting that favours the middle — a flat row of equal bars reads as a progress
/// indicator, not as sound.
private struct Waveform: View {
    let level: Float
    let isActive: Bool

    private static let barCount = 13
    private static let width: CGFloat = 2
    private static let minHeight: CGFloat = 2

    private static let phases: [Double] = (0..<barCount).map { index in
        // Irrational multiplier keeps the offsets from lining up into a visible period.
        (Double(index) * 0.618).truncatingRemainder(dividingBy: 1)
    }

    /// Bell-shaped weighting: tallest in the middle, tapering to the ends.
    private static let weights: [CGFloat] = (0..<barCount).map { index in
        let centred = Double(index) - Double(barCount - 1) / 2
        let spread = Double(barCount) / 3.4
        return CGFloat(exp(-(centred * centred) / (2 * spread * spread)))
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !isActive)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            GeometryReader { geometry in
                HStack(alignment: .center, spacing: 2) {
                    ForEach(0..<Self.barCount, id: \.self) { index in
                        Capsule()
                            .fill(Brand.gradient)
                            .frame(width: Self.width, height: height(for: index, at: time, in: geometry.size.height))
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
    }

    private func height(for index: Int, at time: TimeInterval, in available: CGFloat) -> CGFloat {
        guard isActive else { return Self.minHeight }

        let phase = Self.phases[index]
        let wave = sin(time * 7.0 + phase * .pi * 2)
        let amplitude = CGFloat(max(0.05, min(level * 1.4, 1)))
        // The wave rides on top of the level so bars still breathe during quiet passages.
        let scaled = amplitude * Self.weights[index] * (0.6 + 0.4 * CGFloat(wave))
        return Self.minHeight + max(0, scaled) * (available - Self.minHeight)
    }
}
