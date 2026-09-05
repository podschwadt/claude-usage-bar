import Foundation

/// One frozen debug picture: a `UsageState` plus the history rows its charts
/// would plot, built once at selection time rather than recomputed per
/// render (see `DebugScenario.scene(now:prefs:)`). Pure, AppKit-free, and
/// unit-testable in the same regime as `PanelModel`/`UsageMachine`.
package struct DebugScene {
    package let state: UsageState
    package let sessionSamples: [Sample]
    package let weekSamples: [Sample]

    package init(state: UsageState, sessionSamples: [Sample], weekSamples: [Sample]) {
        self.state = state
        self.sessionSamples = sessionSamples
        self.weekSamples = weekSamples
    }
}

/// Synthetic scenes for exercising the menu bar and panel without a real
/// `/usage` fetch. Each scene is produced by folding a synthetic
/// `UsageSnapshot` through the REAL `UsageMachine.transition`, starting from
/// a fresh `UsageState.initial(now:prefs:)` - a genuinely separate machine
/// instance, never the app's live `state`. Emitted `Step.effects` are
/// discarded: nothing here is recorded to the history store, and no poll is
/// ever triggered. History rows are synthesized directly rather than
/// queried, since the debug path never touches `HistoryCoordinator`.
package enum DebugScenario: String, CaseIterable {
    /// The reported bug: fable plots above week for the whole window, so
    /// fable's 50%-alpha fill washes over week's line and fill.
    case fableAboveWeek
    /// The mirror image - week higher, still painted under fable's fill.
    case weekAboveFable
    /// The two series cross mid-window, so each occludes the other in a
    /// different region - the sharpest test of any occlusion fix.
    case crossover
    /// Identical values throughout: the worst case, where week is
    /// completely invisible under fable's fill.
    case coincident
    /// No session in progress: the session metric is REPORTED but carries
    /// no reset, so its gauge still draws and its countdown dashes out to
    /// `Display.unknownClockCountdown`, while the session chart reads "No
    /// active session" beside a live week chart. The metric is present
    /// rather than absent because `session` is one of the parser's
    /// REQUIRED_KEYS: a snapshot missing it fails `schema_ok` and never
    /// reaches a trusted state at all.
    case noSessionWithWeekHistory
    /// `trust == .loading`, no samples: menu bar reads "CL ...", session
    /// chart reads "No active session" (`UsageState.initial` has no
    /// session, so there is no window to collect history for), and only the
    /// week chart reads "collecting history…".
    case firstLaunch
    /// A trusted snapshot with all three metrics present but zero samples
    /// recorded yet, so both charts genuinely read "collecting history…" -
    /// the picture `firstLaunch` does not provide, since its session is nil.
    case collectingHistory
    /// Untrustworthy state: "CL ?" menu bar, error rows in the menu, "?" in
    /// the rings.
    case fetchFailed
    /// Metrics in the orange and red warning bands, to check
    /// `Display.barFillColor` / ring tinting.
    case nearLimit

    package var title: String {
        switch self {
        case .fableAboveWeek: return "Fable Above Week"
        case .weekAboveFable: return "Week Above Fable"
        case .crossover: return "Crossover"
        case .coincident: return "Coincident"
        case .noSessionWithWeekHistory: return "No Session (Week History)"
        case .firstLaunch: return "First Launch"
        case .collectingHistory: return "Collecting History"
        case .fetchFailed: return "Fetch Failed"
        case .nearLimit: return "Near Limit"
        }
    }

    /// Points synthesized per chart series - enough to draw a clear ramp
    /// well past the 2-point placeholder threshold.
    private static let sampleCount = 24

    /// Builds this scenario's frozen scene against clock reading `now` and
    /// the live `UsagePrefs` (so a synthetic scene still respects the user's
    /// current Numbers mode/layout/color choices, exactly like a real
    /// snapshot would).
    package func scene(now: Int, prefs: UsagePrefs) -> DebugScene {
        switch self {
        case .fableAboveWeek:
            return Self.rampScene(
                now: now, prefs: prefs, sessionAnchored: true,
                session: (30, 50),
                orderedAboveIsFable: true, low: (20, 30), high: (60, 70))
        case .weekAboveFable:
            return Self.rampScene(
                now: now, prefs: prefs, sessionAnchored: true,
                session: (30, 50),
                orderedAboveIsFable: false, low: (20, 30), high: (60, 70))
        case .crossover:
            // The sign of fable-week must flip somewhere in the window in
            // EITHER Numbers mode. Negating both ramps (used -> remaining)
            // negates the difference at every point without changing where
            // it crosses zero, so - unlike fableAboveWeek/weekAboveFable -
            // no mode-dependent derivation is needed here to keep the name
            // honest.
            return Self.rampScene(
                now: now, prefs: prefs, sessionAnchored: true,
                session: (30, 50),
                week: (20, 80), fable: (80, 20))
        case .coincident:
            return Self.rampScene(
                now: now, prefs: prefs, sessionAnchored: true,
                session: (30, 50),
                week: (30, 60), fable: (30, 60))
        case .noSessionWithWeekHistory:
            return Self.rampScene(
                now: now, prefs: prefs, sessionAnchored: false,
                session: (0, 0),
                week: (20, 40), fable: (50, 70))
        case .firstLaunch:
            return DebugScene(state: UsageState.initial(now: now, prefs: prefs), sessionSamples: [], weekSamples: [])
        case .collectingHistory:
            let queriedAt = Display.iso8601String(Date(timeIntervalSince1970: TimeInterval(now)))
            let metrics: [String: Metric] = [
                MetricKey.session: Self.metric(
                    key: MetricKey.session, usedPct: 0, secondsUntil: HistoryMath.sessionLength),
                MetricKey.week: Self.metric(key: MetricKey.week, usedPct: 0, secondsUntil: HistoryMath.weekLength),
                MetricKey.fable: Self.metric(key: MetricKey.fable, usedPct: 0, secondsUntil: HistoryMath.weekLength),
            ]
            let snapshot = UsageSnapshot(
                ok: true, error: nil, schemaOk: true, missingKeys: nil,
                metrics: metrics, activity: nil, queriedAt: queriedAt, raw: "debug scenario snapshot")
            let state = UsageMachine.transition(
                UsageState.initial(now: now, prefs: prefs), .snapshot(snapshot, now: now)
            ).state
            return DebugScene(state: state, sessionSamples: [], weekSamples: [])
        case .fetchFailed:
            let state = UsageMachine.transition(
                UsageState.initial(now: now, prefs: prefs),
                .snapshot(
                    UsageSnapshot.failure("connection refused - debug scenario"), now: now)
            ).state
            return DebugScene(state: state, sessionSamples: [], weekSamples: [])
        case .nearLimit:
            return Self.rampScene(
                now: now, prefs: prefs, sessionAnchored: true,
                session: (85, 90),
                week: (90, 94), fable: (93, 97))
        }
    }

    // MARK: - Scene construction

    /// Assigns week/fable used-pct ramps so whichever ramp is named "above"
    /// (`high` for `orderedAboveIsFable == true` meaning fable, else week)
    /// is always the higher DISPLAYED series regardless of Numbers mode:
    /// used mode plots usedPct directly, so the above series needs the
    /// higher usedPct ramp; remaining mode plots 100-usedPct, so it needs
    /// the LOWER usedPct ramp instead - the exact inversion in
    /// `UsageState.displayedPct(fromUsed:)`.
    private static func orderedUsedPct(
        prefs: UsagePrefs, aboveIsFable: Bool, low: (Double, Double), high: (Double, Double)
    ) -> (week: (Double, Double), fable: (Double, Double)) {
        let aboveTakesHighUsed = prefs.numbers == .used
        let aboveRamp = aboveTakesHighUsed ? high : low
        let belowRamp = aboveTakesHighUsed ? low : high
        return aboveIsFable ? (week: belowRamp, fable: aboveRamp) : (week: aboveRamp, fable: belowRamp)
    }

    /// Shared scene builder for every scenario driven by linear ramps: builds
    /// a synthetic snapshot, folds it through the real `UsageMachine`, then
    /// synthesizes session/week samples ramping across the resulting windows.
    /// `sessionAnchored` false gives the session metric no reset, modelling
    /// a reported-but-inactive session (the `noSessionWithWeekHistory`
    /// case); the metric itself is always present.
    private static func rampScene(
        now: Int, prefs: UsagePrefs, sessionAnchored: Bool, session: (Double, Double),
        orderedAboveIsFable: Bool, low: (Double, Double), high: (Double, Double)
    ) -> DebugScene {
        let (week, fable) = orderedUsedPct(prefs: prefs, aboveIsFable: orderedAboveIsFable, low: low, high: high)
        return rampScene(
            now: now, prefs: prefs, sessionAnchored: sessionAnchored, session: session, week: week, fable: fable)
    }

    /// Reset countdown baked into the synthetic session metric: places the
    /// session window's anchor (its true end) half-way through the window,
    /// so `ramp` truncated at `now` (see `rampValue`) still has room to draw
    /// before the cutoff.
    private static let sessionRampSecondsUntil = HistoryMath.sessionLength / 2
    /// As above for the week/fable metrics: places the week window's anchor
    /// two-thirds of the way through the window (the anchor lands in the
    /// FUTURE relative to `now`, exactly like a real in-progress window).
    private static let weekRampSecondsUntil = HistoryMath.weekLength / 3

    /// As above, for scenarios that pick their week/fable ramps directly
    /// rather than through `orderedUsedPct` (`crossover`/`coincident`, whose
    /// defining property does not depend on Numbers mode).
    private static func rampScene(
        now: Int, prefs: UsagePrefs, sessionAnchored: Bool, session: (Double, Double),
        week: (Double, Double), fable: (Double, Double)
    ) -> DebugScene {
        // Placeholder metrics just to fold a snapshot through the real
        // machine and recover its windows/anchors; `usedPct` here is
        // irrelevant and overwritten below once the actual windows are
        // known, since real recorded history never runs past `now` and the
        // metrics must agree with wherever the truncated ramp actually ends.
        let queriedAt = Display.iso8601String(Date(timeIntervalSince1970: TimeInterval(now)))
        let placeholderMetrics: [String: Metric] = {
            var m: [String: Metric] = [
                MetricKey.week: Self.metric(key: MetricKey.week, usedPct: week.0, secondsUntil: weekRampSecondsUntil),
                MetricKey.fable: Self.metric(
                    key: MetricKey.fable, usedPct: fable.0, secondsUntil: weekRampSecondsUntil),
            ]
            m[MetricKey.session] = Self.metric(
                key: MetricKey.session, usedPct: session.0,
                secondsUntil: sessionAnchored ? sessionRampSecondsUntil : nil)
            return m
        }()

        let placeholderSnapshot = UsageSnapshot(
            ok: true, error: nil, schemaOk: true, missingKeys: nil,
            metrics: placeholderMetrics, activity: nil, queriedAt: queriedAt, raw: "debug scenario snapshot")
        let placeholderState = UsageMachine.transition(
            UsageState.initial(now: now, prefs: prefs), .snapshot(placeholderSnapshot, now: now)
        ).state

        // Real recorded history never runs past `now`; the rings, menu bar,
        // and chart's last point must all agree on the used-pct the ramp
        // has actually reached there, not the ramp's nominal end value.
        let reachedWeek = Self.rampValue(window: placeholderState.weekWindow, now: now, ramp: week)
        let reachedFable = Self.rampValue(window: placeholderState.weekWindow, now: now, ramp: fable)
        let reachedSession = Self.rampValue(window: placeholderState.sessionWindow, now: now, ramp: session)

        let metrics: [String: Metric] = {
            var m: [String: Metric] = [
                MetricKey.week: Self.metric(
                    key: MetricKey.week, usedPct: reachedWeek, secondsUntil: weekRampSecondsUntil),
                MetricKey.fable: Self.metric(
                    key: MetricKey.fable, usedPct: reachedFable, secondsUntil: weekRampSecondsUntil),
            ]
            m[MetricKey.session] = Self.metric(
                key: MetricKey.session, usedPct: reachedSession,
                secondsUntil: sessionAnchored ? sessionRampSecondsUntil : nil)
            return m
        }()
        let snapshot = UsageSnapshot(
            ok: true, error: nil, schemaOk: true, missingKeys: nil,
            metrics: metrics, activity: nil, queriedAt: queriedAt, raw: "debug scenario snapshot")
        let state = UsageMachine.transition(
            UsageState.initial(now: now, prefs: prefs), .snapshot(snapshot, now: now)
        ).state

        // Week samples carry SOME sessionStart value (the column is
        // non-nullable, see `Sample`), even though the week query never
        // filters on it: fall back to `now` when no session anchor exists.
        let sessionStart = (state.session?.resetAnchor).map(PanelModel.sessionStart(resetAnchor:)) ?? now

        let weekSamples = Self.ramp(
            window: state.weekWindow, now: now, count: sampleCount, sessionStart: sessionStart,
            session: session, week: week, fable: fable)

        // An unanchored session has no window to have recorded rows for:
        // `HistoryCoordinator.chartSamples` skips the session query outright
        // when the anchor is nil, so a faithful scene carries none either.
        let sessionSamples: [Sample] =
            state.session?.resetAnchor == nil
            ? []
            : Self.ramp(
                window: state.sessionWindow, now: now, count: sampleCount, sessionStart: sessionStart,
                session: session, week: week, fable: fable)

        return DebugScene(state: state, sessionSamples: sessionSamples, weekSamples: weekSamples)
    }

    /// One `Metric` fixture with a bare `ResetInfo` (no raw reset phrase).
    /// A nil `secondsUntil` models a metric `/usage` printed WITHOUT its
    /// "resets ..." clause - the metric is still reported, it just has no
    /// countdown (see `noSessionWithWeekHistory`).
    private static func metric(key: String, usedPct: Double, secondsUntil: Int?) -> Metric {
        Metric(
            key: key, usedPct: usedPct, remainingPct: 100 - usedPct,
            reset: ResetInfo(raw: nil, secondsUntil: secondsUntil))
    }

    /// The value a linear `ramp` (from `ramp.0` at `window.start` to
    /// `ramp.1` at `window.end`) has reached at `now`, clamped to the window
    /// - real recorded history never runs past `now`, and `window.end` (the
    /// metric's reset anchor) can itself be in the future for an
    /// in-progress window. Used both to truncate `ramp(_:)`'s emitted
    /// samples and to build the `Metric` fixture that must agree with the
    /// chart's last point.
    private static func rampValue(window: TimeWindow, now: Int, ramp: (Double, Double)) -> Double {
        let span = window.end - window.start
        guard span > 0 else { return ramp.0 }
        let t = min(max(Double(min(window.end, now) - window.start) / Double(span), 0), 1)
        return ramp.0 + (ramp.1 - ramp.0) * t
    }

    /// Linearly ramps `session`/`week`/`fable` used-pct across `window`,
    /// producing `count` evenly spaced samples (`count <= 1` yields none -
    /// nothing to draw a line between), truncated to `min(window.end, now)`
    /// so no sample carries a future timestamp - real recorded history stops
    /// at `now`, and a debug scene must look like what real data looks like.
    /// Every row carries `sessionStart` so a session-scoped query would
    /// filter it consistently, mirroring real recorded rows.
    private static func ramp(
        window: TimeWindow, now: Int, count: Int, sessionStart: Int,
        session: (Double, Double), week: (Double, Double), fable: (Double, Double)
    ) -> [Sample] {
        guard count > 1 else { return [] }
        let span = window.end - window.start
        guard span > 0 else { return [] }
        let clampedEnd = min(window.end, now)
        guard clampedEnd > window.start else { return [] }
        return (0..<count).map { i in
            // `localT` places the sample's timestamp within the TRUNCATED
            // range; `t` re-expresses that timestamp as a fraction of the
            // ORIGINAL (untruncated) window, so every series keeps ramping
            // at its originally intended rate right up to the cutoff.
            let localT = Double(i) / Double(count - 1)
            let ts = window.start + Int(Double(clampedEnd - window.start) * localT)
            let t = min(max(Double(ts - window.start) / Double(span), 0), 1)
            return Sample(
                ts: ts, sessionStart: sessionStart,
                session: session.0 + (session.1 - session.0) * t,
                week: week.0 + (week.1 - week.0) * t,
                fable: fable.0 + (fable.1 - fable.0) * t)
        }
    }
}
