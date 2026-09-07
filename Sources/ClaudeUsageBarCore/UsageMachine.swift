import Foundation

/// The usage domain as a pure state machine: events (`UsageEvent`) go in, a
/// fresh `UsageState` plus an ordered list of `UsageEffect`s (`Step`) comes
/// out. `transition` is pure and total, touches no AppKit, and reads no
/// clock but the one handed to it in the event. `UsageState` is what every
/// surface renders from; `UsageEffect` is only side-effecting verbs. The
/// interpreter (`StatusItemController`) commits `step.state`, then performs
/// `step.effects` strictly in array order — the ordering is contractual
/// (a `.record` must be performed before a `.pollNow` triggers the next
/// fetch), never reordered or batched.
///
/// The reducer returns a nominal `Step`, not a tuple: tuples are not
/// `Equatable`, and whole-`Step` equality is the test strategy throughout
/// `UsageMachineTests`.

/// One metric's derived display state: the raw `Metric` (so
/// `StatusBarRenderer.gauges`/`Display.menuRow`/`PanelModel.build` take it
/// unchanged) and its reset anchor/countdown. `remainingSeconds` is
/// recomputed from every event's own `now`, never cached stale.
package struct MetricState: Equatable {
    package let metric: Metric
    package let resetAnchor: Int?
    package let remainingSeconds: Int?

    package init(metric: Metric, resetAnchor: Int?, remainingSeconds: Int?) {
        self.metric = metric
        self.resetAnchor = resetAnchor
        self.remainingSeconds = remainingSeconds
    }
}

/// The full usage-domain state: everything every surface (menu bar, dropdown,
/// history panel) renders from. Nothing outside `UsageMachine.transition`
/// mutates it.
package struct UsageState: Equatable {
    /// How much the last snapshot can be trusted. `.loading` only before the
    /// first fetch ever completes; a later untrustworthy fetch becomes
    /// `.fetchFailed`/`.schemaMismatch`, never back to `.loading`.
    package enum Trust: Equatable {
        case loading
        case fetchFailed(message: String)
        case schemaMismatch(missing: [String])
        case trusted
    }

    /// Availability of the on-disk history store, reported by the
    /// interpreter's open/fail main-hops (`.historyOpened`/`.historyFailed`).
    package enum HistoryAvailability: Equatable {
        case opening
        case available
        case unavailable(message: String)
    }

    package var trust: Trust
    package var session: MetricState?
    package var week: MetricState?
    package var fable: MetricState?
    package var queriedAt: String?
    package var queriedAtUnix: Int?
    package var activity: Activity?
    /// Copy of the last snapshot's `/usage` payload, falling back to its
    /// error text when no payload was captured — backs "Copy /usage Output".
    package var raw: String?
    /// Latch = the reset anchor already polled for. Without it, a countdown
    /// stuck below zero (waiting on the next real fetch to arrive) would
    /// re-request `.pollNow` on every single tick instead of once per
    /// rollover.
    package var sessionExpiryPolled: Int?
    package var weekExpiryPolled: Int?
    /// The anchor most recently requested for arming (see `.armBoundaryPoll`):
    /// a latch on the ARMING request, not on whether the timer has fired.
    /// Only `trustedSnapshot` ever writes it, and only when it emits the
    /// effect — `tick` and `untrustedSnapshot` leave it unchanged, since an
    /// already-fired timer needs no re-arm and an untrusted blip must not
    /// arm one.
    package var boundaryPollArmed: Int?
    package var history: HistoryAvailability
    /// The only clock any renderer sees; set from the triggering event's
    /// `now`, never read from `Date()` inside the machine.
    package var now: Int
    /// User-configurable display and polling settings, changed only through
    /// `.setPref`.
    package var prefs: UsagePrefs

    package init(
        trust: Trust, session: MetricState?, week: MetricState?, fable: MetricState?,
        queriedAt: String?, queriedAtUnix: Int?,
        activity: Activity?, raw: String?,
        sessionExpiryPolled: Int?, weekExpiryPolled: Int?, boundaryPollArmed: Int?,
        history: HistoryAvailability, now: Int, prefs: UsagePrefs
    ) {
        self.trust = trust
        self.session = session
        self.week = week
        self.fable = fable
        self.queriedAt = queriedAt
        self.queriedAtUnix = queriedAtUnix
        self.activity = activity
        self.raw = raw
        self.sessionExpiryPolled = sessionExpiryPolled
        self.weekExpiryPolled = weekExpiryPolled
        self.boundaryPollArmed = boundaryPollArmed
        self.history = history
        self.now = now
        self.prefs = prefs
    }

    /// The state before any snapshot has ever arrived: loading, no identity,
    /// history availability unknown. `prefs` is an input (the interpreter's
    /// `PrefsStore.load` result at launch), not derived by the machine.
    package static func initial(now: Int, prefs: UsagePrefs = .standard) -> UsageState {
        UsageState(
            trust: .loading, session: nil, week: nil, fable: nil,
            queriedAt: nil, queriedAtUnix: nil,
            activity: nil, raw: nil,
            sessionExpiryPolled: nil, weekExpiryPolled: nil, boundaryPollArmed: nil,
            history: .opening, now: now, prefs: prefs)
    }
}

extension UsageState {
    /// The metrics actually present, in display order (session, week,
    /// fable), skipping whichever are nil.
    package var metricStates: [MetricState] {
        [session, week, fable].compactMap { $0 }
    }

    /// The session chart's x-axis window: anchored to `session?.resetAnchor`
    /// when known, else a trailing `HistoryMath.sessionLength` window ending
    /// at `now` (see `HistoryMath.sessionWindow`). Computed, not stored, so
    /// it can never desync from `session`/`now`.
    package var sessionWindow: TimeWindow {
        HistoryMath.sessionWindow(resetAtUnix: session?.resetAnchor, now: now)
    }

    /// The week chart's x-axis window: same rule as `sessionWindow`, over
    /// `week?.resetAnchor` and `HistoryMath.weekLength`.
    package var weekWindow: TimeWindow {
        HistoryMath.weekWindow(resetAtUnix: week?.resetAnchor, now: now)
    }
}

extension UsageState: CustomDebugStringConvertible {
    /// Compact, readable dump so a failed whole-`Step` `XCTAssertEqual` in
    /// `UsageMachineTests` prints a diff worth reading. Includes `raw`,
    /// `activity`, and `queriedAtUnix` (presence/length rather than full
    /// content for the first two) so a mismatch confined to just those
    /// fields does not print two identical-looking dumps.
    package var debugDescription: String {
        """
        UsageState(trust: \(trust), now: \(now), history: \(history), \
        session: \(session.map(String.init(describing:)) ?? "nil"), \
        week: \(week.map(String.init(describing:)) ?? "nil"), \
        fable: \(fable.map(String.init(describing:)) ?? "nil"), \
        queriedAt: \(queriedAt ?? "nil"), queriedAtUnix: \(queriedAtUnix.map(String.init) ?? "nil"), \
        activity: \(activity != nil ? "present" : "nil"), \
        raw: \(raw.map { "present(\($0.count) chars)" } ?? "nil"), \
        sessionExpiryPolled: \(sessionExpiryPolled.map(String.init) ?? "nil"), \
        weekExpiryPolled: \(weekExpiryPolled.map(String.init) ?? "nil"), \
        boundaryPollArmed: \(boundaryPollArmed.map(String.init) ?? "nil"), \
        prefs: \(prefs))
        """
    }
}

/// Inputs to the machine. `.snapshot`/`.tick`/`.setPref` carry a clock
/// reading; `.historyOpened`/`.historyFailed` change only
/// `UsageState.history`.
package enum UsageEvent: Equatable {
    case snapshot(UsageSnapshot, now: Int)
    case tick(now: Int)
    case setPref(UsagePref, now: Int)
    case historyOpened
    case historyFailed(message: String)
}

/// Outputs of one transition: side-effecting verbs performed by the
/// interpreter.
package enum UsageEffect: Equatable {
    case record(Sample)
    case pollNow
    /// Arms a one-shot poll at `at` (a unix-seconds reset anchor): the
    /// interpreter's session-boundary timer, re-armed whenever
    /// `trustedSnapshot` reports a new earliest upcoming anchor.
    case armBoundaryPoll(at: Int)
    /// Writes the one key `pref` touches to `UserDefaults`, via
    /// `PrefsStore.persist`.
    case persistPref(UsagePref)
    /// Restarts the poll timer at `seconds`. Emitted only when `.setPref`
    /// carries `.refreshInterval` and the value actually changes.
    case reschedulePoll(seconds: Int)
}

/// One transition's result: the next state, plus its effects in the order
/// the interpreter must perform them.
package struct Step: Equatable {
    package var state: UsageState
    package var effects: [UsageEffect]

    package init(state: UsageState, effects: [UsageEffect]) {
        self.state = state
        self.effects = effects
    }
}

/// The transition function. Pure, total: `PanelModel.resetAnchor`/
/// `PanelModel.sessionStart` are called INSIDE here (the single place the
/// anchor/identity math lives), and every clock read is the event's `now`.
package enum UsageMachine {
    package static func transition(_ state: UsageState, _ event: UsageEvent) -> Step {
        switch event {
        case let .snapshot(snapshot, now):
            return snapshot.isTrustworthy
                ? trustedSnapshot(state, snapshot, now: now)
                : untrustedSnapshot(state, snapshot, now: now)
        case let .tick(now):
            return tick(state, now: now)
        case let .setPref(pref, now):
            return setPref(state, pref, now: now)
        case .historyOpened:
            var next = state
            next.history = .available
            return Step(state: next, effects: [])
        case let .historyFailed(message):
            var next = state
            next.history = .unavailable(message: message)
            return Step(state: next, effects: [])
        }
    }

    // MARK: - T1: trustworthy snapshot

    private static func trustedSnapshot(_ state: UsageState, _ snapshot: UsageSnapshot, now: Int) -> Step {
        let sessionMetric = snapshot.metric(MetricKey.session)
        let weekMetric = snapshot.metric(MetricKey.week)
        let fableMetric = snapshot.metric(MetricKey.fable)

        let newSessionStart = PanelModel.sessionStart(
            queriedAt: snapshot.queriedAt, secondsUntil: sessionMetric?.reset?.secondsUntil)

        // A session absent from this snapshot but present in `state` freezes
        // forward rather than going nil: metric and resetAnchor unchanged,
        // remainingSeconds recomputed against `now` (so it pins at or below
        // zero, the true remaining time). `newSessionStart` above is derived
        // from `sessionMetric`, which is nil here, so it stays nil and the
        // record gate below never writes a frozen sample. A later snapshot
        // reporting a session replaces the frozen state through the branch
        // above.
        let newSession: MetricState?
        if let sessionMetric {
            newSession = anchoredMetricState(for: sessionMetric, queriedAt: snapshot.queriedAt, now: now)
        } else if let frozen = state.session {
            newSession = recomputeRemaining(frozen, now: now)
        } else {
            newSession = nil
        }
        let newWeek = weekMetric.map { anchoredMetricState(for: $0, queriedAt: snapshot.queriedAt, now: now) }
        // /usage DOES emit week_fable.reset.seconds_until (pinned by
        // SnapshotDecodingTests): a present fable metric takes the same
        // anchored path as session/week, but never feeds a poll decision
        // below - only session/week expiry triggers `.pollNow`.
        let newFable = fableMetric.map { anchoredMetricState(for: $0, queriedAt: snapshot.queriedAt, now: now) }

        let sessionPoll = pollDecision(
            oldLatch: state.sessionExpiryPolled, anchor: newSession?.resetAnchor,
            remaining: newSession?.remainingSeconds)
        let weekPoll = pollDecision(
            oldLatch: state.weekExpiryPolled, anchor: newWeek?.resetAnchor, remaining: newWeek?.remainingSeconds)

        // All three metrics present, whole, and a derivable session id, so a
        // recorded row is never partially populated (Sample itself is not
        // nullable).
        let recordSample: Sample? = {
            guard let session = newSession, let week = newWeek, let fable = newFable,
                let sessionStart = newSessionStart, state.history == .available
            else { return nil }
            return Sample(
                ts: now, sessionStart: sessionStart,
                session: session.metric.usedPct, week: week.metric.usedPct, fable: fable.metric.usedPct)
        }()

        // The nearer upcoming reset among session/week. A fired anchor is in
        // the past, so `earliestFutureAnchor` filters it out — the latch can
        // never deadlock on an anchor whose timer already fired. `armAnchor`
        // is non-nil exactly when the nearest future anchor differs from the
        // one last requested for arming (`state.boundaryPollArmed`), e.g.
        // after a session-boundary fire freezes the session and leaves the
        // week anchor as the new earliest.
        let earliest = Self.earliestFutureAnchor(newSession?.resetAnchor, newWeek?.resetAnchor, now: now)
        let armAnchor: Int? = earliest == state.boundaryPollArmed ? nil : earliest

        var effects: [UsageEffect] = []
        if let recordSample { effects.append(.record(recordSample)) }
        if let armAnchor { effects.append(.armBoundaryPoll(at: armAnchor)) }
        if sessionPoll.poll || weekPoll.poll { effects.append(.pollNow) }

        var next = state
        next.trust = .trusted
        next.session = newSession
        next.week = newWeek
        next.fable = newFable
        next.queriedAt = snapshot.queriedAt
        next.queriedAtUnix = snapshot.queriedAt.flatMap(Display.iso8601Date).map { Int($0.timeIntervalSince1970) }
        next.activity = snapshot.activity
        next.raw = snapshot.raw
        next.sessionExpiryPolled = sessionPoll.latch
        next.weekExpiryPolled = weekPoll.latch
        next.boundaryPollArmed = armAnchor ?? state.boundaryPollArmed
        next.now = now

        return Step(state: next, effects: effects)
    }

    // MARK: - T2: untrustworthy snapshot

    private static func untrustedSnapshot(_ state: UsageState, _ snapshot: UsageSnapshot, now: Int) -> Step {
        let trust: UsageState.Trust
        if !snapshot.ok {
            trust = .fetchFailed(message: snapshot.error ?? "unknown error")
        } else {
            trust = .schemaMismatch(missing: snapshot.missingKeys ?? [])
        }

        var next = state
        next.trust = trust
        next.session = nil
        next.week = nil
        next.fable = nil
        next.queriedAt = snapshot.queriedAt
        next.queriedAtUnix = snapshot.queriedAt.flatMap(Display.iso8601Date).map { Int($0.timeIntervalSince1970) }
        next.activity = snapshot.activity
        next.raw = snapshot.raw ?? snapshot.error
        next.now = now
        // sessionExpiryPolled and weekExpiryPolled PERSIST unchanged: an
        // untrustworthy blip must not re-arm a poll for an anchor already
        // latched before the blip.

        return Step(state: next, effects: [])
    }

    // MARK: - T3/T4: tick

    private static func tick(_ state: UsageState, now: Int) -> Step {
        guard state.trust == .trusted else {
            var next = state
            next.now = now
            return Step(state: next, effects: [])
        }

        let newSession = state.session.map { recomputeRemaining($0, now: now) }
        let newWeek = state.week.map { recomputeRemaining($0, now: now) }
        // Fable is anchored too (see trustedSnapshot), so its countdown must
        // stay live between polls exactly like session/week; it just never
        // feeds a poll decision below.
        let newFable = state.fable.map { recomputeRemaining($0, now: now) }

        let sessionPoll = pollDecision(
            oldLatch: state.sessionExpiryPolled, anchor: newSession?.resetAnchor,
            remaining: newSession?.remainingSeconds)
        let weekPoll = pollDecision(
            oldLatch: state.weekExpiryPolled, anchor: newWeek?.resetAnchor, remaining: newWeek?.remainingSeconds)

        var effects: [UsageEffect] = []
        if sessionPoll.poll || weekPoll.poll { effects.append(.pollNow) }

        var next = state
        next.session = newSession
        next.week = newWeek
        next.fable = newFable
        next.sessionExpiryPolled = sessionPoll.latch
        next.weekExpiryPolled = weekPoll.latch
        next.now = now

        return Step(state: next, effects: effects)
    }

    // MARK: - T5: user preference change

    /// Runs the ordinary tick recompute first - so a stale countdown flips
    /// live and a crossed anchor still latches its `.pollNow` even when the
    /// triggering event was a pref change, not a fresh poll - then applies
    /// `pref` on top of the ticked state and appends its persistence effect.
    /// `.reschedulePoll` follows only when `pref` is `.refreshInterval` and
    /// its value actually differs from what was already stored: any other
    /// pref, or the same interval set again, must not restart the poll timer.
    private static func setPref(_ state: UsageState, _ pref: UsagePref, now: Int) -> Step {
        let ticked = tick(state, now: now)
        var next = ticked.state
        let oldInterval = next.prefs.refreshInterval
        next.prefs = applying(pref, to: next.prefs)

        var effects = ticked.effects
        effects.append(.persistPref(pref))
        if case let .refreshInterval(seconds) = pref, seconds != oldInterval {
            effects.append(.reschedulePoll(seconds: seconds))
        }

        return Step(state: next, effects: effects)
    }

    /// Applies one `UsagePref` payload to `prefs`, returning the updated copy.
    private static func applying(_ pref: UsagePref, to prefs: UsagePrefs) -> UsagePrefs {
        var next = prefs
        switch pref {
        case let .layout(layout): next.layout = layout
        case let .barColor(barColor): next.barColor = barColor
        case let .numbers(numbers): next.numbers = numbers
        case let .refreshInterval(seconds): next.refreshInterval = seconds
        case let .showCountdown(on): next.showCountdown = on
        }
        return next
    }

    // MARK: - Shared helpers

    private static func anchoredMetricState(for metric: Metric, queriedAt: String?, now: Int) -> MetricState {
        let anchor = PanelModel.resetAnchor(queriedAt: queriedAt, secondsUntil: metric.reset?.secondsUntil)
        return MetricState(metric: metric, resetAnchor: anchor, remainingSeconds: anchor.map { $0 - now })
    }

    private static func recomputeRemaining(_ state: MetricState, now: Int) -> MetricState {
        MetricState(
            metric: state.metric, resetAnchor: state.resetAnchor, remainingSeconds: state.resetAnchor.map { $0 - now })
    }

    /// Whether an expired countdown should fire `.pollNow`, and what the
    /// anchor latch becomes afterward. Clears (to nil) once the countdown is
    /// non-negative or absent; otherwise holds the anchor it already polled
    /// for so the same expiry cannot fire twice, and only reports `poll:
    /// true` the first time a given anchor is seen expired.
    private static func pollDecision(oldLatch: Int?, anchor: Int?, remaining: Int?) -> (latch: Int?, poll: Bool) {
        guard let remaining, remaining < 0 else { return (nil, false) }
        if oldLatch == anchor { return (oldLatch, false) }
        return (anchor, true)
    }

    /// The nearer of two optional reset anchors that is still ahead of `now`,
    /// or nil when neither is: feeds `armBoundaryPoll` arming, which only
    /// ever targets an anchor still worth a one-shot timer.
    private static func earliestFutureAnchor(_ a: Int?, _ b: Int?, now: Int) -> Int? {
        [a, b].compactMap { $0 }.filter { $0 > now }.min()
    }
}
