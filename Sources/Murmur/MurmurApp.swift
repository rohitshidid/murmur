import AppKit
import SwiftUI

@main
struct MurmurApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // The main window. A `Window` rather than a `WindowGroup`: this app has one front
        // panel, and letting ⌘N spawn a second copy of a tape deck makes no sense.
        Window("Murmur", id: "main") {
            MainWindow(controller: delegate.controller)
        }
        .defaultSize(width: 860, height: 620)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Reveal Dictionary File") {
                    NSWorkspace.shared.activateFileViewerSelecting([DictionaryStore.fileURL])
                }
            }
        }

        // Fully qualified: this app has its own `Settings` type, which otherwise shadows
        // SwiftUI's settings scene.
        SwiftUI.Settings {
            SettingsWindow(controller: delegate.controller)
        }

        // Secondary now: status and the hotkey while you're working in another app.
        MenuBarExtra {
            MenuContent(controller: delegate.controller)
        } label: {
            Image(systemName: delegate.controller.state.isActive ? "waveform.circle.fill" : "waveform")
        }

    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = DictationController()
    private var hud: HUDPanel?
    private var stateObservation: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A regular app now: dock icon, app menu, standard windows. The HUD is still a
        // non-activating panel, so dictating into another app never steals its focus — that
        // property belongs to the panel, not to the activation policy.
        NSApp.setActivationPolicy(.regular)

        hud = HUDPanel(controller: controller)

        let armed = controller.activate()
        if !armed {
            Permissions.promptForAccessibility()
            // The tap can only be created once the user grants Accessibility, and there's
            // no notification for that — poll until it takes.
            retryActivation()
        }

        // Parakeet's models take ~20s to load from disk, and that cost lands on whichever
        // dictation touches them first — so the first hold after every launch would stall
        // with the HUD showing nothing. Warm them in the background instead, but only when
        // they're actually going to be used and are already downloaded.
        let willUseParakeet = Settings.shared.engine == .parakeet
        if willUseParakeet, ParakeetModels.isDownloaded {
            Task.detached(priority: .utility) {
                _ = try? await ParakeetModels.shared.manager()
            }
        }


        observeState()
        // Told apart on purpose. Announcing "ready" while the tap failed to install is how
        // an ungranted app reads as a broken one: the key does nothing and the log says
        // everything is fine.
        if armed {
            Log.app.info("Murmur ready — hold \(Settings.shared.pushToTalkKey.displayName) to dictate")
        } else {
            Log.app.error("push-to-talk is OFF — Accessibility not granted. The Record button still works.")
        }
    }

    /// `murmur://clear` empties the history — a scriptable hook, kept because it costs a
    /// dozen lines and is the only way to clear history without the UI.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "murmur" && url.host == "clear" {
            RunLog.clear()
            RunStore.shared.reload()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.deactivate()
    }

    /// Shows and hides the HUD in step with the controller's state.
    private func observeState() {
        withObservationTracking {
            _ = controller.state
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.controller.state.isActive {
                    self.hud?.present()
                } else {
                    self.hud?.dismiss()
                }
                self.observeState()
            }
        }
    }

    /// Polls until the tap actually installs.
    ///
    /// The condition is `activate()`, not `Permissions.hasAccessibility`. Those are not the
    /// same question, and the difference is the bug: TCC stores a code-signing requirement,
    /// so after an unsigned rebuild the stored grant no longer matches the binary — and the
    /// old loop would exit on `hasAccessibility`, log "hotkey armed", and leave the tap
    /// dead. Asking whether the tap was created cannot be wrong about it.
    ///
    /// Safe to call repeatedly: both monitors `stop()` before they start.
    private func retryActivation() {
        Task { @MainActor in
            while !controller.activate() {
                try? await Task.sleep(for: .seconds(1))
            }
            Log.app.info("Accessibility granted — hotkey armed")
        }
    }
}

private struct MenuContent: View {
    @Bindable var controller: DictationController
    @State private var settings = Settings.shared
    @Environment(\.openWindow) private var openWindow
    @State private var isPreloadingParakeet = false
    @State private var parakeetOnDisk = ParakeetModels.isDownloaded

    /// Read while the body is evaluated rather than in `onAppear`.
    ///
    /// `onAppear` does not reliably fire for `MenuBarExtra` content — SwiftUI turns it into
    /// `NSMenu` items rather than mounting views — so a list populated there stays empty and
    /// the picker shows nothing. Computing it here also keeps it fresh: devices come and go
    /// with cables and Bluetooth, so a list cached at launch is wrong by the time you look.
    private var inputs: [AudioInputDevice] { AudioDevices.inputs() }
    private var activeInput: AudioInputDevice? { AudioDevices.active(uid: settings.inputDeviceUID) }

    private var parakeetStatus: String {
        if isPreloadingParakeet { return "Loading Parakeet models…" }
        // Reflects what's actually on disk, not just what this menu instance has done.
        return parakeetOnDisk ? "Parakeet models installed ✓" : "Download Parakeet models…"
    }

    /// The microphone in use, and every other one available.
    ///
    /// "System default" is a real choice rather than the absence of one: picking it means
    /// the app follows whatever you change the system to later.
    private var microphonePicker: some View {
        Picker("Microphone", selection: Binding(
            get: { settings.inputDeviceUID ?? "" },
            set: { settings.inputDeviceUID = $0.isEmpty ? nil : $0 }
        )) {
            Text(systemDefaultTitle).tag("")
            Divider()
            ForEach(inputs) { device in
                Text(device.name).tag(device.uid)
            }
        }
    }

    private var systemDefaultTitle: String {
        guard let name = AudioDevices.systemDefaultInput()?.name else { return "System default" }
        return "System default (\(name))"
    }

    private func preloadParakeet() {
        guard !isPreloadingParakeet else { return }
        isPreloadingParakeet = true
        Task {
            do {
                _ = try await ParakeetModels.shared.manager()
                parakeetOnDisk = ParakeetModels.isDownloaded
            } catch {
                Log.speech.error("Parakeet preload failed: \(error.localizedDescription)")
            }
            isPreloadingParakeet = false
        }
    }

    var body: some View {
        Text("Hold \(settings.pushToTalkKey.displayName) to dictate")

        Text(activeInput.map { "Microphone: \($0.name)" } ?? "Microphone: none found")

        Divider()

        microphonePicker

        Picker("Push-to-talk key", selection: Binding(
            get: { settings.pushToTalkKey },
            set: { key in
                settings.pushToTalkKey = key
                controller.reloadHotkey()
            }
        )) {
            ForEach(PushToTalkKey.allCases, id: \.self) { key in
                Text(key.displayName).tag(key)
            }
        }

        Picker("Engine", selection: $settings.engine) {
            ForEach(SpeechEngineChoice.allCases, id: \.self) { choice in
                Text(choice.displayName).tag(choice)
            }
        }

        Toggle("Clean up text", isOn: $settings.cleanupEnabled)

        if settings.cleanupEnabled {
            Toggle("Smart cleanup (on-device AI)", isOn: $settings.smartCleanup)
                .disabled(!FoundationModelFormatter.isAvailable)
            if let reason = FoundationModelFormatter.unavailableReason {
                Text(reason).font(.caption)
            }
        }

        Toggle("Sound", isOn: $settings.soundEnabled)

        Divider()

        // Downloading ~470 MB on the first hold would look like a hang, so offer to do it
        // deliberately instead.
        if settings.engine == .parakeet {
            Button(parakeetStatus) { preloadParakeet() }
                .disabled(isPreloadingParakeet || parakeetOnDisk)
        }

        if !Permissions.hasAccessibility {
            Button("Grant Accessibility…") { Permissions.openAccessibilitySettings() }
        }
        if !Permissions.hasMicrophone {
            Button("Grant Microphone…") { Permissions.openMicrophoneSettings() }
        }

        Button("Quit Murmur") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
