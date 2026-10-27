import AppKit

// Headless mode for verifying the pipeline without opening the menu bar app.
if CommandLine.arguments.contains("--selftest") {
    exit(SelfTest.run())
}

// Checks the configured LLM against a sample transcript.
if CommandLine.arguments.contains("--test-summary") {
    let semaphore = DispatchSemaphore(value: 0)
    var code: Int32 = 1
    Task { code = await SummaryCheck.run(); semaphore.signal() }
    semaphore.wait()
    exit(code)
}

// Top-level code runs before the main actor is established, so hop onto it
// explicitly to build the delegate.
MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    // NSApplication does not retain its delegate.
    objc_setAssociatedObject(application, "MeetingNotesDelegate", delegate, .OBJC_ASSOCIATION_RETAIN)
    application.delegate = delegate
    // Menu bar only: no Dock icon, no main window.
    application.setActivationPolicy(.accessory)
    application.run()
}
