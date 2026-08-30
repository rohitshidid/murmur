import AppKit
import SwiftUI

/// The floating capsule that appears while you hold the key.
///
/// The single most important property here is that this panel **never becomes key**.
/// If it did, the user's text field would lose focus and `TextInjector` would have
/// nothing to insert into. Hence `.nonactivatingPanel` plus `canBecomeKey == false`.
@MainActor
final class HUDPanel: NSPanel {
    init(controller: DictationController) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: HUDView.size.width, height: HUDView.size.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        ignoresMouseEvents = true

        isOpaque = false
        backgroundColor = .clear
        // The capsule draws its own shadow, with `HUDView.margin` of clear space around it
        // to fall off into. The window's shadow would be a second one, traced around the
        // full rectangular frame — exactly the hard square edge this avoids.
        hasShadow = false

        let hosting = NSHostingView(rootView: HUDView(controller: controller))
        // An NSHostingView is layer-backed with an opaque backing colour by default, and
        // that layer is the rectangle you see behind a rounded panel.
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = .clear
        hosting.layer?.isOpaque = false
        contentView = hosting
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// How much clear space sits between the bottom of the capsule and the top of the Dock.
    ///
    /// Measured to the *capsule*, not the window: the window is taller by `HUDView.margin`
    /// on each side so the shadow has room, and positioning by the frame would leave the
    /// HUD floating that much higher than intended.
    private static let gapAboveDock: CGFloat = 18

    /// Parks the panel low on the active screen, horizontally centered.
    ///
    /// `NSScreen.main` is the screen with the *key window* — and an accessory app with a
    /// non-activating panel never has one, so it can be nil. Falling back to `screens.first`
    /// keeps the HUD on-screen instead of stranding it at the origin.
    func reposition() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            Log.app.error("no screen available to position HUD")
            return
        }
        let visible = screen.visibleFrame
        let size = frame.size
        setFrameOrigin(
            NSPoint(
                x: visible.midX - size.width / 2,
                y: visible.minY + Self.gapAboveDock - HUDView.margin
            )
        )
    }

    func present() {
        // Every active state change (starting → listening → finishing) calls this. Without
        // the early exit the panel would reset to alpha 0 and re-fade on each one, which
        // reads as a flicker mid-utterance.
        guard !isVisible || alphaValue < 1 else { return }

        reposition()
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            animator().alphaValue = 1
        }
    }

    func dismiss() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            // AppKit always calls this on the main thread.
            MainActor.assumeIsolated { self?.orderOut(nil) }
        }
    }
}
