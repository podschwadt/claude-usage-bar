import ClaudeUsageBarCore
import XCTest

/// Builds a trustworthy-shaped `UsageSnapshot` fixture. A `nil` metric
/// argument omits that key entirely (simulating a metric absent from
/// `/usage`, e.g. no active session); `sessionSecondsUntil`/`weekSecondsUntil`/
/// `fableSecondsUntil` feed each metric's `reset.seconds_until`, `nil` meaning
/// no reset is known. `fableSecondsUntil` defaults to the same value as
/// `weekSecondsUntil` (real `/usage` output reports the same reset for both,
/// see SnapshotDecodingTests's fixture).
private func snapshotFixture(
    session: Double?, week: Double?, fable: Double?,
    queriedAt: String? = queriedAtFixture,
    sessionSecondsUntil: Int? = 9540, weekSecondsUntil: Int? = 250800, fableSecondsUntil: Int? = 250800,
    ok: Bool = true, schemaOk: Bool = true, missingKeys: [String] = [],
    error: String? = nil, raw: String? = "raw /usage output", activity: Activity? = nil
) -> UsageSnapshot {
    var metrics: [String: Metric] = [:]
    if let session {
        metrics[MetricKey.session] = metricFixture(
            key: MetricKey.session, usedPct: session, secondsUntil: sessionSecondsUntil)
    }
    if let week {
        metrics[MetricKey.week] = metricFixture(key: MetricKey.week, usedPct: week, secondsUntil: weekSecondsUntil)
    }
    if let fable {
        metrics[MetricKey.fable] = metricFixture(key: MetricKey.fable, usedPct: fable, secondsUntil: fableSecondsUntil)
    }
    return UsageSnapshot(
        ok: ok, error: error, schemaOk: schemaOk, missingKeys: missingKeys,
        metrics: metrics, activity: activity, queriedAt: queriedAt, raw: raw)
}

/// Namespaces the fold helper below: an unqualified `run(...)` inside an
/// `XCTestCase` method resolves to `XCTestCase`'s own `run()` instance
/// method rather than a same-named free function, so it needs a home.
private enum Fold {
    /// Folds a sequence of events through the machine from `s0`, returning
    /// only the final state. Use `UsageMachine.transition` directly, per
    /// step, when a test needs to inspect effects along the way.
    static func run(_ s0: UsageState, _ events: [UsageEvent]) -> UsageState {
        events.reduce(s0) { state, event in UsageMachine.transition(state, event).state }
    }
}

/// Whether an `.armBoundaryPoll` effect is present, regardless of its anchor.
private func containsArmBoundaryPoll(_ effects: [UsageEffect]) -> Bool {
    effects.contains {
        if case .armBoundaryPoll = $0 { return true }
        return false
    }
}

/// Minimal seeded RNG: `SystemRandomNumberGenerator` cannot be seeded, and
/// the property loops below need reproducible failures. Every assertion
/// embeds its seed in the failure message so a failing run can be replayed.
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private func randomUsedPct(using rng: inout SplitMix64) -> Double {
    Double(rng.next() % 10001) / 100  // 0.00 ... 100.00
}

/// One seeded random walk of snapshot/tick events (clock strictly advancing),
/// shared by the invariant tests below so each stresses the same trajectory.
private func randomWalkEvents(seed: UInt64, count: Int) -> [UsageEvent] {
    var rng = SplitMix64(seed: seed)
    var now = queriedAtUnixFixture
    var events: [UsageEvent] = []
    for _ in 0..<count {
        now += Int(rng.next() % 120) + 1
        if rng.next() % 4 == 0 {
            events.append(.tick(now: now))
        } else {
            let snap = snapshotFixture(
                session: randomUsedPct(using: &rng), week: randomUsedPct(using: &rng),
                fable: randomUsedPct(using: &rng),
                sessionSecondsUntil: Int(rng.next() % 20000) - 5000, weekSecondsUntil: Int(rng.next() % 300000) - 50000)
            events.append(.snapshot(snap, now: now))
        }
    }
    return events
}

final class UsageMachineTests: XCTestCase {
    // MARK: - Table-driven: the fully-specified transitions (T4/T5/T6),
    // asserted as whole-Step equality per the plan's test strategy.

    func testTableDrivenTransitions() {
        let t0 = queriedAtUnixFixture
        let loading = UsageState.initial(now: t0)

        let cases: [(name: String, state: UsageState, event: UsageEvent, expected: Step)] = [
            (
                name: "historyOpened sets history available, no effects",
                state: loading, event: .historyOpened,
                expected: Step(
                    state: {
                        var s = loading; s.history = .available; return s
                    }(), effects: [])
            ),
            (
                name: "historyFailed sets history unavailable, no effects",
                state: loading, event: .historyFailed(message: "disk full"),
                expected: Step(
                    state: {
                        var s = loading; s.history = .unavailable(message: "disk full"); return s
                    }(),
                    effects: [])
            ),
            (
                name: "tick while untrusted only advances now",
                state: loading, event: .tick(now: t0 + 60),
                expected: Step(
                    state: {
                        var s = loading; s.now = t0 + 60; return s
                    }(), effects: [])
            ),
        ]

        for testCase in cases {
            let step = UsageMachine.transition(testCase.state, testCase.event)
            XCTAssertTrue(
                step == testCase.expected,
                "\(testCase.name): expected \(testCase.expected.state.debugDescription), "
                    + "got \(step.state.debugDescription), effects \(step.effects)")
        }
    }

    // MARK: - First snapshot: no record before history opens.

    func testFirstSnapshotNoRecordWhileHistoryOpening() {
        let state0 = UsageState.initial(now: queriedAtUnixFixture)
        let snap = snapshotFixture(session: 10, week: 10, fable: 10)
        let step = UsageMachine.transition(state0, .snapshot(snap, now: queriedAtUnixFixture))

        XCTAssertTrue(
            !step.effects.contains {
                if case .record = $0 { return true }; return false
            },
            "no record while history is still .opening")
        XCTAssertTrue(step.state.history == .opening, "history untouched by a snapshot event")
    }

    // MARK: - Record gate permutations.

    func testRecordGatePermutations() {
        let now = queriedAtUnixFixture
        let state = Fold.run(UsageState.initial(now: now), [.historyOpened])
        XCTAssertTrue(state.history == .available)

        let untrustworthy = snapshotFixture(session: 10, week: 10, fable: 10, ok: false, schemaOk: false, error: "boom")
        let untrustworthyStep = UsageMachine.transition(state, .snapshot(untrustworthy, now: now))
        XCTAssertTrue(
            !untrustworthyStep.effects.contains {
                if case .record = $0 { return true }; return false
            },
            "untrustworthy snapshot never records")

        let missingFable = snapshotFixture(session: 10, week: 10, fable: nil)
        let missingFableStep = UsageMachine.transition(state, .snapshot(missingFable, now: now))
        XCTAssertTrue(
            !missingFableStep.effects.contains {
                if case .record = $0 { return true }; return false
            },
            "missing fable metric blocks the record gate")

        let nilSessionStart = snapshotFixture(session: 10, week: 10, fable: 10, sessionSecondsUntil: nil)
        let nilSessionStartStep = UsageMachine.transition(state, .snapshot(nilSessionStart, now: now))
        XCTAssertTrue(
            !nilSessionStartStep.effects.contains {
                if case .record = $0 { return true }; return false
            },
            "nil sessionStart blocks the record gate")

        let allPresent = snapshotFixture(session: 10, week: 20, fable: 30)
        let openingState = UsageState.initial(now: now)
        let openingStep = UsageMachine.transition(openingState, .snapshot(allPresent, now: now))
        XCTAssertTrue(
            !openingStep.effects.contains {
                if case .record = $0 { return true }; return false
            },
            "no record while history is still .opening")

        let recordStep = UsageMachine.transition(state, .snapshot(allPresent, now: now))
        let expectedSessionStart = PanelModel.sessionStart(queriedAt: queriedAtFixture, secondsUntil: 9540)!
        let expectedSample = Sample(ts: now, sessionStart: expectedSessionStart, session: 10, week: 20, fable: 30)
        XCTAssertTrue(recordStep.effects.contains(.record(expectedSample)), "record gate open records the exact sample")
    }

    // MARK: - Stale-snapshot no-loop.

    func testStaleSnapshotPollsOnceThenSilent() {
        let now = queriedAtUnixFixture
        let staleSnap = snapshotFixture(session: 10, week: 10, fable: 10, sessionSecondsUntil: -30)
        var state = UsageState.initial(now: now)
        var step = UsageMachine.transition(state, .snapshot(staleSnap, now: now))
        XCTAssertTrue(step.effects.contains(.pollNow), "an already-expired snapshot polls once on arrival")
        state = step.state

        step = UsageMachine.transition(state, .snapshot(staleSnap, now: now))
        XCTAssertTrue(!step.effects.contains(.pollNow), "an identical re-fetch of the same stale anchor stays silent")
    }

    // MARK: - Week analog of the stale-snapshot no-loop: week expiry polls
    // through the same latch, independently of session.

    func testStaleWeekSnapshotPollsOnceThenSilent() {
        let now = queriedAtUnixFixture
        let staleSnap = snapshotFixture(session: 10, week: 10, fable: 10, weekSecondsUntil: -30)
        var state = UsageState.initial(now: now)
        var step = UsageMachine.transition(state, .snapshot(staleSnap, now: now))
        XCTAssertTrue(step.effects.contains(.pollNow), "an already-expired week snapshot polls once on arrival")
        XCTAssertNotNil(step.state.weekExpiryPolled, "the week expiry latch is set once polled")
        state = step.state

        step = UsageMachine.transition(state, .snapshot(staleSnap, now: now))
        XCTAssertTrue(
            !step.effects.contains(.pollNow), "an identical re-fetch of the same stale week anchor stays silent")
    }

    // MARK: - Trust flap: expiry latches persist through an untrustworthy gap.

    func testTrustFlapPreservesExpiryLatches() {
        let now = queriedAtUnixFixture
        let staleSnap = snapshotFixture(
            session: 10, week: 10, fable: 10, sessionSecondsUntil: -30, weekSecondsUntil: -30)
        var state = UsageState.initial(now: now)
        var step = UsageMachine.transition(state, .snapshot(staleSnap, now: now))
        state = step.state
        let sessionLatch = state.sessionExpiryPolled
        let weekLatch = state.weekExpiryPolled
        XCTAssertNotNil(sessionLatch, "setup: the stale session anchor sets the session expiry latch")
        XCTAssertNotNil(weekLatch, "setup: the stale week anchor sets the week expiry latch")

        let failure = UsageSnapshot.failure("network error")
        step = UsageMachine.transition(state, .snapshot(failure, now: now))
        XCTAssertNil(step.state.session, "an untrustworthy snapshot clears the session metric")
        XCTAssertNil(step.state.week, "an untrustworthy snapshot clears the week metric")
        XCTAssertNil(step.state.fable, "an untrustworthy snapshot clears the fable metric")
        XCTAssertTrue(
            step.state.sessionExpiryPolled == sessionLatch,
            "the session expiry latch survives an untrustworthy gap unchanged")
        XCTAssertTrue(
            step.state.weekExpiryPolled == weekLatch, "the week expiry latch survives an untrustworthy gap unchanged")
        state = step.state

        step = UsageMachine.transition(state, .snapshot(staleSnap, now: now))
        XCTAssertTrue(
            step.state.sessionExpiryPolled == sessionLatch,
            "recovering to the same stale anchor keeps the same latch, no double pollNow")
        XCTAssertTrue(!step.effects.contains(.pollNow), "the recovered anchor was already polled before the flap")
    }

    // MARK: - Tick recompute.

    func testTickRecomputesRemainingSeconds() {
        let now = queriedAtUnixFixture
        let snap = snapshotFixture(session: 10, week: 10, fable: 10, sessionSecondsUntil: 9540)
        let state = Fold.run(UsageState.initial(now: now), [.snapshot(snap, now: now)])
        let anchor = state.session!.resetAnchor!
        XCTAssertTrue(state.session?.remainingSeconds == 9540, "remainingSeconds fresh off a snapshot")

        let step = UsageMachine.transition(state, .tick(now: now + 40))
        XCTAssertTrue(
            step.state.session?.remainingSeconds == anchor - (now + 40),
            "a tick recomputes remainingSeconds from the stored anchor and the tick's own now")
        XCTAssertTrue(step.state.now == now + 40, "now advances with the tick")
    }

    // MARK: - Tick-driven expiry: a live anchor crossed by a later tick
    // (not a fresh snapshot) latches pollNow exactly once.

    func testTickPastLiveAnchorFiresPollNowOnceThenSilent() {
        let t0 = queriedAtUnixFixture
        let secondsUntil = 100
        let snap = snapshotFixture(session: 95, week: 10, fable: 10, sessionSecondsUntil: secondsUntil)
        var state = Fold.run(UsageState.initial(now: t0), [.historyOpened])
        var step = UsageMachine.transition(state, .snapshot(snap, now: t0))
        state = step.state
        XCTAssertTrue(!step.effects.contains(.pollNow), "a live (not yet expired) anchor does not poll on arrival")

        let expiredNow = t0 + secondsUntil + 50
        step = UsageMachine.transition(state, .tick(now: expiredNow))
        XCTAssertTrue(step.effects == [.pollNow], "a tick crossing the anchor fires exactly one pollNow")
        state = step.state
        XCTAssertNotNil(state.sessionExpiryPolled, "the session latch is set once polled")

        step = UsageMachine.transition(state, .tick(now: expiredNow + 30))
        XCTAssertTrue(step.effects.isEmpty, "further ticks against the same expired anchor stay silent")
    }

    // MARK: - Tick-driven expiry, week variant: a live week anchor crossed by
    // a later tick (session left live throughout) latches pollNow exactly
    // once, independently of the session branch above.

    func testTickPastLiveWeekAnchorFiresPollNowOnceThenSilent() {
        let t0 = queriedAtUnixFixture
        let weekSecondsUntil = 200
        let snap = snapshotFixture(session: 10, week: 95, fable: 10, weekSecondsUntil: weekSecondsUntil)
        var state = Fold.run(UsageState.initial(now: t0), [.historyOpened])
        var step = UsageMachine.transition(state, .snapshot(snap, now: t0))
        state = step.state
        XCTAssertTrue(!step.effects.contains(.pollNow), "a live (not yet expired) week anchor does not poll on arrival")

        let expiredNow = t0 + weekSecondsUntil + 50
        step = UsageMachine.transition(state, .tick(now: expiredNow))
        XCTAssertTrue(step.effects == [.pollNow], "a tick crossing the week anchor fires exactly one pollNow")
        state = step.state
        XCTAssertNotNil(state.weekExpiryPolled, "the week latch is set once polled")

        step = UsageMachine.transition(state, .tick(now: expiredNow + 30))
        XCTAssertTrue(step.effects.isEmpty, "further ticks against the same expired week anchor stay silent")
    }

    // MARK: - Fable reset countdown (regression: /usage DOES emit
    // week_fable.reset.seconds_until; SnapshotDecodingTests pins it).

    func testFableAnchoredCountdownAndNoPollLatch() {
        let now = queriedAtUnixFixture
        let fableSecondsUntil = 5000
        let snap = snapshotFixture(session: 10, week: 10, fable: 10, fableSecondsUntil: fableSecondsUntil)
        var state = Fold.run(UsageState.initial(now: now), [.historyOpened])
        var step = UsageMachine.transition(state, .snapshot(snap, now: now))
        state = step.state

        let anchor = state.fable?.resetAnchor
        XCTAssertNotNil(anchor, "a fable metric with a reset yields a non-nil resetAnchor")
        XCTAssertTrue(
            state.fable?.remainingSeconds == anchor.map { $0 - now },
            "fable's remainingSeconds is anchor - now right off the snapshot")

        step = UsageMachine.transition(state, .tick(now: now + 40))
        state = step.state
        XCTAssertTrue(state.fable?.resetAnchor == anchor, "a tick does not move fable's anchor")
        XCTAssertTrue(
            state.fable?.remainingSeconds == anchor.map { $0 - (now + 40) },
            "a tick recomputes fable's remainingSeconds too, not just session/week")

        // A fable-only expiry (already past its own anchor) must never fire
        // pollNow: only session/week expiry triggers a re-poll, deliberately
        // not extended to fable.
        let expiredFableSnap = snapshotFixture(session: 10, week: 10, fable: 10, fableSecondsUntil: -30)
        let freshState = Fold.run(UsageState.initial(now: now), [.historyOpened])
        let expiredStep = UsageMachine.transition(freshState, .snapshot(expiredFableSnap, now: now))
        XCTAssertTrue(
            !expiredStep.effects.contains(.pollNow),
            "an already-expired fable anchor alone never fires pollNow")
        let tickStep = UsageMachine.transition(expiredStep.state, .tick(now: now + 60))
        XCTAssertTrue(
            !tickStep.effects.contains(.pollNow),
            "ticking past a fable-only expiry still never fires pollNow")
    }

    // MARK: - History availability.

    func testHistoryAvailability() {
        let opening = UsageState.initial(now: 1000)
        XCTAssertTrue(opening.history == .opening)

        let available = Fold.run(opening, [.historyOpened])
        XCTAssertTrue(available.history == .available)

        let unavailable = Fold.run(available, [.historyFailed(message: "disk full")])
        XCTAssertTrue(unavailable.history == .unavailable(message: "disk full"))
    }

    // MARK: - Whole-Step contractual effect order: record, then
    // armBoundaryPoll, then pollNow.

    func testWholeStepEffectOrderRecordThenArmBoundaryPollThenPollNow() {
        let t0 = queriedAtUnixFixture
        let opened = Fold.run(UsageState.initial(now: t0), [.historyOpened])

        // A snapshot that completes the record gate (all three metrics
        // present, a derivable session identity, history available), is the
        // first ever to report the week anchor (arming the boundary poll),
        // and arrives with an already-expired session anchor (latching a
        // pollNow) must perform all three in that order: the interpreter's
        // `.record` write and the `.pollNow` refetch share the serial
        // history queue (see `dispatch`'s doc comment), so the order is
        // contractual, not incidental.
        let snap = snapshotFixture(session: 95, week: 10, fable: 10, sessionSecondsUntil: -30)
        let step = UsageMachine.transition(opened, .snapshot(snap, now: t0))

        func anchoredExpected(_ metric: Metric) -> MetricState {
            let anchor = PanelModel.resetAnchor(queriedAt: queriedAtFixture, secondsUntil: metric.reset?.secondsUntil)
            return MetricState(metric: metric, resetAnchor: anchor, remainingSeconds: anchor.map { $0 - t0 })
        }

        let expectedSession = anchoredExpected(snap.metric(MetricKey.session)!)
        let expectedWeek = anchoredExpected(snap.metric(MetricKey.week)!)
        let expectedFable = anchoredExpected(snap.metric(MetricKey.fable)!)
        let expectedSessionStart = PanelModel.sessionStart(queriedAt: queriedAtFixture, secondsUntil: -30)!
        let expectedSample = Sample(ts: t0, sessionStart: expectedSessionStart, session: 95, week: 10, fable: 10)

        var expectedState = opened
        expectedState.trust = .trusted
        expectedState.session = expectedSession
        expectedState.week = expectedWeek
        expectedState.fable = expectedFable
        expectedState.queriedAt = queriedAtFixture
        expectedState.queriedAtUnix = queriedAtUnixFixture
        expectedState.activity = nil
        expectedState.raw = "raw /usage output"
        expectedState.sessionExpiryPolled = expectedSession.resetAnchor
        expectedState.weekExpiryPolled = nil
        expectedState.boundaryPollArmed = expectedWeek.resetAnchor
        expectedState.now = t0

        // The session anchor is already past `t0`, so the week anchor is the
        // only future one, and `boundaryPollArmed` starts nil (`opened` never
        // saw a snapshot), so any future anchor arms it.
        let expected = Step(
            state: expectedState,
            effects: [.record(expectedSample), .armBoundaryPoll(at: expectedWeek.resetAnchor!), .pollNow])

        XCTAssertEqual(
            step, expected,
            "expected \(expected.state.debugDescription) effects \(expected.effects), "
                + "got \(step.state.debugDescription) effects \(step.effects)")
    }

    // MARK: - Latch re-arm: a different already-expired anchor polls again.

    func testExpiredAnchorLatchReArmsForADifferentAnchor() {
        let now = queriedAtUnixFixture
        let anchorASnap = snapshotFixture(session: 10, week: 10, fable: 10, sessionSecondsUntil: -30)
        var state = UsageState.initial(now: now)
        var step = UsageMachine.transition(state, .snapshot(anchorASnap, now: now))
        XCTAssertTrue(step.effects.contains(.pollNow), "anchor A's expiry polls once on arrival")
        state = step.state
        XCTAssertNotNil(state.sessionExpiryPolled, "the latch is set to anchor A")

        // Same anchor again: must stay silent (existing behavior, see
        // testStaleSnapshotPollsOnceThenSilent).
        step = UsageMachine.transition(state, .snapshot(anchorASnap, now: now))
        XCTAssertTrue(!step.effects.contains(.pollNow), "a repeat of the same expired anchor stays silent")
        state = step.state

        // A DIFFERENT already-expired anchor (session secondsUntil changed
        // from -30 to -9999) must re-arm the latch and poll again: the old
        // latch matches anchor A, not this new anchor B.
        let anchorBSnap = snapshotFixture(session: 10, week: 10, fable: 10, sessionSecondsUntil: -9999)
        step = UsageMachine.transition(state, .snapshot(anchorBSnap, now: now))
        XCTAssertTrue(step.effects.contains(.pollNow), "a different already-expired anchor polls again")
        XCTAssertTrue(
            state.sessionExpiryPolled != step.state.sessionExpiryPolled,
            "the latch moves from anchor A to anchor B")
    }

    // MARK: - armBoundaryPoll arming: fires on the first trusted snapshot
    // and whenever the earliest upcoming session/week anchor changes; silent
    // when it does not, or when nothing is upcoming.

    func testArmBoundaryPollEmittedOnFirstTrustedSnapshot() {
        let t0 = queriedAtUnixFixture
        let opened = Fold.run(UsageState.initial(now: t0), [.historyOpened])
        // sessionSecondsUntil (9540) is nearer than the default weekSecondsUntil
        // (250800), so the session anchor is the earliest upcoming reset.
        let snap = snapshotFixture(session: 10, week: 10, fable: 10)
        let step = UsageMachine.transition(opened, .snapshot(snap, now: t0))
        let sessionAnchor = PanelModel.resetAnchor(queriedAt: queriedAtFixture, secondsUntil: 9540)!
        XCTAssertTrue(
            step.effects.contains(.armBoundaryPoll(at: sessionAnchor)),
            "the first trusted snapshot arms the boundary poll at the earliest upcoming anchor")
        XCTAssertTrue(
            step.state.boundaryPollArmed == sessionAnchor,
            "the latch records the anchor just requested for arming")
    }

    func testArmBoundaryPollEmittedWhenEarliestAnchorChanges() {
        let t0 = queriedAtUnixFixture
        let opened = Fold.run(UsageState.initial(now: t0), [.historyOpened])
        let firstSnap = snapshotFixture(session: 10, week: 10, fable: 10, sessionSecondsUntil: 9540)
        let state = UsageMachine.transition(opened, .snapshot(firstSnap, now: t0)).state
        let firstAnchor = state.boundaryPollArmed
        XCTAssertNotNil(firstAnchor, "setup: the first snapshot latches an armed anchor")

        // A later poll reporting a shorter session countdown moves the
        // earliest anchor earlier: the boundary poll must re-arm to match.
        let secondSnap = snapshotFixture(session: 10, week: 10, fable: 10, sessionSecondsUntil: 4000)
        let step = UsageMachine.transition(state, .snapshot(secondSnap, now: t0))
        let newAnchor = PanelModel.resetAnchor(queriedAt: queriedAtFixture, secondsUntil: 4000)!
        XCTAssertTrue(
            step.effects.contains(.armBoundaryPoll(at: newAnchor)),
            "a changed earliest anchor re-arms the boundary poll")
        XCTAssertTrue(
            step.state.boundaryPollArmed == newAnchor && newAnchor != firstAnchor,
            "the latch moves from the first armed anchor to the new one")
    }

    func testArmBoundaryPollNotEmittedWhenAnchorsUnchanged() {
        let t0 = queriedAtUnixFixture
        let opened = Fold.run(UsageState.initial(now: t0), [.historyOpened])
        let snap = snapshotFixture(session: 10, week: 10, fable: 10)
        let state = UsageMachine.transition(opened, .snapshot(snap, now: t0)).state
        let armedAnchor = state.boundaryPollArmed
        XCTAssertNotNil(armedAnchor, "setup: the first snapshot latches an armed anchor")

        // An identical re-fetch reports the same anchors: nothing moved, no re-arm.
        let step = UsageMachine.transition(state, .snapshot(snap, now: t0))
        XCTAssertTrue(
            !containsArmBoundaryPoll(step.effects), "an unchanged earliest anchor does not re-arm the boundary poll")
        XCTAssertTrue(
            step.state.boundaryPollArmed == armedAnchor, "the latch is left as-is when the earliest anchor repeats")
    }

    func testArmBoundaryPollNotEmittedWhenNoAnchorIsFuture() {
        let t0 = queriedAtUnixFixture
        let state = Fold.run(UsageState.initial(now: t0), [.historyOpened])
        let snap = snapshotFixture(session: 10, week: 10, fable: 10, sessionSecondsUntil: -30, weekSecondsUntil: -30)
        let step = UsageMachine.transition(state, .snapshot(snap, now: t0))
        XCTAssertTrue(
            !containsArmBoundaryPoll(step.effects), "no anchor upcoming means nothing to arm the boundary poll against")
        XCTAssertTrue(
            step.state.boundaryPollArmed == nil, "no future anchor leaves the latch at its unset starting value")
    }

    // MARK: - Only a trusted snapshot ever writes the arm latch: `.tick`
    // recomputes countdowns and can itself fire `.pollNow` through the
    // separate tick-latch fallback, but never arms or re-arms the boundary
    // poll, even crossing an anchor.

    func testTickNeverEmitsArmBoundaryPoll() {
        let t0 = queriedAtUnixFixture
        let opened = Fold.run(UsageState.initial(now: t0), [.historyOpened])
        let snap = snapshotFixture(session: 10, week: 10, fable: 10, sessionSecondsUntil: 50)
        let state = UsageMachine.transition(opened, .snapshot(snap, now: t0)).state
        let armedAnchor = state.boundaryPollArmed
        XCTAssertNotNil(armedAnchor, "setup: the snapshot arms the boundary poll")

        let step = UsageMachine.transition(state, .tick(now: t0 + 100))
        XCTAssertTrue(!containsArmBoundaryPoll(step.effects), "a tick crossing the armed anchor never arms it")
        XCTAssertTrue(step.state.boundaryPollArmed == armedAnchor, "a tick leaves the arm latch unchanged")
    }

    // MARK: - An untrustworthy snapshot must not re-arm or clear the latch:
    // same rule as the expiry latches (testTrustFlapPreservesExpiryLatches).

    func testUntrustedSnapshotLeavesBoundaryPollArmedUnchanged() {
        let t0 = queriedAtUnixFixture
        let opened = Fold.run(UsageState.initial(now: t0), [.historyOpened])
        let snap = snapshotFixture(session: 10, week: 10, fable: 10, sessionSecondsUntil: 50)
        let state = UsageMachine.transition(opened, .snapshot(snap, now: t0)).state
        let armedAnchor = state.boundaryPollArmed
        XCTAssertNotNil(armedAnchor, "setup: the trusted snapshot arms the boundary poll")

        let failure = UsageSnapshot.failure("network error")
        let step = UsageMachine.transition(state, .snapshot(failure, now: t0))
        XCTAssertTrue(
            step.state.boundaryPollArmed == armedAnchor, "an untrustworthy snapshot leaves the arm latch unchanged")
    }

    // MARK: - Rollover freeze: a session absent from a trusted snapshot but
    // present in the prior state carries the prior MetricState forward
    // (remainingSeconds recomputed, resetAnchor and metric unchanged)
    // instead of going nil; a later snapshot reporting a session unfreezes.

    func testMissingSessionCarriesPriorStateForwardWithoutRecording() {
        let t0 = queriedAtUnixFixture
        let opened = Fold.run(UsageState.initial(now: t0), [.historyOpened])
        let snap = snapshotFixture(session: 42, week: 10, fable: 10, sessionSecondsUntil: 60)
        let state = UsageMachine.transition(opened, .snapshot(snap, now: t0)).state
        let anchor = state.session!.resetAnchor!
        let metric = state.session!.metric

        // /usage reports no session key between 5h windows.
        let laterNow = t0 + 200
        let gapSnap = snapshotFixture(session: nil, week: 10, fable: 10)
        let step = UsageMachine.transition(state, .snapshot(gapSnap, now: laterNow))

        XCTAssertTrue(step.state.session?.metric == metric, "the frozen session's metric is unchanged")
        XCTAssertTrue(step.state.session?.resetAnchor == anchor, "the frozen session's resetAnchor is unchanged")
        XCTAssertTrue(
            step.state.session?.remainingSeconds == anchor - laterNow,
            "the frozen session's remainingSeconds recomputes against the new snapshot's now")
        XCTAssertTrue(
            !step.effects.contains {
                if case .record = $0 { return true }; return false
            },
            "a frozen session has no derivable sessionStart, so it never records a sample")
    }

    func testFreezeUnfreezesOnANewSession() {
        let t0 = queriedAtUnixFixture
        let opened = Fold.run(UsageState.initial(now: t0), [.historyOpened])
        let snap = snapshotFixture(session: 42, week: 10, fable: 10, sessionSecondsUntil: 60)
        var state = UsageMachine.transition(opened, .snapshot(snap, now: t0)).state

        let gapSnap = snapshotFixture(session: nil, week: 10, fable: 10)
        state = UsageMachine.transition(state, .snapshot(gapSnap, now: t0 + 200)).state
        XCTAssertTrue((state.session?.remainingSeconds ?? 0) <= 0, "setup: the session is frozen past its anchor")

        let freshSnap = snapshotFixture(session: 5, week: 10, fable: 10, sessionSecondsUntil: 18000)
        let step = UsageMachine.transition(state, .snapshot(freshSnap, now: t0 + 210))
        let expectedAnchor = PanelModel.resetAnchor(queriedAt: queriedAtFixture, secondsUntil: 18000)
        XCTAssertTrue(step.state.session?.metric.usedPct == 5, "a new session snapshot replaces the frozen metric")
        XCTAssertTrue(
            step.state.session?.resetAnchor == expectedAnchor, "a new session snapshot replaces the frozen anchor")
    }

    // MARK: - Re-arm after a boundary fire: the latch names the last anchor
    // REQUESTED for arming, so when a fire's re-fetch lands past the armed
    // session anchor (freezing the session), the week anchor becomes the
    // earliest future anchor, differs from the latch, and re-arms in the
    // same step.

    func testBoundaryFireLeavesLatchStaleSoTheWeekAnchorReArms() {
        let t0 = queriedAtUnixFixture
        let opened = Fold.run(UsageState.initial(now: t0), [.historyOpened])

        // Snapshot A: the session anchor S is nearer than the week anchor W,
        // so A arms the latch at S.
        let snapA = snapshotFixture(session: 95, week: 10, fable: 10, sessionSecondsUntil: 50, weekSecondsUntil: 9000)
        let afterA = UsageMachine.transition(opened, .snapshot(snapA, now: t0))
        let s = PanelModel.resetAnchor(queriedAt: queriedAtFixture, secondsUntil: 50)!
        let w = PanelModel.resetAnchor(queriedAt: queriedAtFixture, secondsUntil: 9000)!
        XCTAssertTrue(afterA.state.boundaryPollArmed == s, "setup: the nearer session anchor arms the latch")

        // Snapshot B: the boundary fire's re-fetch, landing after S, reports
        // no session (freeze) and the same W. Pin the whole effects array:
        // the frozen session's now-negative remainingSeconds also feeds
        // `pollDecision` once — accepted, bounded (the session expiry latch
        // below stops it repeating) — alongside the re-arm.
        let laterNow = t0 + 200
        let snapB = snapshotFixture(session: nil, week: 10, fable: 10, weekSecondsUntil: 9000)
        let stepB = UsageMachine.transition(afterA.state, .snapshot(snapB, now: laterNow))

        XCTAssertTrue(
            stepB.effects == [.armBoundaryPoll(at: w), .pollNow],
            "a boundary fire that freezes the session re-arms against the week anchor and polls once "
                + "for the frozen session's own expiry, got \(stepB.effects)")
        XCTAssertTrue(stepB.state.boundaryPollArmed == w, "the latch moves from the session anchor to the week anchor")

        // A follow-up gap snapshot (same shape, a little later, W still
        // future) is silent: the session expiry latch already covers S, and
        // the arm latch already covers W.
        let gapNow = t0 + 210
        let snapC = snapshotFixture(session: nil, week: 10, fable: 10, weekSecondsUntil: 9000)
        let stepC = UsageMachine.transition(stepB.state, .snapshot(snapC, now: gapNow))
        XCTAssertTrue(stepC.effects.isEmpty, "the follow-up gap snapshot emits nothing, got \(stepC.effects)")
    }

    // MARK: - setPref: runs the tick core (remainingSeconds recompute)
    // before applying the pref, then always appends persistPref.

    func testSetPrefRunsTickCoreThenAppliesPrefThenPersists() {
        let t0 = queriedAtUnixFixture
        let opened = Fold.run(UsageState.initial(now: t0), [.historyOpened])
        let snap = snapshotFixture(session: 10, week: 10, fable: 10, sessionSecondsUntil: 9540)
        let state = UsageMachine.transition(opened, .snapshot(snap, now: t0)).state
        let anchor = state.session!.resetAnchor!

        let laterNow = t0 + 40
        let pref = UsagePref.layout(.rows)
        let step = UsageMachine.transition(state, .setPref(pref, now: laterNow))

        XCTAssertTrue(
            step.state.session?.remainingSeconds == anchor - laterNow,
            "setPref runs the tick core first, recomputing remainingSeconds against the event's now")
        XCTAssertTrue(step.state.prefs.layout == .rows, "the pref is applied on top of the ticked state")
        XCTAssertTrue(step.state.now == laterNow, "now advances with the setPref event")
        XCTAssertTrue(
            step.effects == [.persistPref(pref)], "a non-interval pref persists without rescheduling the poll")
    }

    // MARK: - Whole-Step equality for a representative setPref, pinning the
    // ticked session/week/fable recompute alongside the applied pref.

    func testSetPrefWholeStepEquality() {
        let t0 = queriedAtUnixFixture
        let opened = Fold.run(UsageState.initial(now: t0), [.historyOpened])
        let snap = snapshotFixture(session: 10, week: 10, fable: 10, sessionSecondsUntil: 9540)
        let state = UsageMachine.transition(opened, .snapshot(snap, now: t0)).state

        let laterNow = t0 + 40
        let pref = UsagePref.barColor(.purple)
        let step = UsageMachine.transition(state, .setPref(pref, now: laterNow))

        func recomputed(_ metricState: MetricState) -> MetricState {
            MetricState(
                metric: metricState.metric, resetAnchor: metricState.resetAnchor,
                remainingSeconds: metricState.resetAnchor.map { $0 - laterNow })
        }

        var expectedState = state
        expectedState.session = recomputed(state.session!)
        expectedState.week = recomputed(state.week!)
        expectedState.fable = recomputed(state.fable!)
        expectedState.now = laterNow
        expectedState.prefs.barColor = .purple

        let expected = Step(state: expectedState, effects: [.persistPref(pref)])
        XCTAssertEqual(
            step, expected,
            "expected \(expected.state.debugDescription) effects \(expected.effects), "
                + "got \(step.state.debugDescription) effects \(step.effects)")
    }

    // MARK: - reschedulePoll fires only for a CHANGED refreshInterval.

    func testSetPrefRefreshIntervalChangedEmitsReschedulePoll() {
        let t0 = queriedAtUnixFixture
        let state = UsageState.initial(now: t0)
        XCTAssertTrue(state.prefs.refreshInterval == 60, "setup: standard prefs default to a 60s interval")

        let pref = UsagePref.refreshInterval(300)
        let step = UsageMachine.transition(state, .setPref(pref, now: t0))

        XCTAssertTrue(step.state.prefs.refreshInterval == 300, "the new interval is applied")
        XCTAssertTrue(
            step.effects == [.persistPref(pref), .reschedulePoll(seconds: 300)],
            "a changed interval persists then reschedules the poll, in that order, got \(step.effects)")
    }

    func testSetPrefRefreshIntervalUnchangedSkipsReschedulePoll() {
        let t0 = queriedAtUnixFixture
        let state = UsageState.initial(now: t0)
        let pref = UsagePref.refreshInterval(state.prefs.refreshInterval)
        let step = UsageMachine.transition(state, .setPref(pref, now: t0))
        XCTAssertTrue(
            step.effects == [.persistPref(pref)],
            "setting the interval to its current value never reschedules the poll, got \(step.effects)")
    }

    func testSetPrefNonIntervalPrefsNeverReschedulePoll() {
        let t0 = queriedAtUnixFixture
        let state = UsageState.initial(now: t0)
        let prefs: [UsagePref] = [.layout(.rows), .barColor(.green), .numbers(.used), .showCountdown(false)]
        for pref in prefs {
            let step = UsageMachine.transition(state, .setPref(pref, now: t0))
            XCTAssertTrue(
                !step.effects.contains {
                    if case .reschedulePoll = $0 { return true }; return false
                },
                "\(pref) must never reschedule the poll")
        }
    }

    // MARK: - Whole-Step effect order: the tick core's pollNow (a crossed
    // anchor) precedes the pref's own persistPref.

    func testSetPrefEffectOrderPollNowThenPersistPref() {
        let t0 = queriedAtUnixFixture
        let opened = Fold.run(UsageState.initial(now: t0), [.historyOpened])
        let snap = snapshotFixture(session: 95, week: 10, fable: 10, sessionSecondsUntil: 30)
        let state = UsageMachine.transition(opened, .snapshot(snap, now: t0)).state

        let expiredNow = t0 + 100  // past the session anchor -> the tick core latches pollNow
        let pref = UsagePref.numbers(.used)
        let step = UsageMachine.transition(state, .setPref(pref, now: expiredNow))

        XCTAssertTrue(
            step.effects == [.pollNow, .persistPref(pref)],
            "the tick core's pollNow (from the crossed anchor) precedes the pref's own persistPref, "
                + "got \(step.effects)")
    }

    // MARK: - Invariant loops over a seeded random walk.

    func testInvariantDeterminism() {
        let seed: UInt64 = 20260904
        let events = randomWalkEvents(seed: seed, count: 500)
        var state = Fold.run(UsageState.initial(now: queriedAtUnixFixture), [.historyOpened])
        for (i, event) in events.enumerated() {
            let step1 = UsageMachine.transition(state, event)
            let step2 = UsageMachine.transition(state, event)
            XCTAssertTrue(step1 == step2, "seed \(seed) iteration \(i): same (state, event) produced different Steps")
            state = step1.state
        }
    }

    func testInvariantRemainingMatchesAnchorMinusNow() {
        let seed: UInt64 = 20260905
        let events = randomWalkEvents(seed: seed, count: 500)
        var state = Fold.run(UsageState.initial(now: queriedAtUnixFixture), [.historyOpened])
        for (i, event) in events.enumerated() {
            state = UsageMachine.transition(state, event).state
            for metricState in [state.session, state.week, state.fable] {
                guard let metricState, let anchor = metricState.resetAnchor,
                    let remaining = metricState.remainingSeconds
                else { continue }
                XCTAssertTrue(
                    remaining == anchor - state.now,
                    "seed \(seed) iteration \(i): remainingSeconds must equal anchor - now")
            }
        }
    }
}
