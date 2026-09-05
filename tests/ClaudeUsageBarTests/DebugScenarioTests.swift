import AppKit
import ClaudeUsageBarCore
import XCTest

private let baseColor = NSColor.systemBlue
private let fableColor = NSColor.systemTeal

final class DebugScenarioTests: XCTestCase {
    private let now = queriedAtUnixFixture

    func testEveryScenarioBuildsWithoutTrapping() {
        for scenario in DebugScenario.allCases {
            let scene = scenario.scene(now: now, prefs: .standard)
            _ = scene.state
            _ = scene.sessionSamples
            _ = scene.weekSamples
        }
    }

    func testSceneIsDeterministic() {
        for scenario in DebugScenario.allCases {
            let a = scenario.scene(now: now, prefs: .standard)
            let b = scenario.scene(now: now, prefs: .standard)
            XCTAssertTrue(a.state == b.state, "\(scenario): same inputs produce equal state")
            XCTAssertTrue(
                a.sessionSamples == b.sessionSamples, "\(scenario): same inputs produce equal session samples")
            XCTAssertTrue(a.weekSamples == b.weekSamples, "\(scenario): same inputs produce equal week samples")
        }
    }

    /// Scenarios expected to come out of the real machine trusted, i.e.
    /// backed by an actual `.snapshot` fold rather than the untouched
    /// `.initial`/`.failure` states (`firstLaunch`/`fetchFailed`).
    private static let trustedScenarios: [DebugScenario] = [
        .fableAboveWeek, .weekAboveFable, .crossover, .coincident,
        .noSessionWithWeekHistory, .collectingHistory, .nearLimit,
    ]

    func testTrustedScenariosAreGenuinelyMachineProduced() {
        for scenario in Self.trustedScenarios {
            let scene = scenario.scene(now: now, prefs: .standard)
            XCTAssertTrue(scene.state.trust == .trusted, "\(scenario): trust == .trusted")

            // Every trusted scenario carries all three metrics: `session` is
            // one of the parser's REQUIRED_KEYS, so a snapshot missing it
            // fails `schema_ok` and could never reach `.trusted` at all.
            // `noSessionWithWeekHistory` is the one scenario whose session
            // has no RESET, so its anchor is legitimately nil there and
            // non-nil everywhere else.
            guard let session = scene.state.session else {
                XCTFail("\(scenario): expected a session metric")
                continue
            }
            let expectedSessionAnchor = PanelModel.resetAnchor(
                queriedAt: scene.state.queriedAt, secondsUntil: session.metric.reset?.secondsUntil)
            XCTAssertTrue(
                session.resetAnchor == expectedSessionAnchor,
                "\(scenario): session.resetAnchor matches PanelModel.resetAnchor")
            if scenario == .noSessionWithWeekHistory {
                XCTAssertTrue(session.resetAnchor == nil, "\(scenario): unanchored session has no reset anchor")
            } else {
                XCTAssertTrue(session.resetAnchor != nil, "\(scenario): session anchor is derivable")
            }

            guard let week = scene.state.week, let fable = scene.state.fable else {
                XCTFail("\(scenario): expected week and fable metrics")
                continue
            }
            let expectedWeekAnchor = PanelModel.resetAnchor(
                queriedAt: scene.state.queriedAt, secondsUntil: week.metric.reset?.secondsUntil)
            XCTAssertTrue(expectedWeekAnchor != nil, "\(scenario): week anchor is derivable")
            XCTAssertTrue(
                week.resetAnchor == expectedWeekAnchor, "\(scenario): week.resetAnchor matches PanelModel.resetAnchor")

            let expectedFableAnchor = PanelModel.resetAnchor(
                queriedAt: scene.state.queriedAt, secondsUntil: fable.metric.reset?.secondsUntil)
            XCTAssertTrue(expectedFableAnchor != nil, "\(scenario): fable anchor is derivable")
            XCTAssertTrue(
                fable.resetAnchor == expectedFableAnchor,
                "\(scenario): fable.resetAnchor matches PanelModel.resetAnchor")
        }
    }

    /// `weekSeries[1]` (fable) must plot strictly above `weekSeries[0]`
    /// (week) at every shared timestamp, in BOTH Numbers modes - the
    /// property that makes the scenario's name honest regardless of the
    /// user's current display mode.
    func testFableAboveWeekPlotsFableHigherInBothModes() {
        for mode in Display.NumberMode.allCases {
            var prefs = UsagePrefs.standard
            prefs.numbers = mode
            let scene = DebugScenario.fableAboveWeek.scene(now: now, prefs: prefs)
            let model = PanelModel.build(
                state: scene.state, sessionSamples: scene.sessionSamples, weekSamples: scene.weekSamples,
                baseColor: baseColor, fableColor: fableColor)

            let week = model.weekSeries[0].points
            let fable = model.weekSeries[1].points
            XCTAssertTrue(week.count == fable.count, "\(mode): week and fable series have the same point count")
            XCTAssertTrue(!week.isEmpty, "\(mode): series are non-empty")
            for (weekPoint, fablePoint) in zip(week, fable) {
                XCTAssertTrue(weekPoint.ts == fablePoint.ts, "\(mode): series share the same timestamps")
                XCTAssertTrue(
                    fablePoint.value > weekPoint.value,
                    "\(mode): fable (\(fablePoint.value)) plots above week (\(weekPoint.value)) at ts \(weekPoint.ts)")
            }
        }
    }

    /// Mirror of `testFableAboveWeekPlotsFableHigherInBothModes`: exercises
    /// `orderedUsedPct`'s `aboveIsFable == false` branch, which was
    /// otherwise completely unexercised - a swapped ternary there would have
    /// shipped green.
    func testWeekAboveFablePlotsWeekHigherInBothModes() {
        for mode in Display.NumberMode.allCases {
            var prefs = UsagePrefs.standard
            prefs.numbers = mode
            let scene = DebugScenario.weekAboveFable.scene(now: now, prefs: prefs)
            let model = PanelModel.build(
                state: scene.state, sessionSamples: scene.sessionSamples, weekSamples: scene.weekSamples,
                baseColor: baseColor, fableColor: fableColor)

            let week = model.weekSeries[0].points
            let fable = model.weekSeries[1].points
            XCTAssertTrue(week.count == fable.count, "\(mode): week and fable series have the same point count")
            XCTAssertTrue(!week.isEmpty, "\(mode): series are non-empty")
            for (weekPoint, fablePoint) in zip(week, fable) {
                XCTAssertTrue(weekPoint.ts == fablePoint.ts, "\(mode): series share the same timestamps")
                XCTAssertTrue(
                    weekPoint.value > fablePoint.value,
                    "\(mode): week (\(weekPoint.value)) plots above fable (\(fablePoint.value)) at ts \(weekPoint.ts)")
            }
        }
    }

    /// Runs in both Numbers modes: the code comment on `crossover`'s
    /// derivation claims the sign flip holds regardless of mode (negating
    /// both ramps negates the difference at every point without moving
    /// where it crosses zero), but the test previously only ever ran under
    /// `.standard` (`.remaining`) prefs, leaving that claim unverified in
    /// `.used` mode.
    func testCrossoverSignFlipsAtLeastOnce() {
        for mode in Display.NumberMode.allCases {
            var prefs = UsagePrefs.standard
            prefs.numbers = mode
            let scene = DebugScenario.crossover.scene(now: now, prefs: prefs)
            let model = PanelModel.build(
                state: scene.state, sessionSamples: scene.sessionSamples, weekSamples: scene.weekSamples,
                baseColor: baseColor, fableColor: fableColor)
            let week = model.weekSeries[0].points
            let fable = model.weekSeries[1].points
            XCTAssertTrue(
                week.count == fable.count && week.count > 1, "\(mode): crossover series are comparable and non-trivial")

            let signs = zip(week, fable).map { $0.1.value - $0.0.value }.map { $0 == 0 ? 0 : ($0 > 0 ? 1 : -1) }
            let flips = zip(signs, signs.dropFirst()).filter { a, b in a != 0 && b != 0 && a != b }.count
            XCTAssertTrue(flips >= 1, "\(mode): crossover: the sign of fable - week changes at least once")
        }
    }

    func testCoincidentIsEqualAtEveryTimestamp() {
        let scene = DebugScenario.coincident.scene(now: now, prefs: .standard)
        let model = PanelModel.build(
            state: scene.state, sessionSamples: scene.sessionSamples, weekSamples: scene.weekSamples,
            baseColor: baseColor, fableColor: fableColor)
        let week = model.weekSeries[0].points
        let fable = model.weekSeries[1].points
        XCTAssertTrue(week.count == fable.count && !week.isEmpty, "coincident series are comparable and non-empty")
        for (weekPoint, fablePoint) in zip(week, fable) {
            XCTAssertTrue(weekPoint.ts == fablePoint.ts, "coincident: series share the same timestamps")
            XCTAssertTrue(
                approxEqual(weekPoint.value, fablePoint.value),
                "coincident: week and fable are equal at ts \(weekPoint.ts)")
        }
    }

    /// The session metric is REPORTED but unanchored, which is what `/usage`
    /// actually emits between windows (the "resets ..." clause is dropped,
    /// the "Current session: N% used" line is not). That distinction is the
    /// whole point of the scenario: an absent metric would strip the session
    /// gauge from the menu bar and drop its countdown line entirely, whereas
    /// a present-but-unanchored one keeps the gauge and dashes the countdown
    /// out to `Display.unknownClockCountdown`.
    func testNoSessionWithWeekHistory() {
        let scene = DebugScenario.noSessionWithWeekHistory.scene(now: now, prefs: .standard)
        XCTAssertTrue(scene.state.session != nil, "noSessionWithWeekHistory: session metric is reported")
        XCTAssertTrue(scene.state.session?.resetAnchor == nil, "noSessionWithWeekHistory: session has no reset anchor")
        XCTAssertTrue(scene.sessionSamples.isEmpty, "noSessionWithWeekHistory: an unanchored session has no rows")
        XCTAssertTrue(scene.weekSamples.count >= 2, "noSessionWithWeekHistory: week history is populated")

        // All three gauges still draw in the menu bar.
        XCTAssertTrue(scene.state.metricStates.count == 3, "noSessionWithWeekHistory: all three gauges still draw")

        // The countdown cell keeps its session line, dashed out rather than
        // dropped - the symptom that exposed the original modelling error.
        let lines = Display.countdownLines(session: scene.state.session, week: scene.state.week)
        XCTAssertTrue(lines?.count == 2, "noSessionWithWeekHistory: both countdown lines are present")
        XCTAssertTrue(
            lines?.first == Display.unknownClockCountdown,
            "noSessionWithWeekHistory: session countdown dashes out to \(Display.unknownClockCountdown)")

        let model = PanelModel.build(
            state: scene.state, sessionSamples: scene.sessionSamples, weekSamples: scene.weekSamples,
            baseColor: baseColor, fableColor: fableColor)
        XCTAssertTrue(
            model.sessionPlaceholder == "No active session",
            "noSessionWithWeekHistory: session placeholder reads \"No active session\"")
        XCTAssertTrue(
            model.weekPlaceholder == nil, "noSessionWithWeekHistory: week chart has real data, no placeholder")
    }

    func testFirstLaunch() {
        let scene = DebugScenario.firstLaunch.scene(now: now, prefs: .standard)
        XCTAssertTrue(scene.state.trust == .loading, "firstLaunch: trust == .loading")

        let model = PanelModel.build(
            state: scene.state, sessionSamples: scene.sessionSamples, weekSamples: scene.weekSamples,
            baseColor: baseColor, fableColor: fableColor)
        XCTAssertTrue(model.sessionPlaceholder != nil, "firstLaunch: session placeholder is set")
        XCTAssertTrue(model.weekPlaceholder != nil, "firstLaunch: week placeholder is set")
    }

    /// `collectingHistory` is the scenario that actually provides the
    /// picture `firstLaunch`'s old (incorrect) doc comment claimed: a
    /// trusted state with all three metrics present but zero samples, so
    /// BOTH charts read "collecting history…" - unlike `firstLaunch`, whose
    /// nil session makes its session chart read "No active session" instead.
    func testCollectingHistoryShowsBothPlaceholders() {
        let scene = DebugScenario.collectingHistory.scene(now: now, prefs: .standard)
        XCTAssertTrue(scene.state.trust == .trusted, "collectingHistory: trust == .trusted")
        XCTAssertTrue(scene.state.session != nil, "collectingHistory: session metric is present")
        XCTAssertTrue(scene.sessionSamples.isEmpty, "collectingHistory: no session samples recorded yet")
        XCTAssertTrue(scene.weekSamples.isEmpty, "collectingHistory: no week samples recorded yet")

        let model = PanelModel.build(
            state: scene.state, sessionSamples: scene.sessionSamples, weekSamples: scene.weekSamples,
            baseColor: baseColor, fableColor: fableColor)
        XCTAssertTrue(
            model.sessionPlaceholder == "collecting history…",
            "collectingHistory: session chart reads \"collecting history…\"")
        XCTAssertTrue(
            model.weekPlaceholder == "collecting history…",
            "collectingHistory: week chart reads \"collecting history…\"")
    }

    func testFetchFailed() {
        let scene = DebugScenario.fetchFailed.scene(now: now, prefs: .standard)
        guard case .fetchFailed = scene.state.trust else {
            XCTFail("fetchFailed: expected trust == .fetchFailed, got \(scene.state.trust)")
            return
        }
    }

    func testDebugScenarioTitlesAreNonEmpty() {
        for scenario in DebugScenario.allCases {
            XCTAssertTrue(!scenario.title.isEmpty, "\(scenario): title is non-empty")
        }
    }
}
