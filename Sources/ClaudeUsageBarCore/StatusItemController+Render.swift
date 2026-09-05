import AppKit

/// Menu bar rendering: the gauge image, tooltip, and countdown repaint timer.
extension StatusItemController {

    /// Text shown while the first fetch is still in flight.
    private static let loadingText = "CL ..."
    /// Text shown when the snapshot cannot be trusted (parse failure, unrecognised format).
    private static let errorText = "CL ?"
    /// Tooltip fallback when untrustworthy state carries no message of its
    /// own (schema mismatch, or trusted but every metric is missing).
    private static let unrecognisedFormatTooltip =
        "Unrecognised /usage output — the parser needs updating."

    private static let colorHexOverrideKey = "barColorHex"

    /// The palette pick, unless the user has written a custom hex override
    /// (defaults write com.claudeusagebar.app barColorHex RRGGBB). The one
    /// preference read outside `PrefsStore`: a hex override takes
    /// effect without restart, which needs a fresh read here rather than a
    /// value carried on `state`.
    var baseBarColor: NSColor {
        if let hex = defaults.string(forKey: Self.colorHexOverrideKey),
            let custom = NSColor(hexString: hex)
        {
            return custom
        }
        return renderState.prefs.barColor.nsColor
    }

    /// Three gauges — Session, Week, Fable — each a number plus a small bar
    /// fill, arranged as columns or stacked rows per `state.prefs.layout`.
    /// Reads `renderState` throughout, so a selected `Debug` scenario shadows
    /// the menu bar exactly as it shadows the panel. The countdown timer
    /// decision is made exactly once at the end, from the REAL `state` via
    /// `shouldRunCountdownTimer` (never from `renderState`), so selecting a
    /// debug scenario can never invalidate the timer that drives the real
    /// machine's `.tick` events.
    func render() {
        defer { setCountdownTimerActive(shouldRunCountdownTimer) }

        switch renderState.trust {
        case .loading:
            statusItem.button?.image = StatusBarRenderer.placeholderImage(text: Self.loadingText, color: .labelColor)
            statusItem.button?.toolTip = debugTooltip("Loading usage...")
            statusItem.button?.setAccessibilityLabel("Claude usage: loading")
            return
        case let .fetchFailed(message):
            renderUntrustworthy(tooltip: message)
            return
        case .schemaMismatch:
            renderUntrustworthy(tooltip: Self.unrecognisedFormatTooltip)
            return
        case .trusted:
            break
        }

        let metricStates = renderState.metricStates
        guard !metricStates.isEmpty else {
            // Never show a number we cannot stand behind.
            renderUntrustworthy(tooltip: Self.unrecognisedFormatTooltip)
            return
        }

        let g = StatusBarRenderer.gauges(
            presentations: renderState.presentations, layout: renderState.prefs.layout, baseColor: baseBarColor)
        // Two different readouts stacked (session H:MM over week X.Yd), not
        // two halves of the same countdown: a metric absent from the snapshot
        // drops its line, one present with an unknown anchor dashes it out,
        // and a past anchor pins at "0:00"/"0.0d" (Display.countdownLines).
        let lines =
            renderState.prefs.showCountdown
            ? Display.countdownLines(session: renderState.session, week: renderState.week)
            : nil
        statusItem.button?.image = StatusBarRenderer.image(
            gauges: g, layout: renderState.prefs.layout, countdownLines: lines)
        statusItem.button?.toolTip = debugTooltip(
            metricStates
                .map { Display.menuRow(for: $0.metric, remainingSeconds: $0.remainingSeconds) }
                .joined(separator: "\n"))
        statusItem.button?.setAccessibilityLabel("Claude usage: " + g.map { $0.text }.joined(separator: ", "))
    }

    /// The shared "cannot stand behind this number" placeholder: orange
    /// `CL ?`, no accessibility number, no countdown timer.
    private func renderUntrustworthy(tooltip: String) {
        statusItem.button?.image = StatusBarRenderer.placeholderImage(text: Self.errorText, color: .systemOrange)
        statusItem.button?.toolTip = debugTooltip(tooltip)
        statusItem.button?.setAccessibilityLabel("Claude usage: unavailable")
    }

    /// Prefix so an overridden menu bar is unmistakable while a `Debug`
    /// scenario is selected; the real tooltip text otherwise.
    private func debugTooltip(_ text: String) -> String {
        debugScene == nil ? text : "DEBUG - \(text)"
    }

    /// Whether any countdown line moves as time passes. A dashed placeholder
    /// line (unknown anchor) repaints to identical pixels, so it alone never
    /// arms the repaint timer; a frozen, past anchor still does, since its
    /// tick is what re-polls for the metric's own rollover.
    private var hasLiveCountdown: Bool {
        state.prefs.showCountdown
            && (state.session?.remainingSeconds != nil || state.week?.remainingSeconds != nil)
    }

    /// Whether the countdown repaint timer should run, computed from the
    /// REAL `state` only - never from `renderState` - so a selected `Debug`
    /// scenario can never invalidate the timer that dispatches `.tick` into
    /// the real `UsageMachine`. Mirrors `render()`'s branch structure against
    /// `state.trust` directly: `.loading`/untrustworthy/no-metrics never run
    /// it, `.trusted` with metrics present defers to `hasLiveCountdown`.
    /// `untrustworthySnapshot` can preserve prior metric states even while
    /// untrustworthy, which is why the trust guard must stay rather than
    /// checking `state.metricStates.isEmpty` alone.
    private var shouldRunCountdownTimer: Bool {
        guard case .trusted = state.trust, !state.metricStates.isEmpty else { return false }
        return hasLiveCountdown
    }

    private static let countdownRepaintInterval: TimeInterval = 60

    /// The repaint timer only redraws the existing snapshot against the
    /// current time (no fetch) so the countdown stays honest between polls;
    /// it runs only while some line actually moves (`hasLiveCountdown`).
    /// `Display.clockCountdown`/`daysCountdown` pin at "0:00"/"0.0d" once
    /// their anchor is past rather than going nil, so a frozen session or an
    /// expired week keeps this timer running past the reset moment - the
    /// other, still-live line continues to tick.
    private func setCountdownTimerActive(_ active: Bool) {
        guard active else {
            countdownTimer?.invalidate()
            countdownTimer = nil
            return
        }
        guard countdownTimer == nil else { return }
        let t = Timer(timeInterval: Self.countdownRepaintInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.dispatch(.tick(now: self.clock()))
        }
        RunLoop.main.add(t, forMode: .common)
        countdownTimer = t
    }
}
