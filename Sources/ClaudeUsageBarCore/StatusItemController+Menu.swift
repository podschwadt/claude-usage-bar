import AppKit

/// Builds the right-click dropdown menu and drives its preference pickers
/// and history/login actions.
extension StatusItemController {

    /// Polling is free (the /usage command never reaches the model), so a
    /// one-minute default costs nothing but keeps the readout live.
    private static let intervalChoices: [(String, Int)] = [
        ("30 seconds", 30), ("1 minute", 60), ("5 minutes", 300), ("15 minutes", 900),
    ]

    func makeMenu(includeDebug: Bool) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // The trust/metric/activity/"Updated" header block reads
        // `renderState`, so a selected Debug scenario shadows it exactly
        // like the menu bar and panel.
        switch renderState.trust {
        case .loading:
            addRow(menu, "Loading…", enabled: false)
        case let .fetchFailed(message):
            addRow(menu, "Could not read usage", enabled: false)
            for chunk in message.split(separator: "\n") {
                addRow(menu, "   \(chunk)", enabled: false)
            }
        case let .schemaMismatch(missing):
            addRow(menu, "Unrecognised /usage format", enabled: false)
            addRow(menu, "   missing: \(missing.joined(separator: ", "))", enabled: false)
            addRow(menu, "   the parser needs updating", enabled: false)
        case .trusted:
            // Stable order regardless of dictionary iteration order.
            for metricState in renderState.metricStates {
                let row = Display.menuRow(for: metricState.metric, remainingSeconds: metricState.remainingSeconds)
                let item = addRow(menu, row, enabled: false)
                item.attributedTitle = NSAttributedString(
                    string: row,
                    attributes: [
                        .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular),
                        .foregroundColor: Display.color(band: renderState.presentation(for: metricState).band),
                    ])
            }
            if let a = renderState.activity, let requests = a.requests {
                menu.addItem(.separator())
                var line = "Last \(a.windowDays ?? 7)d: \(requests) requests"
                if let s = a.sessions { line += " · \(s) sessions" }
                addRow(menu, line, enabled: false)
                if a.localOnly == true {
                    addRow(menu, "   (this machine only)", enabled: false)
                }
            }
        }
        if let queriedAtUnix = renderState.queriedAtUnix {
            let date = Date(timeIntervalSince1970: TimeInterval(queriedAtUnix))
            addRow(menu, "Updated \(Display.clockTime(date))", enabled: false)
        }

        menu.addItem(.separator())

        menu.addItem(
            pickerSubmenu(
                title: "Layout",
                items: Display.BarLayout.allCases.map {
                    (title: $0.title, pref: .layout($0), isOn: $0 == state.prefs.layout)
                }))

        // A barColorHex default silently overrides whichever entry is
        // checked here, as an escape hatch for a tint outside the palette.
        menu.addItem(
            pickerSubmenu(
                title: "Color",
                items: BarColor.allCases.map {
                    (title: $0.title, pref: .barColor($0), isOn: $0 == state.prefs.barColor)
                }))

        menu.addItem(
            pickerSubmenu(
                title: "Numbers",
                items: Display.NumberMode.allCases.map {
                    (title: $0.title, pref: .numbers($0), isOn: $0 == state.prefs.numbers)
                }))

        menu.addItem(
            pickerSubmenu(
                title: "Refresh every",
                items: Self.intervalChoices.map {
                    (title: $0.0, pref: .refreshInterval($0.1), isOn: $0.1 == state.prefs.refreshInterval)
                }))

        let countdownItem = NSMenuItem(title: "Time Remaining", action: #selector(toggleCountdown), keyEquivalent: "")
        countdownItem.target = self
        countdownItem.state = state.prefs.showCountdown ? .on : .off
        menu.addItem(countdownItem)

        menu.addItem(.separator())
        addAction(menu, "Refresh Now", #selector(refresh), key: "r")
        addAction(menu, "Copy /usage Output", #selector(copyRaw), key: "c")

        switch state.history {
        case .available:
            addAction(menu, "Clear History…", #selector(clearHistory), key: "")
        case let .unavailable(message):
            addRow(menu, "History unavailable: \(message)", enabled: false)
            addAction(menu, "Reset History…", #selector(resetHistory), key: "")
        case .opening:
            addRow(menu, "History loading…", enabled: false)
        }

        let login = addAction(menu, "Open at Login", #selector(toggleLogin), key: "")
        login.state = LoginItem.enabled ? .on : .off

        if includeDebug {
            menu.addItem(.separator())
            menu.addItem(debugSubmenu())
        }

        menu.addItem(.separator())
        addAction(menu, "Quit Claude Usage", #selector(quit), key: "q")

        return menu
    }

    /// "Debug" submenu, revealed only by Option+right-click (see
    /// `showMenu`): an "Off" entry plus one per `DebugScenario.allCases`,
    /// checkmark on the active one. Built with the same `pickerSubmenu`
    /// shape as the Layout/Color/Numbers/Refresh-every pickers above, but
    /// dispatches `pickDebugScenario` instead of `pickPref` since a scenario
    /// is transient interpreter state, never a persisted `UsagePref`.
    private func debugSubmenu() -> NSMenuItem {
        let parent = NSMenuItem(title: "Debug", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        let off = NSMenuItem(title: "Off", action: #selector(pickDebugScenario(_:)), keyEquivalent: "")
        off.target = self
        off.representedObject = nil
        off.state = activeDebugScenario == nil ? .on : .off
        submenu.addItem(off)

        for scenario in DebugScenario.allCases {
            let entry = NSMenuItem(title: scenario.title, action: #selector(pickDebugScenario(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = DebugScenarioBox(scenario)
            entry.state = activeDebugScenario == scenario ? .on : .off
            submenu.addItem(entry)
        }

        parent.submenu = submenu
        return parent
    }

    @discardableResult
    private func addRow(_ menu: NSMenu, _ title: String, enabled: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = enabled
        menu.addItem(item)
        return item
    }

    @discardableResult
    private func addAction(
        _ menu: NSMenu, _ title: String,
        _ selector: Selector, key: String
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        item.isEnabled = true
        menu.addItem(item)
        return item
    }

    /// Builds one pref submenu: a titled parent item holding one checkable
    /// entry per `items`, each dispatching `pickPref` with its own
    /// `UsagePref` boxed in `representedObject` (see `PrefBox`). Shared by
    /// the Layout/Color/Numbers/Refresh-every submenus, which differ only in
    /// title and choice list.
    private func pickerSubmenu(title: String, items: [(title: String, pref: UsagePref, isOn: Bool)]) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for item in items {
            let entry = NSMenuItem(title: item.title, action: #selector(pickPref(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = PrefBox(item.pref)
            entry.state = item.isOn ? .on : .off
            submenu.addItem(entry)
        }
        parent.submenu = submenu
        return parent
    }

    // MARK: - Actions

    /// Dispatches a preference change to the REAL machine unchanged, then -
    /// while a `Debug` scenario is active - rebuilds the frozen scene from
    /// the new prefs and repaints both shadowed surfaces via
    /// `applyDebugScenario`. Without this, a scenario picked in one Numbers
    /// mode would stay frozen showing that mode even after the picker is
    /// flipped, since `dispatch` only re-queries an open panel on
    /// `.snapshot` events and `debugScene` is otherwise never rebuilt.
    @objc private func pickPref(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? PrefBox else { return }
        let now = clock()
        dispatch(.setPref(box.pref, now: now))
        if activeDebugScenario != nil {
            applyDebugScenario(activeDebugScenario, now: now)
        }
    }

    @objc private func toggleCountdown() {
        let now = clock()
        dispatch(.setPref(.showCountdown(!state.prefs.showCountdown), now: now))
        if activeDebugScenario != nil {
            applyDebugScenario(activeDebugScenario, now: now)
        }
    }

    /// Selects (or, for "Off", clears) a debug scenario.
    @objc private func pickDebugScenario(_ sender: NSMenuItem) {
        let scenario = (sender.representedObject as? DebugScenarioBox)?.scenario
        applyDebugScenario(scenario, now: clock())
    }

    /// Builds `scenario`'s frozen scene against `state.prefs` (the real,
    /// current preferences) and repaints both shadowed surfaces: `dispatch`
    /// only re-queries an open panel on `.snapshot` events, so nothing else
    /// would refresh the panel here. Shared by `pickDebugScenario` (a new
    /// scenario is picked) and `pickPref`/`toggleCountdown` (a scenario is
    /// already active and the prefs it is built from just changed) so both
    /// paths rebuild the scene identically rather than duplicating this
    /// logic.
    private func applyDebugScenario(_ scenario: DebugScenario?, now: Int) {
        activeDebugScenario = scenario
        debugScene = scenario?.scene(now: now, prefs: state.prefs)
        render()
        if panel.isVisible {
            loadPanelModel { [weak self] model in self?.panel.update(model: model) }
        }
    }

    @objc private func copyRaw() {
        // `state.raw` already holds `snapshot.raw ?? snapshot.error` for an
        // untrustworthy snapshot (see `UsageMachine`'s untrusted-snapshot
        // transition) and `snapshot.raw` for a trusted one.
        guard let raw = state.raw else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(raw, forType: .string)
    }

    // MARK: - History actions

    @objc private func clearHistory() {
        guard
            AppAlerts.confirm(
                message: "Clear usage history?",
                informative: "This permanently deletes all recorded usage samples.",
                confirmTitle: "Clear")
        else { return }
        history.clear()
    }

    /// Recovery path for an unopenable database (`state.history ==
    /// .unavailable`): re-opens through `HistoryCoordinator.resetAndReopen`,
    /// so a corrupt or otherwise unopenable store is not a dead end —
    /// "Reset History…" stays reachable instead of only "Clear History…",
    /// which needs an already-open store to run.
    @objc private func resetHistory() {
        guard
            AppAlerts.confirm(
                message: "Reset usage history?",
                informative: "The history database could not be opened and will be deleted; "
                    + "a fresh, empty one is created in its place.",
                confirmTitle: "Reset")
        else { return }

        history.resetAndReopen(
            onOpened: { [weak self] in self?.dispatch(.historyOpened) },
            onFailed: { [weak self] message in self?.dispatch(.historyFailed(message: message)) })
    }

    @objc private func toggleLogin() {
        do {
            try LoginItem.toggle()
        } catch {
            // Unsigned / not-in-Applications builds are commonly rejected here;
            // surface it instead of silently doing nothing.
            AppAlerts.error(
                message: "Could not change the login item",
                informative: "\(error.localizedDescription)\n\n"
                    + "SMAppService requires a signed app installed in /Applications.")
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

/// Boxes a `DebugScenario` for `NSMenuItem.representedObject`, so
/// `pickDebugScenario` can recover the exact case each generated "Debug"
/// submenu entry carries; the "Off" entry carries a nil `representedObject`
/// instead of a box, mirroring `PrefBox`.
private final class DebugScenarioBox: NSObject {
    let scenario: DebugScenario

    init(_ scenario: DebugScenario) {
        self.scenario = scenario
    }
}
