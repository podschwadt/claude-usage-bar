import AppKit

/// Opens the history panel and loads its data from the history store.
extension StatusItemController {

    /// Fable's chart/legend tint — fixed rather than user-configurable, so
    /// it can never collide with whatever `BarColor` the user picks for the
    /// primary series.
    private static let fableColor = NSColor.systemTeal

    func togglePanel() {
        let button = statusItem.button!
        // A fresh tick, committed before any panel model is built, so the
        // menu bar and the panel render the very same instant (see
        // `loadPanelModel`'s doc comment below) rather than two independent
        // clock reads that could disagree by however long has passed since
        // the last tick/poll. This can itself fire a due `.pollNow` up to
        // `countdownRepaintInterval` (StatusItemController+Render.swift) seconds
        // early — the machine reacting to
        // a fresher `now`, not a bug.
        dispatch(.tick(now: clock()))
        // Decided synchronously so two fast clicks cannot race: the panel
        // opens immediately with whatever is on hand (placeholders show
        // "collecting history…" until real content arrives), then
        // `loadPanelModel` fills it in once the store answers. Everything
        // below is derived from `panel.isVisible` AFTER the toggle, never
        // from whether it was visible before: `panel.toggle` can silently
        // no-op (the reopen debounce swallowing a click that lands just
        // after a click-outside close), and reading the pre-toggle state
        // would then wrongly highlight the button and query history for a
        // panel that never opened.
        let placeholder = PanelModel.build(
            state: renderState, sessionSamples: [], weekSamples: [],
            baseColor: baseBarColor, fableColor: Self.fableColor, debugLabel: debugFooterLabel)
        panel.toggle(model: placeholder, relativeTo: button)
        button.highlight(panel.isVisible)
        guard panel.isVisible else { return }
        loadPanelModel { [weak self] model in self?.panel.update(model: model) }
    }

    /// Queries the history store for the current session and week windows
    /// and hands `completion` a fully-populated `PanelModel`, both built
    /// from one `state` snapshot captured here on main: the SQL range
    /// (`sessionWindow`/`weekWindow`, `state`'s own computed properties) and
    /// the rendered model (`PanelModel.build(state:...)`, reading the same
    /// properties) always agree because they are the same committed value,
    /// never two independent derivations.
    ///
    /// While a `Debug` scenario is selected, this instead builds synchronously
    /// from the scenario's own frozen state and samples, never reaching
    /// `HistoryCoordinator` - the debug path must never touch the on-disk
    /// history store.
    func loadPanelModel(completion: @escaping (PanelModel) -> Void) {
        if let debugScene {
            completion(
                PanelModel.build(
                    state: debugScene.state, sessionSamples: debugScene.sessionSamples,
                    weekSamples: debugScene.weekSamples,
                    baseColor: baseBarColor, fableColor: Self.fableColor, debugLabel: debugFooterLabel))
            return
        }

        let snapshot = state
        let baseColor = baseBarColor
        let sessionWindow = snapshot.sessionWindow
        let weekWindow = snapshot.weekWindow
        let sessionAnchor = snapshot.session?.resetAnchor

        history.chartSamples(sessionWindow: sessionWindow, sessionAnchor: sessionAnchor, weekWindow: weekWindow) {
            sessionSamples, weekSamples in
            completion(
                PanelModel.build(
                    state: snapshot, sessionSamples: sessionSamples, weekSamples: weekSamples,
                    baseColor: baseColor, fableColor: Self.fableColor))
        }
    }

    /// "DEBUG - <scenario title>" while a scenario is selected, overriding
    /// the panel footer's normal "Updated ..."/"No data yet" line; nil
    /// otherwise, leaving `PanelModel.build`'s default footer untouched.
    private var debugFooterLabel: String? {
        guard let scenario = activeDebugScenario else { return nil }
        return "DEBUG - \(scenario.title)"
    }
}
