import AVFoundation
import AppKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let recorder = AudioRecorder()
    private var timer: Timer?
    private var startedAt: Date?
    private var lastNoteURL: URL?
    private var statusText = "Ready"
    private var isBusy = false

    private let recordItem = NSMenuItem(title: "Start Recording", action: #selector(toggleRecording), keyEquivalent: "r")
    private let statusLine = NSMenuItem(title: "Ready", action: nil, keyEquivalent: "")
    private let openLastItem = NSMenuItem(title: "Open Last Note", action: #selector(openLastNote), keyEquivalent: "o")
    private let systemAudioItem = NSMenuItem(title: "Capture System Audio", action: #selector(toggleSystemAudio), keyEquivalent: "")

    private var captureSystemAudio = true
    private var controlWindow: ControlWindowController?
    private var hotKey: GlobalHotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        captureSystemAudio = Config.shared.bool("CAPTURE_SYSTEM_AUDIO", default: true)
        try? FileManager.default.createDirectory(at: Config.shared.notesDirectory, withIntermediateDirectories: true)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "Meeting Notes")
        statusItem.button?.imagePosition = .imageLeading
        buildMenu()
        buildControlWindow()
        installHotKey()
        requestNotificationPermission()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if recorder.isRecording {
            // Don't lose the meeting: seal what we have.
            let semaphore = DispatchSemaphore(value: 0)
            Task { _ = await recorder.stop(); semaphore.signal() }
            _ = semaphore.wait(timeout: .now() + 5)
        }
    }

    // MARK: - Menu

    private func buildMenu() {
        let menu = NSMenu()
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        recordItem.target = self
        menu.addItem(recordItem)

        systemAudioItem.target = self
        systemAudioItem.state = captureSystemAudio ? .on : .off
        menu.addItem(systemAudioItem)
        menu.addItem(.separator())

        let windowItem = NSMenuItem(title: "Show Control Window", action: #selector(showControlWindow), keyEquivalent: "")
        windowItem.target = self
        menu.addItem(windowItem)
        menu.addItem(.separator())

        openLastItem.target = self
        openLastItem.isEnabled = false
        menu.addItem(openLastItem)

        let folderItem = NSMenuItem(title: "Open Notes Folder", action: #selector(openFolder), keyEquivalent: "")
        folderItem.target = self
        menu.addItem(folderItem)

        let settingsItem = NSMenuItem(title: "Edit .env…", action: #selector(editEnv), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let diagnosticsItem = NSMenuItem(title: "Diagnostics…", action: #selector(showDiagnostics), keyEquivalent: "")
        diagnosticsItem.target = self
        menu.addItem(diagnosticsItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Meeting Notes", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func refreshUI() {
        statusLine.title = statusText
        openLastItem.isEnabled = lastNoteURL != nil
        systemAudioItem.isEnabled = !recorder.isRecording && !isBusy
        recordItem.isEnabled = !isBusy

        if recorder.isRecording {
            recordItem.title = "Stop Recording"
            statusItem.button?.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Recording")
            statusLine.title = "Recording — " + NoteWriter.humanDuration(recorder.elapsed)
        } else {
            recordItem.title = "Start Recording"
            statusItem.button?.image = NSImage(systemSymbolName: isBusy ? "hourglass" : "waveform.circle",
                                               accessibilityDescription: "Meeting Notes")
        }
        // Never set a title: it widens the item, and macOS silently drops status
        // items that no longer fit (notched displays especially).
        statusItem.button?.title = ""

        controlWindow?.update(isRecording: recorder.isRecording,
                              isBusy: isBusy,
                              status: statusText,
                              elapsed: recorder.elapsed,
                              captureSystemAudio: captureSystemAudio,
                              hasLastNote: lastNoteURL != nil)
    }

    private func buildControlWindow() {
        controlWindow = ControlWindowController(actions: .init(
            toggleRecording: { [weak self] in self?.toggleRecording() },
            setCaptureSystemAudio: { [weak self] enabled in
                guard let self else { return }
                self.captureSystemAudio = enabled
                self.systemAudioItem.state = enabled ? .on : .off
            },
            openNotesFolder: { [weak self] in self?.openFolder() },
            openLastNote: { [weak self] in self?.openLastNote() },
            showDiagnostics: { [weak self] in self?.showDiagnostics() }))
        refreshUI()
    }

    private func installHotKey() {
        hotKey = GlobalHotKey { [weak self] in self?.toggleRecording() }
        GlobalHotKey.shared = hotKey
        if hotKey == nil {
            NSLog("MeetingNotes: could not register the \(GlobalHotKey.displayName) hotkey — another app may already own it.")
        }
    }

    @objc private func showControlWindow() {
        controlWindow?.show()
        refreshUI()
    }

    /// Re-opening the app from Finder or the Dock surfaces the window instead of
    /// doing nothing, which is the fallback when the menu bar icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showControlWindow()
        return true
    }

    private func setStatus(_ text: String) {
        statusText = text
        refreshUI()
    }

    // MARK: - Actions

    @objc private func toggleSystemAudio() {
        captureSystemAudio.toggle()
        systemAudioItem.state = captureSystemAudio ? .on : .off
    }

    @objc private func toggleRecording() {
        if recorder.isRecording {
            Task { await stopRecording() }
        } else {
            Task { await startRecording() }
        }
    }

    private func startRecording() async {
        Config.shared.reload()

        guard await AudioRecorder.requestMicrophoneAccess() else {
            presentPermissionAlert(
                title: "Microphone access is needed",
                message: "Meeting Notes records your side of the conversation through the microphone.\n\nOpen System Settings › Privacy & Security › Microphone and enable Meeting Notes.",
                settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
            return
        }

        var wantsSystemAudio = captureSystemAudio
        if wantsSystemAudio && !AudioRecorder.screenRecordingAuthorized() {
            AudioRecorder.requestScreenRecordingAccess()
            if !AudioRecorder.screenRecordingAuthorized() {
                switch askAboutScreenRecording() {
                case .openSettings:
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                    return
                case .micOnly:
                    wantsSystemAudio = false
                case .cancel:
                    return
                }
            }
        }

        let started = Date()
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingnotes-\(NoteWriter.basename(for: started))-\(UUID().uuidString.prefix(6)).wav")
        do {
            try await recorder.start(outputURL: scratch, captureSystemAudio: wantsSystemAudio)
            startedAt = started
            setStatus(recorder.capturedSystemAudio ? "Recording (mic + system audio)" : "Recording (microphone only)")
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                // Timers fire on the main run loop, so this is already main-actor work.
                MainActor.assumeIsolated { self?.refreshUI() }
            }
        } catch {
            presentError("Could not start recording", error.localizedDescription)
        }
        refreshUI()
    }

    private func stopRecording() async {
        timer?.invalidate()
        timer = nil
        let started = startedAt ?? Date()
        let capturedSystem = recorder.capturedSystemAudio

        isBusy = true
        setStatus("Finishing recording…")

        guard let result = await recorder.stop() else {
            isBusy = false
            setStatus("Ready")
            return
        }
        startedAt = nil
        refreshUI()

        let outcome = await Pipeline.process(
            wavURL: result.url,
            startedAt: started,
            duration: result.duration,
            capturedSystemAudio: capturedSystem,
            progress: { [weak self] message in
                Task { @MainActor in self?.setStatus(message) }
            })

        isBusy = false
        switch outcome {
        case .success(let output):
            lastNoteURL = output.noteURL
            let name = output.noteURL.lastPathComponent
            setStatus("Saved \(name)")
            if output.warnings.isEmpty {
                notify(title: "Meeting notes ready", body: name)
            } else {
                notify(title: "Meeting notes saved with warnings", body: output.warnings.first ?? name)
            }
        case .failure(let error):
            setStatus("Ready")
            presentError("Could not save the note", error.localizedDescription)
        }
        refreshUI()
    }

    @objc private func openLastNote() {
        guard let lastNoteURL else { return }
        NSWorkspace.shared.open(lastNoteURL)
    }

    @objc private func openFolder() {
        let directory = Config.shared.notesDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }

    @objc private func editEnv() {
        let url = Config.shared.envFileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Templates.envExample.write(to: url, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func showDiagnostics() {
        Config.shared.reload()
        let config = Config.shared
        var lines: [String] = []
        lines.append("Notes folder: \(config.notesDirectory.path)")
        lines.append("Config file: \(config.envFileURL.path) \(FileManager.default.fileExists(atPath: config.envFileURL.path) ? "(found)" : "(not created yet)")")
        lines.append("")
        lines.append("Microphone permission: \(AudioRecorder.microphoneAuthorized() ? "granted" : "NOT granted")")
        lines.append("Screen Recording permission: \(AudioRecorder.screenRecordingAuthorized() ? "granted" : "NOT granted")")
        lines.append("")
        lines.append("whisper.cpp binary: \(config.whisperBinary?.path ?? "not found")")
        lines.append("whisper model: \(config.whisperModel?.path ?? "not found")")
        lines.append("Transcription backend: \(Transcriber.resolveBackend().rawValue)")
        let provider = Summarizer.resolveProvider()
        lines.append("Summary provider: \(provider == .none ? "none configured" : "\(provider.rawValue) / \(Summarizer.model(for: provider))")")
        lines.append("")
        lines.append("Keys present: " + ["ANTHROPIC_API_KEY", "OPENAI_API_KEY", "GROQ_API_KEY"]
            .filter { config.string($0) != nil }
            .joined(separator: ", ").ifEmpty("none"))

        let alert = NSAlert()
        alert.messageText = "Meeting Notes diagnostics"
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Copy")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: - Alerts and notifications

    private enum ScreenRecordingChoice { case openSettings, micOnly, cancel }

    private func askAboutScreenRecording() -> ScreenRecordingChoice {
        let alert = NSAlert()
        alert.messageText = "Screen Recording permission is needed for system audio"
        alert.informativeText = "macOS puts other apps' audio — the other people on your call — behind the Screen Recording permission. Nothing on screen is recorded or saved; only audio is captured.\n\nAfter enabling it, quit and reopen Meeting Notes."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Record Microphone Only")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .openSettings
        case .alertSecondButtonReturn: return .micOnly
        default: return .cancel
        }
    }

    private func presentPermissionAlert(title: String, message: String, settingsURL: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn, let url = URL(string: settingsURL) {
            NSWorkspace.shared.open(url)
        }
    }

    private func presentError(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private var notificationsAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    private func requestNotificationPermission() {
        guard notificationsAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notify(title: String, body: String) {
        guard notificationsAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String {
        trimmingCharacters(in: .whitespaces).isEmpty ? fallback : self
    }
}
