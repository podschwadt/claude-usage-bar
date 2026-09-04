import AppKit

/// Menu bar only: no dock icon, no windows. LSUIElement is set in Info.plist,
/// and .accessory here covers running the binary directly during development.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = StatusItemController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        controller.start()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
