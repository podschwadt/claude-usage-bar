/// A half-open-in-spirit but inclusive `[start, end]` range of unix seconds
/// used to bound a chart's x-axis.
package struct TimeWindow: Equatable {
    package let start: Int
    package let end: Int

    package init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }
}

/// Pure time-axis and data-shaping math for the history charts: no AppKit,
/// no IO, fully unit-testable.
package enum HistoryMath {
    package static let sessionLength = 5 * 3600
    package static let weekLength = 7 * 86400
    package static let weekBucket = 1800
    /// Tolerance, in seconds, for matching a stored `session_start` against
    /// the current session's identity. `/usage` rounds `seconds_until`, so
    /// `PanelModel.sessionStart` derives values up to a minute apart for the
    /// same real session across polls; 120 doubles that observed jitter for
    /// margin. Distinct sessions start at least one 5h window apart, so any
    /// tolerance far below `sessionLength` can never match a neighbor.
    package static let sessionStartTolerance = 120

    package static func sessionWindow(resetAtUnix: Int?, now: Int) -> TimeWindow {
        window(length: sessionLength, resetAtUnix: resetAtUnix, now: now)
    }

    package static func weekWindow(resetAtUnix: Int?, now: Int) -> TimeWindow {
        window(length: weekLength, resetAtUnix: resetAtUnix, now: now)
    }

    /// Anchored `[resetAt - length, resetAt]` when the reset boundary is
    /// known; otherwise a trailing window of the SAME length ending at
    /// `now` — the fallback swaps the anchor, never the duration, so the
    /// chart's x-scale never silently rescales between the two cases.
    private static func window(length: Int, resetAtUnix: Int?, now: Int) -> TimeWindow {
        let end = resetAtUnix ?? now
        return TimeWindow(start: end - length, end: end)
    }
}
