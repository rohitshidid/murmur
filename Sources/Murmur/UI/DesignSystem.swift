import SwiftUI

/// The design system for Murmur YouTube.
///
/// Direction: quiet, modern macOS. Flat surfaces, one hairline border, generous radii, a
/// single accent, and type doing most of the work. Depth comes from a soft shadow and a
/// change of surface — never from bevels, grain or gloss.
///
/// Every value a view needs lives here; components never declare their own colors, sizes,
/// radii or durations.
///
/// The rules that keep this from drifting:
/// - **One accent.** Indigo. Selection, focus and the level meter all borrow it.
/// - **Red means recording.** Nothing else in the app is red.
/// - **Two surfaces per screen at most** — the window, and cards on it. A card inside a
///   card inside a well is how a clean layout turns to mud.
/// - **Borders are hairlines.** If something needs to stand out, change its surface or its
///   type, not its border weight.
enum DS {

    // MARK: - Color

    /// Surfaces, from the window backdrop inward. `face` resolves light and dark.
    enum Color {
        /// The window backdrop. Everything else sits on this.
        static let chassis = face(light: 0xF6F6F8, dark: 0x0C0C0E)

        /// A card: the primary raised surface.
        static let panel = face(light: 0xFFFFFF, dark: 0x171719)
        /// A card under the pointer.
        static let panelHighlight = face(light: 0xFBFBFC, dark: 0x1D1D20)
        /// A card pushed back — headers, footers, secondary strips.
        static let panelShade = face(light: 0xF1F1F4, dark: 0x131315)

        /// A recessed region: the scrolling area a list lives in.
        static let well = face(light: 0xF1F1F4, dark: 0x121214)
        /// A row inside a well.
        static let deck = face(light: 0xFFFFFF, dark: 0x1A1A1D)
        /// A control surface — a button or a field.
        static let cap = face(light: 0xFFFFFF, dark: 0x212125)

        /// The single hairline used for every border in the app.
        static let seam = face(light: 0xE4E4E8, dark: 0x2B2B30)

        /// Primary text.
        static let ink = face(light: 0x18181B, dark: 0xF3F3F5)
        /// Supporting text: captions, hints, metadata.
        static let inkSecondary = face(light: 0x71717A, dark: 0x9B9BA4)
        /// Small uppercase labels.
        static let silkscreen = face(light: 0x8A8A93, dark: 0x83838C)
        /// Text on a card. Kept distinct from `ink` because rows and the window backdrop
        /// were different materials in the old system and call sites still say which.
        static let inkOnDeck = face(light: 0x18181B, dark: 0xF3F3F5)

        /// The one accent. Selection, focus, level, and the HUD.
        static let accent = face(light: 0x5B5BD6, dark: 0x7C7CF0)

        /// Recording. The only red in the app.
        static let record = face(light: 0xE5484D, dark: 0xF2555A)

        /// A selected row.
        static let selection = face(light: 0xEDEDFD, dark: 0x232340)
        /// Hover, which must be felt rather than seen.
        static let hover = face(light: 0xF4F4F6, dark: 0x232327)

        /// Level instrumentation. Amber appears here and nowhere else.
        static let meterGreen = face(light: 0x1FA463, dark: 0x35C07E)
        static let meterAmber = face(light: 0xC77A0A, dark: 0xE0A33A)
        static let meterRed = face(light: 0xDC3E43, dark: 0xEF5A5F)

        // MARK: Face resolution

        /// Resolves to the light or dark value for the current appearance.
        private static func face(light: UInt32, dark: UInt32) -> SwiftUI.Color {
            SwiftUI.Color(nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return NSColor(hex: isDark ? dark : light)
            })
        }
    }

    // MARK: - Material

    /// Sizes for the few components that still need a fixed physical dimension.
    enum Material {
        /// Standard control height. Modern and compact rather than chunky.
        static let keyHeight: CGFloat = 28
        static let keyMinWidth: CGFloat = 56
        static let keyPressScale: CGFloat = 0.97

        /// A status dot.
        static let lampSize: CGFloat = 7
        static let lampGlow: Double = 0.35

        /// The level meter: a slim rounded bar rather than a needle.
        static let meterHeight: CGFloat = 6
        static let meterBarWidth: CGFloat = 3
        static let meterBarGap: CGFloat = 3
        /// Above this fraction of full scale the meter warms toward amber.
        static let meterWarmPoint: Double = 0.72
    }

    // MARK: - Type

    /// System type throughout. The old face used a grotesque to imitate silkscreen
    /// printing; a modern macOS app should look like it belongs on the system.
    enum Font {
        static let silkscreen = SwiftUI.Font.system(size: 10, weight: .semibold)
        static let silkscreenLarge = SwiftUI.Font.system(size: 12, weight: .semibold)
        static let caption = SwiftUI.Font.system(size: 11, weight: .regular)
        static let label = SwiftUI.Font.system(size: 11, weight: .regular)
        static let body = SwiftUI.Font.system(size: 13, weight: .regular)
        static let bodyEmphasis = SwiftUI.Font.system(size: 13, weight: .semibold)
        static let title = SwiftUI.Font.system(size: 17, weight: .semibold)

        /// Numbers that change in place — timings, counters — so digits don't jitter.
        static let counter = SwiftUI.Font.system(size: 12, design: .monospaced).monospacedDigit()
        static let counterLarge = SwiftUI.Font.system(size: 28, weight: .medium, design: .monospaced)
            .monospacedDigit()

        /// Letter-spacing for the small uppercase labels.
        static let silkscreenTracking: CGFloat = 0.6
    }

    // MARK: - Space

    enum Space {
        static let hair: CGFloat = 2
        static let tight: CGFloat = 4
        static let snug: CGFloat = 8
        static let base: CGFloat = 12
        static let roomy: CGFloat = 16
        static let wide: CGFloat = 24
        static let panel: CGFloat = 28
    }

    // MARK: - Radius

    /// Generous and consistent. The old system kept radii tiny to read as machined metal;
    /// this one rounds everything the way the rest of the OS does.
    enum Radius {
        static let none: CGFloat = 0
        static let chip: CGFloat = 6
        static let control: CGFloat = 8
        static let panel: CGFloat = 12
        static let window: CGFloat = 16
    }

    // MARK: - Border

    enum Border {
        static let hairline: CGFloat = 1
        static let seam: CGFloat = 1
    }

    // MARK: - Shadow

    /// Soft and shallow. A card is a sheet of paper a millimetre off the page, not a block.
    enum Shadow {
        static let raised = Spec(color: .black.opacity(0.10), radius: 3, x: 0, y: 1)
        static let pressed = Spec(color: .black.opacity(0.06), radius: 1, x: 0, y: 0)
        static let panel = Spec(color: .black.opacity(0.08), radius: 12, x: 0, y: 3)
        static let window = Spec(color: .black.opacity(0.18), radius: 32, x: 0, y: 12)

        struct Spec {
            let color: SwiftUI.Color
            let radius: CGFloat
            let x: CGFloat
            let y: CGFloat
        }
    }

    // MARK: - Motion

    /// Soft springs. Things settle rather than snap.
    enum Motion {
        static let press = Animation.spring(response: 0.16, dampingFraction: 0.7)
        static let release = Animation.spring(response: 0.28, dampingFraction: 0.75)
        static let panel = Animation.spring(response: 0.32, dampingFraction: 0.86)
        static let lamp = Animation.easeOut(duration: 0.14)

        static let levelRelease: TimeInterval = 0.32
    }
}

// MARK: - Hex helpers

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
