import ClaudeUsageBarCore
import XCTest

/// Pins the presentation lens: one call resolves a metric's displayed
/// percentage, fill fraction, and warning band for the state's Numbers mode,
/// so no drawer re-derives any of them.
final class MetricPresentationTests: XCTestCase {
    private func state(usedPct: Double, numbers: Display.NumberMode) -> UsageState {
        var prefs = UsagePrefs.standard
        prefs.numbers = numbers
        var state = UsageState.initial(now: 0, prefs: prefs)
        state.session = MetricState(
            metric: metricFixture(key: MetricKey.session, usedPct: usedPct, secondsUntil: nil),
            resetAnchor: nil, remainingSeconds: nil)
        return state
    }

    func testUsedMode() {
        let p = state(usedPct: 37, numbers: .used).presentations[0]
        XCTAssertTrue(p.key == MetricKey.session, "presentation carries the metric key")
        XCTAssertTrue(p.displayedPct == 37, "used mode displays used pct")
        XCTAssertTrue(approxEqual(p.fillFraction, 0.37), "used mode fills by used pct")
        XCTAssertTrue(p.band == .normal, "37% used leaves 63% remaining, normal band")
    }

    func testRemainingMode() {
        let p = state(usedPct: 37, numbers: .remaining).presentations[0]
        XCTAssertTrue(p.displayedPct == 63, "remaining mode displays remaining pct")
        XCTAssertTrue(approxEqual(p.fillFraction, 0.63), "remaining mode fills by remaining pct")
    }

    func testBandIsModeIndependent() {
        let used = state(usedPct: 90, numbers: .used).presentations[0]
        let remaining = state(usedPct: 90, numbers: .remaining).presentations[0]
        XCTAssertTrue(used.band == .critical, "10% remaining is critical in used mode")
        XCTAssertTrue(remaining.band == .critical, "10% remaining is critical in remaining mode")
    }

    func testBandDerivesFromUsedPctNotDecodedRemaining() {
        var prefs = UsagePrefs.standard
        prefs.numbers = .remaining
        var s = UsageState.initial(now: 0, prefs: prefs)
        // Fields deliberately disagree: decoded remaining_pct says 50, the
        // canonical usedPct says 10 remaining. The band follows usedPct.
        s.session = MetricState(
            metric: Metric(key: MetricKey.session, usedPct: 90, remainingPct: 50, reset: nil),
            resetAnchor: nil, remainingSeconds: nil)
        XCTAssertTrue(s.presentations[0].band == .critical, "band derives remaining from usedPct")
    }

    func testOptionalLiftAndSampleLens() {
        let s = state(usedPct: 37, numbers: .used)
        XCTAssertTrue(s.presentation(for: nil as MetricState?) == nil, "nil metric has no presentation")
        XCTAssertTrue(s.displayedPct(fromUsed: 20) == 20, "used mode plots a sample's used pct")
        XCTAssertTrue(
            state(usedPct: 37, numbers: .remaining).displayedPct(fromUsed: 20) == 80,
            "remaining mode plots a sample's remaining pct")
    }
}
