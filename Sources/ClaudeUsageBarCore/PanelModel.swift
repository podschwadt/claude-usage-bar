import AppKit

/// One drawable chart series: a color plus its points.
package struct ChartSeriesModel {
    package let color: NSColor
    /// Legend name shown before the value in the hover readout; nil for a
    /// single-series chart, where a name adds nothing.
    package let label: String?
    package let points: [(ts: Int, value: Double)]

    package init(color: NSColor, label: String? = nil, points: [(ts: Int, value: Double)]) {
        self.color = color
        self.label = label
        self.points = points
    }
}

/// One ring gauge in the panel's rings row: `label` above the ring, a
/// circular track plus an arc covering the displayed `fraction` (0...1)
/// of it, `value` big in the center ("65%", or "?" when
/// untrustworthy), and `caption` beneath the value (a countdown string, or
/// "" when there is none - Fable has no reset timer in `/usage`).
package struct RingModel {
    package let label: String
    package let color: NSColor
    package let fraction: Double
    package let value: String
    package let caption: String

    package init(label: String, color: NSColor, fraction: Double, value: String, caption: String) {
        self.label = label
        self.color = color
        self.fraction = fraction
        self.value = value
        self.caption = caption
    }
}

/// Pure content assembly for the history panel: takes the latest metrics,
/// the row samples already queried from `HistoryStore`, and the current
/// time, and produces everything the panel's views draw. No AppKit drawing
/// happens here - `NSColor` values are just data (the design's tints),
/// matching the `StatusBarRenderer.gauges` pure-model split.
package struct PanelModel {
    package let rings: [RingModel]
    package let sessionWindow: TimeWindow
    package let weekWindow: TimeWindow
    package let sessionSeries: [ChartSeriesModel]
    package let weekSeries: [ChartSeriesModel]
    package let footer: String
    package let sessionPlaceholder: String?
    package let weekPlaceholder: String?

    package init(
        rings: [RingModel],
        sessionWindow: TimeWindow, weekWindow: TimeWindow,
        sessionSeries: [ChartSeriesModel], weekSeries: [ChartSeriesModel],
        footer: String,
        sessionPlaceholder: String?, weekPlaceholder: String?
    ) {
        self.rings = rings
        self.sessionWindow = sessionWindow
        self.weekWindow = weekWindow
        self.sessionSeries = sessionSeries
        self.weekSeries = weekSeries
        self.footer = footer
        self.sessionPlaceholder = sessionPlaceholder
        self.weekPlaceholder = weekPlaceholder
    }

    /// Shown in place of a chart whose series all have fewer than 2 points -
    /// nothing to draw a line between yet (the first-launch state).
    private static let collectingHistoryText = "collecting history…"

    /// Assembles a `PanelModel` from `state` - the machine's single
    /// committed instant, already carrying every metric anchored
    /// (`MetricState.resetAnchor`/`remainingSeconds`), the trust level,
    /// `now`, `queriedAtUnix`, and the derived `sessionWindow`/`weekWindow`
    /// - plus the row samples already queried from `HistoryStore` for those
    /// same windows.
    /// `debugLabel` overrides the footer with "DEBUG - <scenario title>"
    /// when the state being rendered came from a `DebugScenario` rather than
    /// a real fetch; nil (the normal path) leaves the "Updated ..."/"No data
    /// yet" footer untouched.
    package static func build(
        state: UsageState, sessionSamples: [Sample], weekSamples: [Sample],
        baseColor: NSColor, fableColor: NSColor, debugLabel: String? = nil
    ) -> PanelModel {
        // Stored samples carry used_pct; the Numbers-mode lens resolves each
        // to its displayed percentage exactly once, here. ChartGeometry
        // plots the values as-is. Every series opens with a synthetic origin
        // point (see `originPoint`) ahead of the recorded rows, each derived
        // from its own metric's anchor — fable's weekly window carries its
        // own reset, so it gets its own origin rather than borrowing week's.
        let sessionSeries = [
            ChartSeriesModel(
                color: baseColor,
                points: originPoint(
                    state: state, anchor: state.session?.resetAnchor,
                    windowLength: HistoryMath.sessionLength, firstSampleTs: sessionSamples.first?.ts)
                    + sessionSamples.map { (ts: $0.ts, value: state.displayedPct(fromUsed: $0.session)) })
        ]

        let weekFirstTs = weekSamples.first?.ts
        let weekSeries = [
            ChartSeriesModel(
                color: baseColor, label: "week",
                points: originPoint(
                    state: state, anchor: state.week?.resetAnchor,
                    windowLength: HistoryMath.weekLength, firstSampleTs: weekFirstTs)
                    + weekSamples.map { (ts: $0.ts, value: state.displayedPct(fromUsed: $0.week)) }),
            ChartSeriesModel(
                color: fableColor, label: "fable",
                points: originPoint(
                    state: state, anchor: state.fable?.resetAnchor,
                    windowLength: HistoryMath.weekLength, firstSampleTs: weekFirstTs)
                    + weekSamples.map { (ts: $0.ts, value: state.displayedPct(fromUsed: $0.fable)) }),
        ]

        // The three metrics condensed into ring gauges, drawn from the same
        // presentation lens as the menu bar: session and week get their own
        // countdown as the caption; Fable has no reset timer in `/usage`, so
        // its ring carries only the label above it.
        // Rings only show numbers the app stands behind: no presentation
        // while trust is anything but .trusted, even for a present metric.
        let trusted = state.trust == .trusted
        let sessionP = trusted ? state.presentation(for: state.session) : nil
        let weekP = trusted ? state.presentation(for: state.week) : nil
        let fableP = trusted ? state.presentation(for: state.fable) : nil
        let rings = [
            RingModel(
                label: "SESSION", color: Self.ringColor(sessionP, base: baseColor),
                fraction: sessionP?.fillFraction ?? 0,
                value: Self.ringValue(sessionP),
                caption: Display.clockCountdown(seconds: state.session?.remainingSeconds) ?? ""),
            RingModel(
                label: "WEEK", color: Self.ringColor(weekP, base: baseColor),
                fraction: weekP?.fillFraction ?? 0,
                value: Self.ringValue(weekP),
                caption: Display.daysCountdown(seconds: state.week?.remainingSeconds) ?? ""),
            RingModel(
                label: "FABLE", color: Self.ringColor(fableP, base: fableColor),
                fraction: fableP?.fillFraction ?? 0,
                value: Self.ringValue(fableP), caption: ""),
        ]

        // queried_at is present on every trustworthy snapshot; before the
        // first successful fetch there is nothing to have been queried at,
        // so the footer says so rather than fabricating an "Updated" time
        // from `now`, which the panel never actually queried anything at.
        let footer =
            debugLabel
            ?? state.queriedAtUnix.map {
                "Updated \(Display.clockTime(Date(timeIntervalSince1970: TimeInterval($0))))"
            }
            ?? "No data yet"

        return PanelModel(
            rings: rings,
            sessionWindow: state.sessionWindow, weekWindow: state.weekWindow,
            sessionSeries: sessionSeries, weekSeries: weekSeries,
            footer: footer,
            sessionPlaceholder: Self.sessionPlaceholder(for: sessionSeries, anchor: state.session?.resetAnchor),
            weekPlaceholder: Self.placeholder(for: weekSeries)
        )
    }

    /// unix(queried_at) + reset.seconds_until — the single reset-anchor
    /// rule. `UsageMachine.anchoredMetricState` is its only caller
    /// (the single place the anchor/identity math lives): it stamps every
    /// `MetricState.resetAnchor` this way, and `PanelModel.build` reads that
    /// already-derived value off `state.session?.resetAnchor`/
    /// `state.week?.resetAnchor` rather than recomputing it — the two agree
    /// by construction, since both ultimately call this exact function on
    /// the same `queriedAt`/`secondsUntil` pair. Nil when either input is
    /// missing: `reset.at` is never parsed directly, since it can arrive
    /// without a timezone offset (`Display.iso8601Date` then returns nil)
    /// and can be up to 24h stale, while `queried_at` always carries an
    /// offset and `seconds_until` is always non-negative.
    package static func resetAnchor(queriedAt: String?, secondsUntil: Int?) -> Int? {
        guard let queriedAt, let date = Display.iso8601Date(queriedAt), let secondsUntil else { return nil }
        return Int(date.timeIntervalSince1970) + secondsUntil
    }

    /// Seconds until a metric's reset as of `now`, via the anchor above -
    /// the app's single countdown source. Every displayed countdown (menu
    /// bar cell, tooltip, menu rows, ring captions) must tick
    /// against this same clock; the snapshot's raw `seconds_until` is frozen
    /// at fetch time and drifts stale between polls.
    package static func remainingSeconds(queriedAt: String?, secondsUntil: Int?, now: Int) -> Int? {
        resetAnchor(queriedAt: queriedAt, secondsUntil: secondsUntil).map { $0 - now }
    }

    /// A session's identity, derived since `/usage` reports no session id:
    /// the unix-seconds start of its 5-hour window, i.e. `resetAnchor -
    /// sessionLength`. `/usage` rounds `seconds_until`, so two polls of the
    /// same session can derive values up to a minute apart: two samples
    /// belong to the same session iff their derived values fall within
    /// `HistoryMath.sessionStartTolerance` of each other, and `HistoryStore`
    /// rows carry the value as `session_start` for exactly that comparison.
    /// Nil whenever `resetAnchor` is (see its doc comment).
    package static func sessionStart(queriedAt: String?, secondsUntil: Int?) -> Int? {
        resetAnchor(queriedAt: queriedAt, secondsUntil: secondsUntil).map(sessionStart(resetAnchor:))
    }

    /// The identity above from an already-derived anchor - the session-scoped
    /// history query (`HistoryCoordinator.chartSamples`) starts from
    /// `MetricState.resetAnchor` rather than the raw snapshot fields, and
    /// must land on the same value the recording site stored.
    package static func sessionStart(resetAnchor: Int) -> Int {
        resetAnchor - HistoryMath.sessionLength
    }

    /// Synthetic origin for a chart series: a quota window (5h session, 7d
    /// week, 7d fable) opens with 0% used by definition, but its first
    /// recorded row lands only at the first poll that observed the window —
    /// up to one refresh interval late, later still when the machine slept
    /// through the boundary or the server backdates the window's start to
    /// the previous boundary — so without this point a chart's opening
    /// stretch is blank. The 0-used value passes through the same
    /// Numbers-mode lens as the recorded rows (100 in remaining mode, 0 in
    /// used mode), and the point counts toward the placeholder threshold:
    /// one recorded row is enough to draw. Empty when `anchor` is nil (no
    /// window identity to pin the origin to), or when the first row's `ts`
    /// is at or before the derived start — the anchor jitters up to a
    /// minute across polls (see `sessionStart(queriedAt:secondsUntil:)`),
    /// a week bucket's timestamp is floored below the raw rows it averages,
    /// and series points must stay ascending in `ts`.
    private static func originPoint(
        state: UsageState, anchor: Int?, windowLength: Int, firstSampleTs: Int?
    ) -> [(ts: Int, value: Double)] {
        guard let anchor else { return [] }
        let start = anchor - windowLength
        guard firstSampleTs.map({ start < $0 }) ?? true else { return [] }
        return [(ts: start, value: state.displayedPct(fromUsed: 0))]
    }

    /// "?" when the ring has no presentation (absent metric, or any state
    /// the trust gate above withholds), else the formatted displayed
    /// percentage from the presentation lens.
    private static func ringValue(_ p: MetricPresentation?) -> String {
        p.map { Display.pct($0.displayedPct) } ?? "?"
    }

    /// The metric's base tint, switching to the shared low-headroom warning
    /// colors (orange, then red) via the presentation's band, exactly like
    /// the menu bar gauges; the plain base for an absent metric.
    private static func ringColor(_ p: MetricPresentation?, base: NSColor) -> NSColor {
        p.map { Display.barFillColor(band: $0.band, base: base) } ?? base
    }

    /// "collecting history…" when every series in the chart still has fewer
    /// than 2 points (nothing to draw a line between yet); nil once any
    /// series has enough data to plot.
    private static func placeholder(for series: [ChartSeriesModel]) -> String? {
        series.allSatisfy { $0.points.count < 2 } ? collectingHistoryText : nil
    }

    /// The session chart is scoped to the current session; no anchor means
    /// no session is active (between 5 h windows, `/usage` reports no
    /// reset), which is its own state rather than "collecting history".
    private static func sessionPlaceholder(for series: [ChartSeriesModel], anchor: Int?) -> String? {
        anchor == nil ? "No active session" : placeholder(for: series)
    }
}
