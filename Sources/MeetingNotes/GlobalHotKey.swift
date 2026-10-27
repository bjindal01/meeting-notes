import AppKit
import Carbon.HIToolbox

/// A system-wide hotkey registered through Carbon's `RegisterEventHotKey`.
///
/// Deliberately not `NSEvent.addGlobalMonitorForEvents`, which would require the
/// Accessibility permission — this needs no permission at all, which matters for
/// an app whose whole point is not asking for more access than it needs.
final class GlobalHotKey {
    /// Carbon hands the callback no context pointer we can trust across
    /// launches, so the live instance is reached through this.
    static var shared: GlobalHotKey?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let action: () -> Void

    /// Defaults to ⌃⌥⌘R — unlikely to collide with anything, and reachable
    /// one-handed while a call is in progress.
    init?(keyCode: UInt32 = UInt32(kVK_ANSI_R),
          modifiers: UInt32 = UInt32(controlKey | optionKey | cmdKey),
          action: @escaping () -> Void) {
        self.action = action

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, _ -> OSStatus in
                // Carbon dispatches this on the main thread.
                MainActor.assumeIsolated { GlobalHotKey.shared?.fire() }
                return noErr
            },
            1, &eventType, nil, &eventHandler)
        guard installStatus == noErr else { return nil }

        let hotKeyID = EventHotKeyID(signature: OSType(0x4D_4E_54_53), id: 1)  // 'MNTS'
        let registerStatus = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                                 GetApplicationEventTarget(), 0, &hotKeyRef)
        guard registerStatus == noErr else {
            if let eventHandler { RemoveEventHandler(eventHandler) }
            return nil
        }
    }

    fileprivate func fire() { action() }

    /// Human-readable form for the UI, so the shortcut is discoverable.
    static let displayName = "⌃⌥⌘R"

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}
