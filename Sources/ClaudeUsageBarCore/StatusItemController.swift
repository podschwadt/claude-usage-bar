import AppKit

/// Owns the menu bar item, its gauge readout, the click-split dropdown/panel,
/// the poll timer, and the usage history store.
package final class StatusItemController: NSObject {

    /// Unix-time source for the interpreter. Read only to stamp an event
    /// (`.snapshot`, `.tick`) or size a timer delay; every rendered or
    /// queried value derives from the machine's committed `state.now`
    /// instead of a fresh read here.
    let clock: () -> Int

    package init(clock: @escaping () -> Int = { Int(Date().timeIntervalSince1970) }) {
        self.clock = clock
        self.state = UsageState.initial(now: clock(), prefs: PrefsStore.load(from: .standard))
        super.init()
    }

    package let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let fetcher = UsageFetcher()
    let panel = UsagePanelController()
    private var timer: Timer?
    /// The usage domain's entire state, owned by `UsageMachine.transition`;
    /// every render/menu/panel path below reads from this alone.
    var state: UsageState
    private var isRefreshing = false

    /// Non-nil while a `Debug` submenu scenario is selected: a scene built
    /// from a genuinely separate `UsageMachine` instance (see
    /// `DebugScenario.scene(now:prefs:)`), never derived from `state`. The
    /// real machine keeps polling and ticking underneath, untouched; only
    /// `renderState` and the panel/menu header block read this instead.
    /// Every actionable menu item - pref pickers, "Time Remaining", the
    /// history actions - keeps reading `state` directly, so a synthetic
    /// scene can never put a real destructive action in front of the user.
    var debugScene: DebugScene?
    /// Which `DebugScenario` produced `debugScene`, kept alongside it so the
    /// panel footer and menu checkmark can name it (`DebugScenario.title`)
    /// without `DebugScene` itself needing to carry that back-reference.
    var activeDebugScenario: DebugScenario?

    /// What the menu bar and panel header actually render: the active debug
    /// scene's frozen state when one is selected, else the real `state`.
    var renderState: UsageState { debugScene?.state ?? state }

    /// Repaints the countdown cell between polls so it never goes stale at
    /// the 5/15-minute refresh settings; active only while the countdown is
    /// shown and its reset anchor is known (see `setCountdownTimerActive` in
    /// StatusItemController+Render.swift).
    var countdownTimer: Timer?

    /// One-shot usage read armed at the next session/week reset anchor plus
    /// `boundaryPollGrace` (see `.armBoundaryPoll` in `perform`); re-armed
    /// whenever the machine reports a new earliest anchor, invalidated on
    /// terminate.
    private var boundaryTimer: Timer?
    /// Delay past the reset anchor before `.armBoundaryPoll` fires its read,
    /// covering server-side rollover lag.
    private static let boundaryPollGrace: TimeInterval = 2

    /// KVO on the status button's `effectiveAppearance`. The menu bar's
    /// appearance follows the wallpaper as well as Light/Dark Mode, so the
    /// button, not `NSApp`, is what to watch.
    private var appearanceObservation: NSKeyValueObservation?

    /// Owns every touch of the on-disk history store — open, insert, query,
    /// clear — confined to its own serial queue; see `HistoryCoordinator`.
    let history = HistoryCoordinator()

    let defaults = UserDefaults.standard

    package func start() {
        let button = statusItem.button!
        button.imagePosition = .imageOnly
        button.attributedTitle = NSAttributedString()
        // The menu is built fresh per right-click (see `showMenu`) and
        // `statusItem.menu` is never assigned: assigning it hands the
        // button's target/action to NSStatusItem's own click handling, and
        // restoring them afterward is undocumented — the left-click path
        // would break on the first right-click. Routing both buttons
        // through one action and splitting on the triggering event mirrors
        // how native status menus open in the first place.
        button.target = self
        button.action = #selector(statusItemClicked)
        button.sendAction(on: [.leftMouseDown, .rightMouseDown])

        panel.onClose = { [weak self] in self?.statusItem.button?.highlight(false) }

        observeAppearance(of: button)

        render()  // state starts at .loading until the first fetch completes
        startTimer(seconds: state.prefs.refreshInterval)
        refresh()

        // Opened lazily off-main, never as a stored-property initializer:
        // WAL setup fsyncs, and a corrupt or unopenable DB must not crash
        // the app before the status item even exists.
        history.open(
            onOpened: { [weak self] in self?.dispatch(.historyOpened) },
            onFailed: { [weak self] message in self?.dispatch(.historyFailed(message: message)) })

        // `NSApp.terminate` ends the process via exit(); `deinit` never
        // runs, so invalidating timers and closing the history store must
        // happen from an explicit notification handler, not rely on
        // `HistoryStore.deinit`.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { [weak self] _ in
            self?.timer?.invalidate()
            self?.countdownTimer?.invalidate()
            self?.boundaryTimer?.invalidate()
            self?.history.close()
        }
    }

    /// Re-renders whenever `button`'s effective appearance changes. The
    /// gauge image draws in dynamic colors but is a drawing-handler
    /// `NSImage` that AppKit may cache as rendered, so it is regenerated
    /// here. Should the observation ever fail to fire, the cost is one stale
    /// image until the next poll or countdown tick. Called by `start()`;
    /// separate so tests can install it without starting polls.
    package func observeAppearance(of button: NSStatusBarButton) {
        appearanceObservation = button.observe(\.effectiveAppearance) { [weak self] _, _ in
            self?.render()
        }
    }

    /// (Re)starts the poll timer at `seconds`, driven by `start()` at launch
    /// and by `.reschedulePoll` whenever `.setPref(.refreshInterval)` changes
    /// the stored value.
    private func startTimer(seconds: Int) {
        timer?.invalidate()
        let delay = TimeInterval(seconds)
        let t = Timer(timeInterval: delay, repeats: true) { [weak self] _ in self?.refresh() }
        t.tolerance = delay * 0.2  // let the OS coalesce wakeups
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: - Data

    @objc func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        fetcher.fetch { [weak self] snapshot in
            guard let self else { return }
            self.isRefreshing = false
            self.dispatch(.snapshot(snapshot, now: self.clock()))
        }
    }

    // MARK: - Machine

    /// Runs one event through `UsageMachine.transition`. State is committed
    /// BEFORE any effect runs: a re-entrant dispatch triggered by an effect
    /// (e.g. `.pollNow` -> `refresh()` -> a future `.snapshot`) must see the
    /// already-updated state, never the pre-transition one. Then repaint,
    /// perform `step.effects` strictly in array order (contractual — see
    /// `UsageMachine`'s header comment), and only THEN keep an open panel
    /// live on snapshot events: a `.record` effect and this panel query both
    /// land on `HistoryCoordinator`'s serial queue, so queuing the query
    /// before the effect loop would race ahead of the just-arrived sample
    /// and the open panel's chart would lag one poll behind.
    func dispatch(_ event: UsageEvent) {
        let step = UsageMachine.transition(state, event)
        state = step.state
        render()
        for effect in step.effects { perform(effect) }
        if case .snapshot = event, panel.isVisible {
            loadPanelModel { [weak self] model in self?.panel.update(model: model) }
        }
    }

    private func perform(_ effect: UsageEffect) {
        switch effect {
        case let .record(sample):
            history.insert(sample)
        case .pollNow:
            refresh()  // async: perform never synchronously re-dispatches
        case let .armBoundaryPoll(at: anchor):
            // One-shot, replacing any previously armed boundary timer: only
            // the machine's latest earliest anchor is ever pending. A Mac
            // asleep through the fire date falls back to the tick-latch
            // `.pollNow` path on wake.
            boundaryTimer?.invalidate()
            let delay = max(0, TimeInterval(anchor - clock()) + Self.boundaryPollGrace)
            let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in self?.refresh() }
            RunLoop.main.add(t, forMode: .common)
            boundaryTimer = t
        case let .persistPref(pref):
            PrefsStore.persist(pref, to: defaults)
        case let .reschedulePoll(seconds):
            startTimer(seconds: seconds)
        }
    }

    // MARK: - Click split

    /// Both mouse buttons share one action; the triggering event decides
    /// whether it opens the history panel (left) or the dropdown menu
    /// (right, or control-left — the platform convention for a secondary
    /// click on a one-button trackpad).
    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        let isSecondaryClick =
            event?.type == .rightMouseDown
            || (event?.type == .leftMouseDown && event?.modifierFlags.contains(.control) == true)
        if isSecondaryClick {
            showMenu()
        } else {
            togglePanel()
        }
    }

    private func showMenu() {
        // Option+right-click only: the Debug submenu is deliberately hidden
        // from a plain right-click so it never clutters ordinary use.
        let includeDebug = NSEvent.modifierFlags.contains(.option)
        let menu = makeMenu(includeDebug: includeDebug)
        let button = statusItem.button!
        button.highlight(true)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)  // blocks until dismissal
        button.highlight(false)
    }
}
