import ServiceManagement

/// Wraps `SMAppService.mainApp`'s login-item status read and its
/// register/unregister calls behind two verbs.
enum LoginItem {
    /// Whether the app is currently registered to launch at login.
    static var enabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Toggles login-item registration, throwing whatever `SMAppService`
    /// throws so the caller can surface it (see `toggleLogin`'s `AppAlerts`
    /// use).
    static func toggle() throws {
        if enabled {
            try SMAppService.mainApp.unregister()
        } else {
            try SMAppService.mainApp.register()
        }
    }
}
