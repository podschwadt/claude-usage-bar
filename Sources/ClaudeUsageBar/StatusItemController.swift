import AppKit
import ServiceManagement

/// Owns the menu bar item, its two-line readout, the dropdown and the poll timer.
final class StatusItemController: NSObject {

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let fetcher = UsageFetcher()
    private var timer: Timer?
    private var snapshot: UsageSnapshot?
    private var isRefreshing = false

    private let defaults = UserDefaults.standard
    private static let modeKey = "barMode"
    private static let intervalKey = "refreshInterval"

    /// Polling is free (the /usage command never reaches the model), so a
    /// one-minute default costs nothing but keeps the readout live.
    private static let intervalChoices: [(String, TimeInterval)] = [
        ("30 seconds", 30), ("1 minute", 60), ("5 minutes", 300), ("15 minutes", 900),
    ]

    private var mode: Display.BarMode {
        get { Display.BarMode(rawValue: defaults.string(forKey: Self.modeKey) ?? "") ?? .auto }
        set { defaults.set(newValue.rawValue, forKey: Self.modeKey); render(); rebuildMenu() }
    }

    private var interval: TimeInterval {
        get { let v = defaults.double(forKey: Self.intervalKey); return v > 0 ? v : 60 }
        set { defaults.set(newValue, forKey: Self.intervalKey); startTimer(); rebuildMenu() }
    }

    func start() {
        statusItem.button?.imagePosition = .noImage
        renderPlaceholder("CL", "···")
        rebuildMenu()
        startTimer()
        refresh()
    }

    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.refresh() }
        t.tolerance = interval * 0.2   // let the OS coalesce wakeups
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: - Data

    @objc private func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        fetcher.fetch { [weak self] snapshot in
            guard let self else { return }
            self.isRefreshing = false
            self.snapshot = snapshot
            self.render()
            self.rebuildMenu()
        }
    }

    // MARK: - Menu bar readout

    /// Two stacked lines, in the style of the compact system monitors: the
    /// limit that binds first on top, Fable headroom underneath.
    private func render() {
        guard let snap = snapshot else { return renderPlaceholder("CL", "···") }
        guard snap.isTrustworthy else {
            // Never show a number we cannot stand behind.
            renderPlaceholder("CL", "?", color: .systemOrange)
            statusItem.button?.toolTip = snap.error
                ?? "Unrecognised /usage output — Claude Code may have changed its format."
            return
        }

        let primary: Metric? = {
            switch mode {
            case .auto: return snap.binding
            case .session: return snap.metric(MetricKey.session)
            case .week: return snap.metric(MetricKey.week)
            case .fable: return snap.metric(MetricKey.fable)
            }
        }()
        let secondary: Metric? = mode == .fable
            ? snap.binding
            : snap.metric(MetricKey.fable)

        let top = primary.map { "\(Display.tag(for: $0.key)) \(Display.pct($0.remainingPct))" } ?? "CL"
        let bottom = secondary.map { "\(Display.tag(for: $0.key)) \(Display.pct($0.remainingPct))" } ?? "—"

        renderPlaceholder(
            top, bottom,
            color: Display.color(remaining: primary?.remainingPct ?? 100),
            secondaryColor: Display.color(remaining: secondary?.remainingPct ?? 100)
        )
        statusItem.button?.toolTip = [primary, secondary]
            .compactMap { $0.map(Display.menuRow(for:)) }
            .joined(separator: "\n")
    }

    private func renderPlaceholder(_ top: String, _ bottom: String,
                                   color: NSColor = .labelColor,
                                   secondaryColor: NSColor? = nil) {
        let style = NSMutableParagraphStyle()
        style.alignment = .right
        style.maximumLineHeight = 10
        style.minimumLineHeight = 10

        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        func line(_ s: String, _ c: NSColor) -> NSAttributedString {
            NSAttributedString(string: s, attributes: [
                .font: font, .foregroundColor: c, .paragraphStyle: style,
            ])
        }
        let title = NSMutableAttributedString()
        title.append(line(top, color))
        title.append(line("\n" + bottom, secondaryColor ?? color))
        statusItem.button?.attributedTitle = title
    }

    // MARK: - Dropdown

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        if let snap = snapshot {
            if !snap.ok {
                addRow(menu, "Could not read usage", enabled: false)
                for chunk in (snap.error ?? "unknown error").split(separator: "\n") {
                    addRow(menu, "   \(chunk)", enabled: false)
                }
            } else if !(snap.schemaOk ?? false) {
                addRow(menu, "Unrecognised /usage format", enabled: false)
                addRow(menu, "   missing: \((snap.missingKeys ?? []).joined(separator: ", "))",
                       enabled: false)
                addRow(menu, "   the parser needs updating", enabled: false)
            } else {
                if let plan = snap.plan {
                    addRow(menu, "Using \(plan)", enabled: false)
                    menu.addItem(.separator())
                }
                // Stable order regardless of dictionary iteration order.
                for key in [MetricKey.session, MetricKey.week, MetricKey.fable] {
                    guard let m = snap.metric(key) else { continue }
                    let item = addRow(menu, Display.menuRow(for: m), enabled: false)
                    item.attributedTitle = NSAttributedString(
                        string: Display.menuRow(for: m),
                        attributes: [
                            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular),
                            .foregroundColor: Display.color(remaining: m.remainingPct)
                                == .labelColor ? NSColor.labelColor
                                : Display.color(remaining: m.remainingPct),
                        ])
                }
                if let a = snap.activity, let requests = a.requests {
                    menu.addItem(.separator())
                    var line = "Last \(a.windowDays ?? 7)d: \(requests) requests"
                    if let s = a.sessions { line += " · \(s) sessions" }
                    addRow(menu, line, enabled: false)
                    if a.localOnly == true {
                        addRow(menu, "   (this machine only)", enabled: false)
                    }
                }
            }
            if let queried = snap.queriedAt, let date = ISO8601DateFormatter().date(from: queried) {
                let f = DateFormatter()
                f.dateFormat = "HH:mm:ss"
                addRow(menu, "Updated \(f.string(from: date))", enabled: false)
            }
        } else {
            addRow(menu, "Loading…", enabled: false)
        }

        menu.addItem(.separator())

        let displayItem = NSMenuItem(title: "Menu bar shows", action: nil, keyEquivalent: "")
        let displayMenu = NSMenu()
        for m in Display.BarMode.allCases {
            let item = NSMenuItem(title: m.title, action: #selector(pickMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = m.rawValue
            item.state = (m == mode) ? .on : .off
            displayMenu.addItem(item)
        }
        displayItem.submenu = displayMenu
        menu.addItem(displayItem)

        let intervalItem = NSMenuItem(title: "Refresh every", action: nil, keyEquivalent: "")
        let intervalMenu = NSMenu()
        for (title, seconds) in Self.intervalChoices {
            let item = NSMenuItem(title: title, action: #selector(pickInterval(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = seconds
            item.state = (abs(seconds - interval) < 0.5) ? .on : .off
            intervalMenu.addItem(item)
        }
        intervalItem.submenu = intervalMenu
        menu.addItem(intervalItem)

        menu.addItem(.separator())
        addAction(menu, "Refresh Now", #selector(refresh), key: "r")
        addAction(menu, "Copy /usage Output", #selector(copyRaw), key: "c")
        let login = addAction(menu, "Open at Login", #selector(toggleLogin), key: "")
        login.state = loginEnabled ? .on : .off
        menu.addItem(.separator())
        addAction(menu, "Quit Claude Usage", #selector(quit), key: "q")

        statusItem.menu = menu
    }

    @discardableResult
    private func addRow(_ menu: NSMenu, _ title: String, enabled: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = enabled
        menu.addItem(item)
        return item
    }

    @discardableResult
    private func addAction(_ menu: NSMenu, _ title: String,
                           _ selector: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        item.isEnabled = true
        menu.addItem(item)
        return item
    }

    // MARK: - Actions

    @objc private func pickMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let m = Display.BarMode(rawValue: raw) else { return }
        mode = m
    }

    @objc private func pickInterval(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? TimeInterval else { return }
        interval = seconds
    }

    @objc private func copyRaw() {
        guard let raw = snapshot?.raw ?? snapshot?.error else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(raw, forType: .string)
    }

    private var loginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @objc private func toggleLogin() {
        do {
            if loginEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            // Unsigned / not-in-Applications builds are commonly rejected here;
            // surface it instead of silently doing nothing.
            let alert = NSAlert()
            alert.messageText = "Could not change the login item"
            alert.informativeText = "\(error.localizedDescription)\n\n"
                + "This usually means the app needs to live in /Applications."
            alert.runModal()
        }
        rebuildMenu()
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
