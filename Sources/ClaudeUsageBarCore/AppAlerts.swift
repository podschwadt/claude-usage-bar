import AppKit

/// Modal `NSAlert` flows shared by every confirmation and error path outside
/// the render loop. Both entry points activate the app first: an inactive
/// `LSUIElement` accessory app otherwise shows the alert unfocused or behind
/// other windows.
package enum AppAlerts {
    /// Runs a two-button alert (`confirmTitle` first, "Cancel" second) and
    /// reports whether the user picked `confirmTitle`.
    package static func confirm(message: String, informative: String, confirmTitle: String) -> Bool {
        activateApp()
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = informative
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Runs a single-button ("OK") alert and returns once dismissed.
    package static func error(message: String, informative: String) {
        activateApp()
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = informative
        alert.runModal()
    }

    /// Brings the app frontmost so the following alert takes focus.
    private static func activateApp() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
