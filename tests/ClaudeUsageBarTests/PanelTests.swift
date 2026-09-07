import AppKit
import ClaudeUsageBarCore
import Foundation
import XCTest

private let baseColor = NSColor.systemBlue
private let fableColor = NSColor.systemTeal

/// Anchors `metric` exactly as `UsageMachine.anchoredMetricState` does
/// (same call to `PanelModel.resetAnchor`, same `remainingSeconds`
/// derivation), so fixtures built here are bit-identical to what the
/// machine would have produced for the same inputs. Nil in, nil out.
private func metricState(_ metric: Metric?, queriedAt: String?, now: Int) -> MetricState? {
    guard let metric else { return nil }
    let anchor = PanelModel.resetAnchor(queriedAt: queriedAt, secondsUntil: metric.reset?.secondsUntil)
    return MetricState(metric: metric, resetAnchor: anchor, remainingSeconds: anchor.map { $0 - now })
}

/// Shorthand for the many `PanelModel.build` calls below that only care
/// about a couple of parameters; every argument still has an explicit,
/// deliberately chosen value. Builds a `UsageState` fixture (memberwise,
/// not through `UsageMachine.transition` - these tests exercise `build`'s
/// reaction to arbitrary trust/metric combinations, including ones the
/// machine itself would never produce, e.g. a present metric alongside
/// `trustworthy: false`) and calls `build(state:...)`.
private func buildModel(
    session: Metric? = nil, week: Metric? = nil, fable: Metric? = nil, trustworthy: Bool = false,
    queriedAt: String? = nil, sessionSamples: [Sample] = [], weekSamples: [Sample] = [],
    now: Int = 1000, numbers: Display.NumberMode = .remaining
) -> PanelModel {
    var prefs = UsagePrefs.standard
    prefs.numbers = numbers
    let state = UsageState(
        trust: trustworthy ? .trusted : .loading,
        session: metricState(session, queriedAt: queriedAt, now: now),
        week: metricState(week, queriedAt: queriedAt, now: now),
        fable: metricState(fable, queriedAt: queriedAt, now: now),
        queriedAt: queriedAt,
        queriedAtUnix: queriedAt.flatMap(Display.iso8601Date).map { Int($0.timeIntervalSince1970) },
        activity: nil, raw: nil,
        sessionExpiryPolled: nil, weekExpiryPolled: nil, boundaryPollArmed: nil,
        history: .available, now: now, prefs: prefs)
    return PanelModel.build(
        state: state, sessionSamples: sessionSamples, weekSamples: weekSamples,
        baseColor: baseColor, fableColor: fableColor)
}

final class PanelTests: XCTestCase {
    // MARK: - Ring values (the panel header was removed; rings carry these)

    func testRingValues() {
        let session = metricFixture(key: MetricKey.session, usedPct: 37, secondsUntil: nil)

        let untrustworthy = buildModel(session: session, trustworthy: false)
        XCTAssertTrue(untrustworthy.rings[0].value == "?", "session ring value is ? when untrustworthy")
        XCTAssertTrue(untrustworthy.rings[0].fraction == 0, "session ring is empty when untrustworthy")

        let trustworthy = buildModel(session: session, trustworthy: true)
        XCTAssertTrue(trustworthy.rings[0].value == "63%", "session ring value is remaining % (usedPct 37 -> 63%)")
        XCTAssertTrue(trustworthy.rings[0].label == "SESSION", "session ring is labeled")

        // No session anchor (between 5h windows) -> the session chart shows
        // its own state, never "collecting history" or a stale trailing plot.
        XCTAssertTrue(
            trustworthy.sessionPlaceholder == "No active session",
            "session placeholder says no active session when the anchor is unknown")
        let anchored = buildModel(
            session: metricFixture(key: MetricKey.session, usedPct: 37, secondsUntil: 9540),
            trustworthy: true, queriedAt: queriedAtFixture)
        XCTAssertTrue(
            anchored.sessionPlaceholder == "collecting history…",
            "anchored session with <2 points still says collecting history")
    }

    // MARK: - Anchored vs trailing window selection.

    func testAnchoredVsTrailingWindow() {
        let secondsUntil = 5000
        let sessionMetric = metricFixture(key: MetricKey.session, usedPct: 1, secondsUntil: secondsUntil)
        let anchored = buildModel(
            session: sessionMetric, trustworthy: true,
            queriedAt: queriedAtFixture, now: queriedAtUnixFixture + 100)
        XCTAssertTrue(
            anchored.sessionWindow.end == queriedAtUnixFixture + secondsUntil,
            "anchored session window end == unix(queried_at) + seconds_until")

        let trailingMetric = metricFixture(key: MetricKey.session, usedPct: 1, secondsUntil: nil)
        let now = 123_456
        let trailing = buildModel(session: trailingMetric, trustworthy: true, now: now)
        XCTAssertTrue(
            trailing.sessionWindow.end == now, "trailing session window end == now when the anchor is unknown")
    }

    // The two sessionStart derivations must agree on the same snapshot: the
    // recording site derives identity from queried_at/seconds_until, while
    // the session-scoped history query re-derives it from the already-anchored
    // MetricState.resetAnchor.
    func testSessionStartOverloadsAgree() {
        let secondsUntil = 9540
        let fromSnapshot = PanelModel.sessionStart(queriedAt: queriedAtFixture, secondsUntil: secondsUntil)!
        let anchor = PanelModel.resetAnchor(queriedAt: queriedAtFixture, secondsUntil: secondsUntil)!
        XCTAssertTrue(
            fromSnapshot == PanelModel.sessionStart(resetAnchor: anchor),
            "sessionStart from raw snapshot fields matches sessionStart from the derived anchor")
    }

    // MARK: - Series origins: every anchored series is pinned to (window
    // start, 0 used) ahead of the recorded rows, since a quota window opens
    // at 0% used by definition but its first recorded row lands only at the
    // first poll that observed the window.

    func testSessionSeriesStartsAtOrigin() {
        let secondsUntil = 9540
        let anchor = PanelModel.resetAnchor(queriedAt: queriedAtFixture, secondsUntil: secondsUntil)!
        let start = PanelModel.sessionStart(resetAnchor: anchor)
        let sample = Sample(ts: start + 600, sessionStart: start, session: 4, week: 10, fable: 5)
        let sessionMetric = metricFixture(key: MetricKey.session, usedPct: 4, secondsUntil: secondsUntil)

        let model = buildModel(
            session: sessionMetric, trustworthy: true, queriedAt: queriedAtFixture,
            sessionSamples: [sample], now: queriedAtUnixFixture)
        let points = model.sessionSeries[0].points
        XCTAssertTrue(points.count == 2, "origin point is prepended ahead of the recorded row")
        XCTAssertTrue(points[0].ts == start, "origin sits at the session window's start")
        XCTAssertTrue(approxEqual(points[0].value, 100), "remaining mode: origin plots 100%")
        XCTAssertTrue(points[1].ts == start + 600, "recorded row follows the origin unchanged")
        XCTAssertTrue(model.sessionPlaceholder == nil, "origin plus one recorded row is enough to draw")

        let used = buildModel(
            session: sessionMetric, trustworthy: true, queriedAt: queriedAtFixture,
            sessionSamples: [sample], now: queriedAtUnixFixture, numbers: .used)
        XCTAssertTrue(approxEqual(used.sessionSeries[0].points[0].value, 0), "used mode: origin plots 0% used")
    }

    // The anchor (and so the derived start) jitters up to a minute across
    // polls, which can put a recorded row at or before the derived start;
    // the origin is skipped then so the series stays ascending in ts.
    func testSessionOriginSkippedWhenRowPrecedesStart() {
        let secondsUntil = 9540
        let anchor = PanelModel.resetAnchor(queriedAt: queriedAtFixture, secondsUntil: secondsUntil)!
        let start = PanelModel.sessionStart(resetAnchor: anchor)
        let jittered = Sample(ts: start - 30, sessionStart: start - 30, session: 4, week: 10, fable: 5)

        let model = buildModel(
            session: metricFixture(key: MetricKey.session, usedPct: 4, secondsUntil: secondsUntil),
            trustworthy: true, queriedAt: queriedAtFixture,
            sessionSamples: [jittered], now: queriedAtUnixFixture)
        let points = model.sessionSeries[0].points
        XCTAssertTrue(points.count == 1, "no origin when the first row is at or before the derived start")
        XCTAssertTrue(points[0].ts == start - 30, "the jittered row itself is kept")
    }

    // The week chart's series each pin their own origin: week and fable are
    // separate weekly windows carrying their own anchors.
    func testWeekSeriesStartAtTheirOrigins() {
        let weekAnchor = PanelModel.resetAnchor(queriedAt: queriedAtFixture, secondsUntil: 90000)!
        let fableAnchor = PanelModel.resetAnchor(queriedAt: queriedAtFixture, secondsUntil: 90060)!
        let weekStart = weekAnchor - HistoryMath.weekLength
        let sample = Sample(ts: weekStart + 3600, sessionStart: 0, session: 10, week: 12, fable: 3)
        let model = buildModel(
            week: metricFixture(key: MetricKey.week, usedPct: 12, secondsUntil: 90000),
            fable: metricFixture(key: MetricKey.fable, usedPct: 3, secondsUntil: 90060),
            trustworthy: true, queriedAt: queriedAtFixture,
            weekSamples: [sample], now: queriedAtUnixFixture)
        let week = model.weekSeries[0].points
        let fable = model.weekSeries[1].points
        XCTAssertTrue(week.count == 2 && fable.count == 2, "each series has its origin plus the recorded row")
        XCTAssertTrue(week[0].ts == weekStart, "week origin sits at the week window's start")
        XCTAssertTrue(approxEqual(week[0].value, 100), "remaining mode: week origin plots 100%")
        XCTAssertTrue(
            fable[0].ts == fableAnchor - HistoryMath.weekLength, "fable origin derives from fable's own anchor")
    }

    // No anchor means no window identity to pin an origin to: the session
    // series gets none without a session reset, and the fable series gets
    // none without a fable metric, even beside an anchored week.
    func testOriginRequiresAnchor() {
        let weekAnchor = PanelModel.resetAnchor(queriedAt: queriedAtFixture, secondsUntil: 90000)!
        let weekSample = Sample(
            ts: weekAnchor - HistoryMath.weekLength + 3600, sessionStart: 400, session: 37, week: 12, fable: 3)
        let model = buildModel(
            session: metricFixture(key: MetricKey.session, usedPct: 37, secondsUntil: nil),
            week: metricFixture(key: MetricKey.week, usedPct: 12, secondsUntil: 90000),
            trustworthy: true, queriedAt: queriedAtFixture,
            sessionSamples: [Sample(ts: 500, sessionStart: 400, session: 37, week: 12, fable: 3)],
            weekSamples: [weekSample])
        XCTAssertTrue(model.sessionSeries[0].points.count == 1, "no origin without a session anchor")
        XCTAssertTrue(model.weekSeries[0].points.count == 2, "the anchored week series gets its origin")
        XCTAssertTrue(model.weekSeries[1].points.count == 1, "no fable origin without a fable metric")
    }

    // MARK: - Placeholder: set at <2 points, nil at >=2.

    func testPlaceholderPointCountThreshold() {
        // The session placeholder rules apply within an ACTIVE session, so
        // these fixtures carry an anchor (no anchor -> "No active session").
        let anchoredSession = metricFixture(key: MetricKey.session, usedPct: 10, secondsUntil: 9540)
        let onePoint = [Sample(ts: 0, sessionStart: 0, session: 10, week: 0, fable: 0)]
        let modelOne = buildModel(
            session: anchoredSession, queriedAt: queriedAtFixture,
            sessionSamples: onePoint)
        XCTAssertTrue(modelOne.sessionPlaceholder == "collecting history…", "placeholder set with fewer than 2 points")

        let twoPoints = [
            Sample(ts: 0, sessionStart: 0, session: 10, week: 0, fable: 0),
            Sample(ts: 60, sessionStart: 0, session: 20, week: 0, fable: 0),
        ]
        let modelTwo = buildModel(
            session: anchoredSession, queriedAt: queriedAtFixture,
            sessionSamples: twoPoints)
        XCTAssertTrue(modelTwo.sessionPlaceholder == nil, "placeholder nil with 2 or more points")
    }

    // MARK: - Week series order: base color first, then fable color.

    func testWeekSeriesOrder() {
        let model = buildModel()
        XCTAssertTrue(model.weekSeries.count == 2, "week chart has exactly two series")
        XCTAssertTrue(model.weekSeries[0].color == baseColor, "week series[0] uses the base color")
        XCTAssertTrue(model.weekSeries[1].color == fableColor, "week series[1] uses the fable color")
    }

    // MARK: - Rings: colors, "?"/0 when untrustworthy, clamped fractions,
    // captions present/absent, labels.

    func testRingColorsAndLabels() {
        let session = metricFixture(key: MetricKey.session, usedPct: 20, secondsUntil: nil)
        let week = metricFixture(key: MetricKey.week, usedPct: 40, secondsUntil: nil)
        let fable = metricFixture(key: MetricKey.fable, usedPct: 60, secondsUntil: nil)

        let untrustworthy = buildModel(session: session, week: week, fable: fable, trustworthy: false)
        XCTAssertTrue(untrustworthy.rings.count == 3, "rings always has 3 entries (session, week, fable)")
        for ring in untrustworthy.rings {
            XCTAssertTrue(ring.value == "?", "untrustworthy ring value is \"?\"")
            XCTAssertTrue(ring.fraction == 0, "untrustworthy ring fraction is 0 (empty ring, track only)")
        }

        let trustworthy = buildModel(session: session, week: week, fable: fable, trustworthy: true)
        XCTAssertTrue(trustworthy.rings[0].value == "80%", "session ring value is remaining % (usedPct 20 -> 80%)")
        XCTAssertTrue(approxEqual(trustworthy.rings[0].fraction, 0.8), "session ring fraction matches remaining/100")
        XCTAssertTrue(trustworthy.rings[1].value == "60%", "week ring value (usedPct 40 -> 60%)")
        XCTAssertTrue(trustworthy.rings[2].value == "40%", "fable ring value (usedPct 60 -> 40%)")

        XCTAssertTrue(trustworthy.rings[0].color == baseColor, "session ring uses the base color")
        XCTAssertTrue(trustworthy.rings[1].color == baseColor, "week ring uses the base color")
        XCTAssertTrue(trustworthy.rings[2].color == fableColor, "fable ring uses the fable color")

        // Low headroom carries the menu bar gauges' warning colors over to
        // the wheels: orange at <= 25% remaining, red at <= 10%.
        let warning = metricFixture(key: MetricKey.session, usedPct: 80, secondsUntil: nil)  // 20% left
        let critical = metricFixture(key: MetricKey.week, usedPct: 95, secondsUntil: nil)  // 5% left
        let low = buildModel(session: warning, week: critical, fable: fable, trustworthy: true)
        XCTAssertTrue(low.rings[0].color == .systemOrange, "ring turns orange at warning headroom")
        XCTAssertTrue(low.rings[1].color == .systemRed, "ring turns red at critical headroom")
        let lowUntrusted = buildModel(session: warning, week: critical, fable: fable, trustworthy: false)
        XCTAssertTrue(lowUntrusted.rings[0].color == baseColor, "untrustworthy ring keeps the base color")

        XCTAssertTrue(trustworthy.rings[2].caption == "", "fable ring has no caption (no reset timer)")
        XCTAssertTrue(trustworthy.rings.map(\.label) == ["SESSION", "WEEK", "FABLE"], "rings are labeled")
    }

    // Fractions clamp to 0...1 regardless of how far out of range usedPct
    // strays, same rule as `Display.fillFraction`.
    func testRingFractionClamping() {
        let overUsed = metricFixture(key: MetricKey.session, usedPct: 120, secondsUntil: nil)
        let model = buildModel(session: overUsed, trustworthy: true)
        XCTAssertTrue(model.rings[0].fraction == 0, "ring fraction clamps to 0 when usedPct exceeds 100")

        let underUsed = metricFixture(key: MetricKey.session, usedPct: -5, secondsUntil: nil)
        let clampedModel = buildModel(session: underUsed, trustworthy: true)
        XCTAssertTrue(clampedModel.rings[0].fraction == 1, "ring fraction clamps to 1 when usedPct is negative")
    }

    // Captions: present (the countdown string) when the anchor is known,
    // "" when it is not - session and week are independent of each other.
    func testRingCaptions() {
        let session = metricFixture(key: MetricKey.session, usedPct: 10, secondsUntil: 9540)  // 2h39m -> "2:39"
        let week = metricFixture(key: MetricKey.week, usedPct: 10, secondsUntil: nil)
        let model = buildModel(
            session: session, week: week, trustworthy: true,
            queriedAt: queriedAtFixture, now: queriedAtUnixFixture)
        XCTAssertTrue(
            model.rings[0].caption == "2:39", "session ring caption is its H:MM countdown when the anchor is known")
        XCTAssertTrue(model.rings[1].caption == "", "week ring caption is empty when the anchor is unknown")
    }

    // MARK: - Footer: "No data yet" before the first fetch, else "Updated HH:mm:ss".

    func testFooterText() {
        let noData = buildModel(queriedAt: nil)
        XCTAssertTrue(noData.footer == "No data yet", "footer is 'No data yet' when queried_at is nil")

        let withData = buildModel(queriedAt: queriedAtFixture, now: queriedAtUnixFixture)
        let expectedClock = Display.clockTime(Date(timeIntervalSince1970: TimeInterval(queriedAtUnixFixture)))
        XCTAssertTrue(
            withData.footer == "Updated \(expectedClock)",
            "footer is 'Updated HH:mm:ss' from queried_at when present")
    }

    // MARK: - ChartRenderer smoke test: series must actually change the
    // render, not just the grid. Counting non-transparent pixels for a
    // grid-only render vs. the same render with series added means this
    // fails if `drawSeries` were ever deleted (a grid-only render would
    // stay identical either way).

    func testChartRendererSeriesAffectsPixels() {
        let plotRect = CGRect(x: 0, y: 0, width: 264, height: 110)
        let series: [(color: NSColor, points: [CGPoint])] = [
            (color: .systemBlue, points: [CGPoint(x: 0, y: 80), CGPoint(x: 132, y: 40), CGPoint(x: 264, y: 10)]),
            (color: .systemTeal, points: [CGPoint(x: 0, y: 100), CGPoint(x: 132, y: 90), CGPoint(x: 264, y: 60)]),
        ]
        let tickLabels: [(x: CGFloat, label: String)] = [
            (x: 0, label: "Mon"), (x: 132, label: "Tue"), (x: 264, label: "Wed"),
        ]
        let gridColor = NSColor.black.withAlphaComponent(0.06)

        func nonClearPixelCount(_ model: ChartDrawModel) -> Int {
            guard
                let rep = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: 264, pixelsHigh: 110,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
                ), let context = NSGraphicsContext(bitmapImageRep: rep)
            else {
                XCTFail("chart bitmap context creation failed")
                return 0
            }

            let previous = NSGraphicsContext.current
            NSGraphicsContext.current = context
            ChartRenderer.draw(model, plotRect: plotRect, scale: 2)
            NSGraphicsContext.current = previous

            var count = 0
            for y in 0..<110 {
                for x in 0..<264 {
                    var pixel = [Int](repeating: 0, count: 4)
                    rep.getPixel(&pixel, atX: x, y: y)
                    if pixel[3] != 0 { count += 1 }
                }
            }
            return count
        }

        let gridOnlyModel = ChartDrawModel(gridColor: gridColor, series: [], tickLabels: tickLabels, yAxisLabels: [])
        let fullModel = ChartDrawModel(gridColor: gridColor, series: series, tickLabels: tickLabels, yAxisLabels: [])

        let gridOnlyCount = nonClearPixelCount(gridOnlyModel)
        let fullCount = nonClearPixelCount(fullModel)

        XCTAssertTrue(gridOnlyCount > 0, "grid-only render paints at least one non-transparent pixel")
        XCTAssertTrue(
            fullCount > gridOnlyCount,
            "adding series strictly increases the non-transparent pixel count over grid alone")
    }

    // Also exercise the placeholder path and a single-series chart, purely
    // for a no-crash smoke check via forceDraw's NSImage wrapper.
    func testChartRendererEmptySeriesSmokeTest() {
        let image = NSImage(size: CGSize(width: 264, height: 110), flipped: true) { rect in
            ChartRenderer.draw(
                ChartDrawModel(
                    gridColor: .black, series: [(color: .systemBlue, points: [])], tickLabels: [], yAxisLabels: []),
                plotRect: rect, scale: 2)
            return true
        }
        forceDraw(image)
        XCTAssertTrue(true, "ChartRenderer.draw with an empty series does not crash")
    }

    // MARK: - Hover legend labels: multi-series week chart names its rows;
    // the single-series session chart stays unlabeled.

    func testSeriesLegendLabels() {
        let sample = Sample(ts: 500, sessionStart: 400, session: 37, week: 12, fable: 3)
        let model = buildModel(trustworthy: true, sessionSamples: [sample], weekSamples: [sample])
        XCTAssertTrue(model.weekSeries.map(\.label) == ["week", "fable"], "week series carry legend labels")
        XCTAssertTrue(model.sessionSeries[0].label == nil, "single-series session chart has no label")
    }

    // MARK: - Numbers mode: rings and chart series follow prefs.numbers.

    func testUsedModeRingsAndSeries() {
        let sample = Sample(ts: 500, sessionStart: 400, session: 37, week: 12, fable: 3)
        let model = buildModel(
            session: metricFixture(key: MetricKey.session, usedPct: 37, secondsUntil: 9540),
            week: metricFixture(key: MetricKey.week, usedPct: 12, secondsUntil: 90000),
            fable: metricFixture(key: MetricKey.fable, usedPct: 3, secondsUntil: 90000),
            trustworthy: true, queriedAt: queriedAtFixture,
            sessionSamples: [sample], weekSamples: [sample],
            numbers: .used)
        XCTAssertTrue(model.rings[0].value == "37%", "used mode: session ring shows used pct")
        XCTAssertTrue(approxEqual(model.rings[0].fraction, 0.37), "used mode: session ring fills by used pct")
        XCTAssertTrue(model.rings[1].value == "12%", "used mode: week ring shows used pct")
        XCTAssertTrue(
            approxEqual(model.sessionSeries[0].points[0].value, 37), "used mode: session series plots used pct")
        XCTAssertTrue(approxEqual(model.weekSeries[1].points[0].value, 3), "used mode: fable series plots used pct")

        let remaining = buildModel(
            session: metricFixture(key: MetricKey.session, usedPct: 37, secondsUntil: 9540),
            trustworthy: true, queriedAt: queriedAtFixture,
            sessionSamples: [sample], numbers: .remaining)
        XCTAssertTrue(remaining.rings[0].value == "63%", "remaining mode: session ring shows remaining pct")
        XCTAssertTrue(
            approxEqual(remaining.sessionSeries[0].points[0].value, 63),
            "remaining mode: session series plots remaining pct")
    }
}
