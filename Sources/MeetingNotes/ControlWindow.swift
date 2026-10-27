import AppKit

/// A real window with the same controls as the menu, for when the menu bar icon
/// is unreachable — a crowded or notched menu bar hides status items silently,
/// and an app whose only control is hidden is an app you cannot stop.
///
/// Reached by re-opening the app from Finder or the Dock, by the global hotkey,
/// or from the menu itself.
@MainActor
final class ControlWindowController: NSObject, NSWindowDelegate {

    struct Actions {
        let toggleRecording: () -> Void
        let setCaptureSystemAudio: (Bool) -> Void
        let openNotesFolder: () -> Void
        let openLastNote: () -> Void
        let showDiagnostics: () -> Void
    }

    private let actions: Actions
    private var window: NSWindow!

    private let statusLabel = NSTextField(labelWithString: "Ready")
    private let detailLabel = NSTextField(labelWithString: "Not recording")
    private let recordButton = NSButton(title: "Start Recording", target: nil, action: nil)
    private let systemAudioCheckbox = NSButton(checkboxWithTitle: "Capture system audio", target: nil, action: nil)
    private let lastNoteButton = NSButton(title: "Open Last Note", target: nil, action: nil)

    init(actions: Actions) {
        self.actions = actions
        super.init()
        buildWindow()
    }

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 260),
                          styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "Meeting Notes"
        window.delegate = self
        // The controller outlives the window being closed; closing just hides it.
        window.isReleasedWhenClosed = false
        window.center()

        statusLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor

        recordButton.target = self
        recordButton.action = #selector(didTapRecord)
        recordButton.bezelStyle = .rounded
        recordButton.controlSize = .large
        recordButton.keyEquivalent = "\r"

        systemAudioCheckbox.target = self
        systemAudioCheckbox.action = #selector(didToggleSystemAudio)
        systemAudioCheckbox.state = .on

        let folderButton = NSButton(title: "Open Notes Folder", target: self, action: #selector(didTapFolder))
        lastNoteButton.target = self
        lastNoteButton.action = #selector(didTapLastNote)
        lastNoteButton.isEnabled = false
        let diagnosticsButton = NSButton(title: "Diagnostics…", target: self, action: #selector(didTapDiagnostics))
        for button in [folderButton, lastNoteButton, diagnosticsButton] {
            button.bezelStyle = .rounded
        }

        let buttonRow = NSStackView(views: [folderButton, lastNoteButton])
        buttonRow.distribution = .fillEqually
        buttonRow.spacing = 8

        let hint = NSTextField(labelWithString: "\(GlobalHotKey.displayName) starts and stops recording from anywhere.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.lineBreakMode = .byWordWrapping
        hint.maximumNumberOfLines = 2

        let stack = NSStackView(views: [
            statusLabel, detailLabel, recordButton, systemAudioCheckbox,
            NSBox.separator(), buttonRow, diagnosticsButton, hint,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor),
            recordButton.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            diagnosticsButton.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            hint.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
        ])
        window.contentView = content
    }

    func show() {
        // An accessory app has to ask for focus explicitly.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    var isVisible: Bool { window.isVisible }

    /// Mirrors whatever the menu is showing.
    func update(isRecording: Bool, isBusy: Bool, status: String, elapsed: TimeInterval,
                captureSystemAudio: Bool, hasLastNote: Bool) {
        statusLabel.stringValue = isRecording ? "Recording" : (isBusy ? "Working…" : "Ready")
        detailLabel.stringValue = isRecording
            ? "\(NoteWriter.humanDuration(elapsed)) — \(status)"
            : status
        recordButton.title = isRecording ? "Stop Recording" : "Start Recording"
        recordButton.isEnabled = !isBusy
        recordButton.contentTintColor = isRecording ? .systemRed : nil
        systemAudioCheckbox.state = captureSystemAudio ? .on : .off
        systemAudioCheckbox.isEnabled = !isRecording && !isBusy
        lastNoteButton.isEnabled = hasLastNote
    }

    // MARK: - Actions

    @objc private func didTapRecord() { actions.toggleRecording() }
    @objc private func didToggleSystemAudio() { actions.setCaptureSystemAudio(systemAudioCheckbox.state == .on) }
    @objc private func didTapFolder() { actions.openNotesFolder() }
    @objc private func didTapLastNote() { actions.openLastNote() }
    @objc private func didTapDiagnostics() { actions.showDiagnostics() }

    /// Closing the window must not stop a recording or quit the app.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        window.orderOut(nil)
        return false
    }
}

private extension NSBox {
    static func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }
}
