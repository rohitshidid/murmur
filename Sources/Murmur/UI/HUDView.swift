import AppKit
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

    /// The visible capsule.
    static let capsule = CGSize(width: 248, height: 40)

    /// Clear margin around the capsule, inside the window.
    ///
    /// **This is what stops the HUD looking like a rectangle.** A shadow is drawn *inside*
    /// its window, so when the window is exactly the size of the capsule the shadow is
    /// clipped square at the window's edge — which reads as a hard grey box around a
    /// rounded pill. The margin gives the blur somewhere to fall off to nothing.
    static let margin: CGFloat = 24

    /// The window size `HUDPanel` uses.
    static var size: CGSize {
        CGSize(width: capsule.width + margin * 2, height: capsule.height + margin * 2)
    }

    var body: some View {
        HStack(spacing: DS.Space.base) {
            // A banner is what the HUD shows *after* a hold — the result of a Command Mode
            // rewrite, or why there wasn't one. There is no audio behind it, so the meter is
            // replaced by an icon rather than left twitching at a level that is always zero.
            if let banner = controller.banner, !controller.state.isActive {
                Image(systemName: banner.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(banner.isError ? DS.Color.meterRed : Brand.accent)
                    .frame(width: 46, height: 14)
            } else {
                Waveform(level: controller.level, isActive: controller.state == .listening)
                    .frame(width: 46, height: 14)
            }

            // Command Mode records through the same capture and HUD as dictation, and the
            // two do completely different things to the text. Saying which one is holding
            // the mic open is the only thing on screen that tells them apart.
            if controller.mode == .command, controller.state.isActive {
                Text("Command")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Brand.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background {
                        Capsule().fill(Brand.accent.opacity(0.14))
                    }
                    .transition(.scale.combined(with: .opacity))
            }

            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isError ? DS.Color.meterRed : .primary.opacity(0.9))
                .animation(.easeOut(duration: 0.12), value: controller.banner)
                .lineLimit(1)
                // Head truncation is right for a live transcript — the newest words are the
                // ones being watched. It is wrong for a banner, where the whole line is the
                // message, so a banner shrinks to fit instead of losing its front.
                .truncationMode(showingBanner ? .tail : .head)
                .minimumScaleFactor(showingBanner ? 0.72 : 1)
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
        .animation(DS.Motion.panel, value: controller.mode)
        .padding(.horizontal, DS.Space.roomy)
        .frame(width: Self.capsule.width, height: Self.capsule.height)
        .background {
            // A real capsule-masked blur rather than SwiftUI's `.regularMaterial`. The
            // material's backdrop is laid out to the view's bounds, so at this size its
            // corners stay faintly visible against a busy window behind it; an
            // NSVisualEffectView takes an explicit mask and has no corners to show.
            CapsuleBlur()
                .clipShape(Capsule(style: .continuous))
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(.primary.opacity(0.07), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
                .shadow(color: .black.opacity(0.10), radius: 2, y: 1)
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }

    /// Whether the pill is showing the result of a finished hold rather than a live one.
    private var showingBanner: Bool {
        controller.banner != nil && !controller.state.isActive
    }

    private var isError: Bool {
        if case .error = controller.state { return true }
        if let banner = controller.banner, showingBanner { return banner.isError }
        return false
    }

    /// What a hold that hasn't produced words yet should say it is doing.
    ///
    /// Different in Command Mode because the two are waiting for different things. Dictation
    /// is waiting for words to type; Command Mode already has the text and is waiting to be
    /// told what to do with it, which is a question rather than an invitation.
    private var prompt: String {
        controller.mode == .command ? "What should I do with it?" : "Listening…"
    }

    private var label: String {
        // The banner outlives the session that produced it, so it wins only once that
        // session is over — a rewrite that lands while the next hold has already started
        // must not overwrite what that hold is showing.
        if let banner = controller.banner, !controller.state.isActive { return banner.text }

        switch controller.state {
        case .starting: return prompt
        case .listening: return controller.transcript.isEmpty ? prompt : controller.transcript
        // Parakeet transcribes in one pass on release, so there's nothing to show until
        // it lands — say what's happening instead of leaving an empty pill.
        case .finishing:
            if controller.mode == .command { return "Rewriting…" }
            return controller.transcript.isEmpty ? "Transcribing…" : controller.transcript
        case .error(let message): return message
        case .idle: return ""
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

// MARK: - Blur

/// A background blur masked to a capsule.
private struct CapsuleBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> MaskedEffectView {
        let view = MaskedEffectView()
        view.material = .hudWindow
        // Blurs the desktop and windows behind the panel, which is what makes the HUD sit
        // *in* the screen rather than on top of it. Needs a non-opaque window; `HUDPanel`
        // is one.
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: MaskedEffectView, context: Context) {}

    /// The mask is rebuilt on layout: it's a stretchable image whose caps are half the
    /// view's height, and that height isn't known when the view is created.
    final class MaskedEffectView: NSVisualEffectView {
        override func layout() {
            super.layout()
            let radius = bounds.height / 2
            guard radius > 0 else { return }
            maskImage = Self.capsuleMask(radius: radius)
        }

        private static func capsuleMask(radius: CGFloat) -> NSImage {
            // One pixel of straight edge between the two caps, stretched to any width.
            let edge = radius * 2 + 1
            let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
                NSColor.black.setFill()
                NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
                return true
            }
            image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
            image.resizingMode = .stretch
            return image
        }
    }
}
