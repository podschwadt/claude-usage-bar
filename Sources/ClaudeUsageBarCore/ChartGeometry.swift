import CoreGraphics

/// Geometry for the history charts: linear time -> x and displayed-percent
/// -> y mapping, grid lines, and tick timestamps. Pure math (the
/// `GaugeGeometry` analog for the panel's charts) so it is unit-testable
/// without a graphics context.
package enum ChartGeometry {

    /// Percent fractions of the six horizontal grid lines, in increments of 20.
    package static let gridFractions: [Double] = [0, 20, 40, 60, 80, 100]

    /// Default cap on x-axis tick labels (the iStat spec calls for at most 5).
    package static let maxTickCount = 5

    /// Candidate x-axis tick spacings, in seconds, from 30 minutes up to 2
    /// days: `ticks(window:maxCount:offsetFromGMT:)` picks the smallest of
    /// these that keeps the tick count within `maxCount` over the window, so
    /// ticks always land on a round boundary (a half hour, an hour, a day,
    /// ...) rather than an arbitrary evenly-spaced offset.
    package static let tickStepCandidates: [Int] = [1800, 3600, 7200, 10800, 21600, 43200, 86400, 172800]

    /// Linear map from a unix timestamp to an x coordinate: `window.start`
    /// lands on `rect.minX`, `window.end` on `rect.maxX`. Shared by `points`
    /// and `ticks` so the line and its axis labels always agree on scale.
    package static func xPosition(ts: Int, window: TimeWindow, rect: CGRect) -> CGFloat {
        let fraction = CGFloat(ts - window.start) / CGFloat(window.end - window.start)
        return rect.minX + fraction * rect.width
    }

    /// Index of the point in `points` whose mapped x position (via
    /// `xPosition`) is nearest `x` - the hover chart's "which sample is the
    /// mouse over" query. Nil for an empty `points`; an `x` outside the
    /// segment's range clamps to the nearest endpoint (the endpoint's
    /// distance to `x` is still smallest among all points, so no special
    /// case is needed for that).
    package static func nearestIndex(
        points: [(ts: Int, value: Double)], x: CGFloat,
        window: TimeWindow, rect: CGRect
    ) -> Int? {
        guard !points.isEmpty else { return nil }
        var bestIndex = 0
        var bestDistance = CGFloat.infinity
        for (i, point) in points.enumerated() {
            let distance = abs(xPosition(ts: point.ts, window: window, rect: rect) - x)
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = i
            }
        }
        return bestIndex
    }

    /// Maps a segment of displayed percentages (0-100, already resolved for
    /// the Numbers mode by `UsageState.displayedPct(fromUsed:)`) to chart
    /// points. The view is flipped (y grows downward), so 100 sits at the
    /// top edge (`rect.minY`) and 0 at the bottom edge (`rect.maxY`).
    package static func points(
        segment: [(ts: Int, value: Double)], window: TimeWindow, rect: CGRect
    ) -> [CGPoint] {
        segment.map { point in
            let x = xPosition(ts: point.ts, window: window, rect: rect)
            let y = rect.minY + (1 - CGFloat(point.value) / 100) * rect.height
            return CGPoint(x: x, y: y)
        }
    }

    /// Y coordinates of the five horizontal grid lines at 0/25/50/75/100%
    /// remaining, using the same flipped-view mapping as `points`.
    package static func gridYs(rect: CGRect) -> [CGFloat] {
        gridFractions.map { fraction in
            rect.minY + (1 - CGFloat(fraction) / 100) * rect.height
        }
    }

    /// Floor division, correct for a negative dividend (unlike `/`, which
    /// truncates toward zero) - needed below since a local wall-clock
    /// timestamp (unix time + a negative UTC offset) can go negative for a
    /// window near the unix epoch, and more routinely for `offsetFromGMT`
    /// itself (any zone west of Greenwich).
    private static func floorDiv(_ a: Int, _ b: Int) -> Int {
        let q = a / b, r = a % b
        return (r != 0 && (r < 0) != (b < 0)) ? q - 1 : q
    }

    private static func ceilDiv(_ a: Int, _ b: Int) -> Int {
        -floorDiv(-a, b)
    }

    /// How many `step`-second ticks land inside `window`, reckoned in local
    /// wall time (`offsetFromGMT` seconds east of UTC) - the count a
    /// candidate step actually produces once alignment is taken into
    /// account, not just `span / step`.
    private static func tickCount(step: Int, window: TimeWindow, offsetFromGMT: Int) -> Int {
        let firstMultiple = ceilDiv(window.start + offsetFromGMT, step)
        let lastMultiple = floorDiv(window.end + offsetFromGMT, step)
        return max(0, lastMultiple - firstMultiple + 1)
    }

    /// "Nice" x-axis ticks spanning the window: the smallest of
    /// `tickStepCandidates` that keeps the count within `maxCount` (the
    /// widest candidate if none does), starting at the smallest multiple of
    /// that step at or after `window.start` **in local wall time** -
    /// alignment needs the caller's local UTC offset (`TimeZone.current
    /// .secondsFromGMT()` in production; a fixed value in tests, so the
    /// boundary math is pinned rather than dependent on the machine running
    /// the tests). A 5h session window lands on hour marks; a 7d week
    /// window on local midnights every 2 days. Monotonic; ticks snap to
    /// round boundaries rather than to `window.start`/`window.end`.
    package static func ticks(window: TimeWindow, maxCount: Int, offsetFromGMT: Int) -> [Int] {
        guard maxCount > 0, window.end >= window.start else { return [] }
        let step =
            tickStepCandidates.first { tickCount(step: $0, window: window, offsetFromGMT: offsetFromGMT) <= maxCount }
            ?? tickStepCandidates[tickStepCandidates.count - 1]

        var multiple = ceilDiv(window.start + offsetFromGMT, step)
        var result: [Int] = []
        while true {
            let t = multiple * step - offsetFromGMT
            guard t <= window.end else { break }
            result.append(t)
            multiple += 1
        }
        return result
    }

    /// Size of the chart hover readout box: wide enough for `timeWidth` or
    /// the widest of `rowWidths` (a row's full content after the swatch -
    /// any label column plus the value) plus `swatchColumn`, tall enough for
    /// the time row plus one row per `rowWidths` element, `padding` clear on
    /// every side.
    package static func readoutBoxSize(
        timeWidth: CGFloat, rowWidths: [CGFloat], rowHeight: CGFloat, swatchColumn: CGFloat, padding: CGFloat
    ) -> CGSize {
        let contentWidth = max(timeWidth, (rowWidths.max() ?? 0) + swatchColumn)
        let width = contentWidth + 2 * padding
        let height = rowHeight * CGFloat(1 + rowWidths.count) + 2 * padding
        return CGSize(width: width, height: height)
    }

    /// Placement of a readout box of `size` near `anchor` (the chart's
    /// topmost hovered dot): grows right and up by default, `gap` clear of
    /// `anchor`, flipping to the left when growing right would run past
    /// `plotRect.maxX` and flipping down when growing up would run past
    /// `plotRect.minY` (the chart's top edge, its view being flipped). Each
    /// flip is independent and unconditional - a box wider or taller than
    /// `plotRect` can still land partly outside it; this covers the two
    /// edges the box actually risks crossing (right, top) rather than
    /// clamping the result into `plotRect`.
    package static func readoutBoxRect(anchor: CGPoint, size: CGSize, gap: CGFloat, plotRect: CGRect) -> CGRect {
        let rightX = anchor.x + gap
        let x = rightX + size.width > plotRect.maxX ? anchor.x - gap - size.width : rightX
        let upY = anchor.y - gap - size.height
        let y = upY < plotRect.minY ? anchor.y + gap : upY
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }
}
