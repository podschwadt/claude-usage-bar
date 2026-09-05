import Foundation

/// One metric's drawable numbers, resolved for the current Numbers mode.
/// Drawers (menu bar gauges, panel rings and charts) consume this and never
/// inspect the mode or the warning thresholds themselves.
package struct MetricPresentation: Equatable {
    package let key: String
    /// Percentage in the current mode (used or remaining).
    package let displayedPct: Double
    /// Gauge/ring fill for `displayedPct`, clamped to 0...1.
    package let fillFraction: Double
    /// Low-headroom warning band, a function of remaining headroom
    /// regardless of the displayed mode. Remaining is derived from
    /// `usedPct` (the canonical field), not read from the decoded
    /// `remaining_pct`.
    package let band: Display.Severity

    package init(key: String, displayedPct: Double, fillFraction: Double, band: Display.Severity) {
        self.key = key
        self.displayedPct = displayedPct
        self.fillFraction = fillFraction
        self.band = band
    }
}

extension UsageState {
    /// Lens from one metric's state to its drawable numbers under
    /// `prefs.numbers`.
    package func presentation(for metricState: MetricState) -> MetricPresentation {
        let metric = metricState.metric
        return MetricPresentation(
            key: metric.key,
            displayedPct: Display.displayPct(usedPct: metric.usedPct, mode: prefs.numbers),
            fillFraction: Display.fillFraction(usedPct: metric.usedPct, mode: prefs.numbers),
            band: Display.severity(remaining: Display.remainingPct(fromUsed: metric.usedPct)))
    }

    /// `presentation(for:)` lifted over an absent metric.
    package func presentation(for metricState: MetricState?) -> MetricPresentation? {
        metricState.map { presentation(for: $0) }
    }

    /// Presentations for every present metric, in session/week/fable order.
    package var presentations: [MetricPresentation] {
        metricStates.map { presentation(for: $0) }
    }

    /// The same lens applied to a raw used-percent value (a history sample):
    /// the percentage a chart plots for it under `prefs.numbers`.
    package func displayedPct(fromUsed usedPct: Double) -> Double {
        Display.displayPct(usedPct: usedPct, mode: prefs.numbers)
    }
}
