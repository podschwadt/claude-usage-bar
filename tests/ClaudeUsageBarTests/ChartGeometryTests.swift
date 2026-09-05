import ClaudeUsageBarCore
import CoreGraphics
import XCTest

/// Tolerance for the direct frame-overlap check in `testPanelGeometryLayout`
/// (the same value TestSupport's CGFloat `approxEqual` uses).
private let geometryEpsilon: CGFloat = 0.001

/// Shared window/rect fixtures for the ChartGeometry sections below.
private let window = TimeWindow(start: 1000, end: 2000)
private let rect = CGRect(x: 10, y: 20, width: 200, height: 100)

/// Shared panel size fixture for the PanelGeometry.origin sections below.
private let panelSize = CGSize(width: PanelGeometry.panelWidth, height: 400)

final class ChartGeometryTests: XCTestCase {
    // MARK: - ChartGeometry.xPosition / points

    func testXPositionAndPoints() {
        XCTAssertTrue(
            approxEqual(ChartGeometry.xPosition(ts: window.start, window: window, rect: rect), rect.minX),
            "xPosition at window.start maps to rect.minX")
        XCTAssertTrue(
            approxEqual(ChartGeometry.xPosition(ts: window.end, window: window, rect: rect), rect.maxX),
            "xPosition at window.end maps to rect.maxX")
        XCTAssertTrue(
            approxEqual(ChartGeometry.xPosition(ts: 1500, window: window, rect: rect), rect.midX),
            "xPosition at window midpoint maps to rect.midX")

        // Values arrive already resolved for the Numbers mode
        // (UsageState.displayedPct(fromUsed:)): 100 -> top edge (minY) in
        // the flipped view, 0 -> bottom edge (maxY), 50 -> midpoint.
        let segment: [(ts: Int, value: Double)] = [
            (ts: window.start, value: 100), (ts: 1500, value: 50), (ts: window.end, value: 0),
        ]
        let points = ChartGeometry.points(segment: segment, window: window, rect: rect)
        XCTAssertTrue(points.count == 3, "points count matches segment count")
        XCTAssertTrue(approxEqual(points[0].x, rect.minX), "points[0].x at window.start")
        XCTAssertTrue(approxEqual(points[0].y, rect.minY), "displayed 100 maps to rect.minY")
        XCTAssertTrue(approxEqual(points[1].x, rect.midX), "points[1].x at window midpoint")
        XCTAssertTrue(approxEqual(points[1].y, rect.midY), "displayed 50 maps to rect.midY")
        XCTAssertTrue(approxEqual(points[2].x, rect.maxX), "points[2].x at window.end")
        XCTAssertTrue(approxEqual(points[2].y, rect.maxY), "displayed 0 maps to rect.maxY")
    }

    // MARK: - ChartGeometry.nearestIndex (chart hover)

    func testNearestIndex() {
        // 5 points evenly spaced across the window, so their mapped x
        // positions are rect.minX, 25%, 50%, 75%, rect.maxX.
        let points: [(ts: Int, value: Double)] = [
            (ts: 1000, value: 0), (ts: 1250, value: 0), (ts: 1500, value: 0), (ts: 1750, value: 0),
            (ts: 2000, value: 0),
        ]

        XCTAssertTrue(
            ChartGeometry.nearestIndex(points: [], x: rect.midX, window: window, rect: rect) == nil,
            "nearestIndex is nil for an empty points array")

        // Exact hit: x lands exactly on a mapped point.
        let exactX = ChartGeometry.xPosition(ts: 1500, window: window, rect: rect)
        XCTAssertTrue(
            ChartGeometry.nearestIndex(points: points, x: exactX, window: window, rect: rect) == 2,
            "nearestIndex exact hit picks that point's index")

        // Between two points: nudge just past the midpoint toward each
        // neighbor and confirm it picks the nearer one.
        let x1250 = ChartGeometry.xPosition(ts: 1250, window: window, rect: rect)
        let x1500 = ChartGeometry.xPosition(ts: 1500, window: window, rect: rect)
        let midway = (x1250 + x1500) / 2
        XCTAssertTrue(
            ChartGeometry.nearestIndex(points: points, x: midway - 1, window: window, rect: rect) == 1,
            "nearestIndex between points picks the nearer one (left of midpoint)")
        XCTAssertTrue(
            ChartGeometry.nearestIndex(points: points, x: midway + 1, window: window, rect: rect) == 2,
            "nearestIndex between points picks the nearer one (right of midpoint)")

        // Outside range: clamps to the nearest endpoint rather than nil or
        // an out-of-bounds index.
        XCTAssertTrue(
            ChartGeometry.nearestIndex(points: points, x: rect.minX - 1000, window: window, rect: rect) == 0,
            "nearestIndex far left of the plot clamps to the first point")
        XCTAssertTrue(
            ChartGeometry.nearestIndex(points: points, x: rect.maxX + 1000, window: window, rect: rect) == points.count
                - 1,
            "nearestIndex far right of the plot clamps to the last point")

        // A single point always wins, regardless of x.
        let single = [points[2]]
        XCTAssertTrue(
            ChartGeometry.nearestIndex(points: single, x: rect.minX, window: window, rect: rect) == 0,
            "nearestIndex with a single point always returns 0")
    }

    // MARK: - ChartGeometry.gridYs

    // gridFractions ([0, 20, 40, 60, 80, 100]) use the same flipped mapping
    // as `points`: 0% sits at the bottom edge (rect.maxY), 100% at the top
    // (rect.minY), so ascending fractions produce descending y.
    func testGridYs() {
        let ys = ChartGeometry.gridYs(rect: rect)
        XCTAssertTrue(ys.count == 6, "gridYs returns 6 lines (0/20/40/60/80/100%)")
        XCTAssertTrue(approxEqual(ys[0], rect.maxY), "gridYs[0] (0%) at rect.maxY")
        XCTAssertTrue(approxEqual(ys[5], rect.minY), "gridYs[5] (100%) at rect.minY")
        for i in 0..<(ys.count - 1) {
            XCTAssertTrue(ys[i] > ys[i + 1], "gridYs is monotonically decreasing at index \(i)")
        }
        let expectedStep = rect.height / 5
        for i in 0..<(ys.count - 1) {
            XCTAssertTrue(approxEqual(ys[i] - ys[i + 1], expectedStep), "gridYs evenly spaced at index \(i)")
        }
    }

    // MARK: - ChartGeometry.ticks ("nice" alignment-aware boundaries)

    // Generic properties that must hold for any window: bounded, monotonic,
    // capped, and (once there are at least 2 ticks) evenly spaced by one of
    // the candidate steps.
    func testTicksGenericProperties() {
        let ticks = ChartGeometry.ticks(window: window, maxCount: 5, offsetFromGMT: 0)
        XCTAssertTrue(ticks.count <= 5, "ticks count does not exceed maxCount")
        XCTAssertTrue(ticks.allSatisfy { $0 >= window.start && $0 <= window.end }, "every tick falls within the window")
        for i in 0..<max(0, ticks.count - 1) {
            XCTAssertTrue(ticks[i] < ticks[i + 1], "ticks is monotonic at index \(i)")
        }
        if ticks.count >= 2 {
            let step = ticks[1] - ticks[0]
            XCTAssertTrue(ChartGeometry.tickStepCandidates.contains(step), "tick spacing is one of the candidate steps")
            for i in 1..<(ticks.count - 1) {
                XCTAssertTrue(ticks[i + 1] - ticks[i] == step, "tick spacing is constant across all ticks")
            }
        }
    }

    // Session window (5h): pinned boundary math at offsetFromGMT 0. A
    // window not itself hour-aligned (start = 1000) still produces ticks
    // that land exactly on hour marks, not on window.start/window.end.
    func testTicksSessionWindow() {
        let sessionWindow = TimeWindow(start: 1000, end: 1000 + HistoryMath.sessionLength)
        let ticks = ChartGeometry.ticks(window: sessionWindow, maxCount: ChartGeometry.maxTickCount, offsetFromGMT: 0)
        XCTAssertTrue(
            ticks == [3600, 7200, 10800, 14400, 18000],
            "session window ticks are pinned to hour marks, not window.start/window.end")
        for t in ticks {
            XCTAssertTrue(t % 3600 == 0, "session tick \(t) lands on an hour mark")
        }
    }

    // Week window (7d) at offsetFromGMT 0: lands on local midnights every 2
    // days.
    func testTicksWeekWindow() {
        let weekWindow = TimeWindow(start: 0, end: HistoryMath.weekLength)
        let ticks = ChartGeometry.ticks(window: weekWindow, maxCount: ChartGeometry.maxTickCount, offsetFromGMT: 0)
        XCTAssertTrue(ticks == [0, 172800, 345600, 518400], "week window ticks land on midnights, every 2 days")
        XCTAssertTrue(ticks.count <= ChartGeometry.maxTickCount, "week ticks respect maxTickCount")
    }

    // Week window (7d) at a NEGATIVE offsetFromGMT (a zone west of
    // Greenwich, e.g. US Eastern standard time): the boundary math must use
    // LOCAL wall time, so the same window produces different (still
    // midnight-aligned, still 2 days apart) ticks than at offset 0.
    func testTicksWeekWindowNegativeOffset() {
        let offset = -18000  // UTC-5
        let weekWindow = TimeWindow(start: 0, end: HistoryMath.weekLength)
        let ticks = ChartGeometry.ticks(window: weekWindow, maxCount: ChartGeometry.maxTickCount, offsetFromGMT: offset)
        XCTAssertTrue(
            ticks == [18000, 190_800, 363_600, 536_400],
            "week window ticks at a negative offset are pinned to LOCAL midnights every 2 days")
        for t in ticks {
            XCTAssertTrue((t + offset) % 172800 == 0, "week tick \(t) is a local midnight, 2 days apart")
        }
    }

    // MARK: - PanelGeometry.layout

    func testPanelGeometryLayout() {
        let horizontalBounds = PanelGeometry.sideMargin...(PanelGeometry.sideMargin + PanelGeometry.contentWidth)

        let layout = PanelGeometry.layout()
        let frames = [
            layout.ringsRow, layout.sessionHeader, layout.sessionChart,
            layout.weekHeader, layout.weekChart, layout.footer,
        ]
        for frame in frames {
            XCTAssertTrue(horizontalBounds.contains(frame.minX), "layout frame minX within content bounds")
            XCTAssertTrue(horizontalBounds.contains(frame.maxX), "layout frame maxX within content bounds")
            XCTAssertTrue(approxEqual(frame.width, PanelGeometry.contentWidth), "layout frame width is contentWidth")
        }

        // Vertical ordering: every section's stack order top to bottom,
        // non-overlapping (each frame's maxY <= the next frame's minY).
        for i in 0..<(frames.count - 1) {
            XCTAssertTrue(
                frames[i].maxY <= frames[i + 1].minY + geometryEpsilon,
                "layout frame \(i) does not overlap frame \(i + 1)")
        }
        XCTAssertTrue(approxEqual(layout.size.width, PanelGeometry.panelWidth), "layout size.width is panelWidth")
        XCTAssertTrue(approxEqual(layout.ringsRow.height, PanelGeometry.ringsRowHeight), "layout ringsRow height")
    }

    // MARK: - PanelGeometry.ringArc

    func testPanelGeometryRingArc() {
        // 0% remaining: the arc collapses to nothing, start == end.
        let empty = PanelGeometry.ringArc(fraction: 0)
        XCTAssertTrue(approxEqual(empty.start, empty.end), "ringArc(0) start == end (no arc)")

        // 100% remaining: a full circle back to the start angle.
        let full = PanelGeometry.ringArc(fraction: 1)
        XCTAssertTrue(approxEqual(full.end - full.start, 360), "ringArc(1) sweeps the full 360 degrees")

        // Anchored at -90 path-space degrees regardless of fraction: the
        // flipped rings view mirrors angles vertically, so -90 is what lands
        // on 12 o'clock on screen.
        for fraction in [0.0, 0.25, 0.5, 0.65, 1.0] {
            XCTAssertTrue(
                approxEqual(PanelGeometry.ringArc(fraction: fraction).start, -90),
                "ringArc(\(fraction)).start anchors at 12 o'clock on screen (-90 path-space)")
        }

        // Sweep magnitude is directly proportional to fraction, extending
        // counterclockwise in path space (clockwise on screen), so depletion
        // counts the tip down counterclockwise.
        let half = PanelGeometry.ringArc(fraction: 0.5)
        XCTAssertTrue(approxEqual(half.end - half.start, 180), "ringArc(0.5) sweeps half the circle (180 degrees)")

        // Out-of-range fractions clamp to 0...1 rather than over/under-sweeping.
        let over = PanelGeometry.ringArc(fraction: 1.5)
        XCTAssertTrue(approxEqual(over.end - over.start, 360), "ringArc(1.5) clamps to a full sweep")
        let under = PanelGeometry.ringArc(fraction: -0.3)
        XCTAssertTrue(approxEqual(under.start, under.end), "ringArc(-0.3) clamps to no sweep")
    }

    // MARK: - PanelGeometry.origin

    // Fits: left-aligned to the button's left edge.
    func testPanelGeometryOriginFits() {
        let buttonFrame = CGRect(x: 500, y: 800, width: 24, height: 22)
        let visibleFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = PanelGeometry.origin(buttonFrame: buttonFrame, panelSize: panelSize, visibleFrame: visibleFrame)
        XCTAssertTrue(approxEqual(origin.x, buttonFrame.minX), "origin left-aligns to buttonFrame.minX when it fits")
        XCTAssertTrue(
            approxEqual(origin.y, buttonFrame.minY - panelSize.height),
            "origin.y sits panelSize.height below buttonFrame.minY")
    }

    // Overflow: flips to right-aligned against the button's right edge.
    func testPanelGeometryOriginOverflow() {
        let buttonFrame = CGRect(x: 1400, y: 800, width: 24, height: 22)
        let visibleFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = PanelGeometry.origin(buttonFrame: buttonFrame, panelSize: panelSize, visibleFrame: visibleFrame)
        XCTAssertTrue(
            approxEqual(origin.x, buttonFrame.maxX - panelSize.width),
            "origin right-aligns to buttonFrame.maxX - width when left-aligned would overflow")
    }

    // Negative-origin visibleFrame (a display left of the primary): left
    // alignment must return the true negative x, never clamped to 0.
    func testPanelGeometryOriginNegativeVisibleFrame() {
        let buttonFrame = CGRect(x: -1900, y: 800, width: 24, height: 22)
        let visibleFrame = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let origin = PanelGeometry.origin(buttonFrame: buttonFrame, panelSize: panelSize, visibleFrame: visibleFrame)
        XCTAssertTrue(
            approxEqual(origin.x, buttonFrame.minX), "origin on a display left of the primary is the true negative minX"
        )
        XCTAssertTrue(origin.x < 0, "origin.x is negative, not clamped to 0")
    }

    // MARK: - ChartGeometry.readoutBoxSize

    func testReadoutBoxSize() {
        // Widest row (plus its swatch column) beats the time label.
        let wideRows = ChartGeometry.readoutBoxSize(
            timeWidth: 40, rowWidths: [30, 50, 20], rowHeight: 14, swatchColumn: 11, padding: 6)
        XCTAssertTrue(approxEqual(wideRows.width, 73), "readoutBoxSize width from the widest row + swatch column")
        XCTAssertTrue(
            approxEqual(wideRows.height, 68), "readoutBoxSize height is rowHeight * (1 time row + row count) + padding")

        // Time label beats every row + swatch column.
        let wideTime = ChartGeometry.readoutBoxSize(
            timeWidth: 100, rowWidths: [5, 5], rowHeight: 14, swatchColumn: 5, padding: 6)
        XCTAssertTrue(approxEqual(wideTime.width, 112), "readoutBoxSize width from the time label when it is widest")

        // No rows: height is just the time row, plus padding.
        let noRows = ChartGeometry.readoutBoxSize(
            timeWidth: 40, rowWidths: [], rowHeight: 14, swatchColumn: 11, padding: 6)
        XCTAssertTrue(approxEqual(noRows.height, 26), "readoutBoxSize height with no rows is one row + padding")
        XCTAssertTrue(approxEqual(noRows.width, 52), "readoutBoxSize width with no rows comes from timeWidth")
    }

    // MARK: - ChartGeometry.readoutBoxRect

    private let readoutBoxSize = CGSize(width: 50, height: 30)
    private let readoutBoxGap: CGFloat = 8

    // Anchor well clear of every edge: box grows right and up (smaller y,
    // the view being flipped) from the anchor by exactly the gap.
    func testReadoutBoxRectDefaultPlacement() {
        let anchor = CGPoint(x: 100, y: 100)
        let box = ChartGeometry.readoutBoxRect(anchor: anchor, size: readoutBoxSize, gap: readoutBoxGap, plotRect: rect)
        XCTAssertTrue(approxEqual(box.minX, anchor.x + readoutBoxGap), "default placement grows right of the anchor")
        XCTAssertTrue(approxEqual(box.maxY, anchor.y - readoutBoxGap), "default placement grows above the anchor")
        XCTAssertTrue(approxEqual(box.width, readoutBoxSize.width), "readoutBoxRect preserves the given size")
        XCTAssertTrue(approxEqual(box.height, readoutBoxSize.height), "readoutBoxRect preserves the given size")
    }

    // Anchor near plotRect.maxX: growing right would overrun it, so the box
    // flips to grow left instead. Vertical placement is unaffected.
    func testReadoutBoxRectRightEdgeFlip() {
        let anchor = CGPoint(x: rect.maxX - 20, y: 100)
        let box = ChartGeometry.readoutBoxRect(anchor: anchor, size: readoutBoxSize, gap: readoutBoxGap, plotRect: rect)
        XCTAssertTrue(approxEqual(box.maxX, anchor.x - readoutBoxGap), "right-edge flip grows left of the anchor")
        XCTAssertTrue(
            approxEqual(box.maxY, anchor.y - readoutBoxGap), "right-edge flip leaves vertical placement default")
    }

    // Anchor near plotRect.minY: growing up would overrun it (the chart's
    // top edge), so the box flips to grow down instead. Horizontal
    // placement is unaffected.
    func testReadoutBoxRectTopEdgeFlip() {
        let anchor = CGPoint(x: 100, y: rect.minY + 5)
        let box = ChartGeometry.readoutBoxRect(anchor: anchor, size: readoutBoxSize, gap: readoutBoxGap, plotRect: rect)
        XCTAssertTrue(approxEqual(box.minY, anchor.y + readoutBoxGap), "top-edge flip grows below the anchor")
        XCTAssertTrue(
            approxEqual(box.minX, anchor.x + readoutBoxGap), "top-edge flip leaves horizontal placement default")
    }

    // Anchor near the top-right corner: both flips apply independently.
    func testReadoutBoxRectBothEdgesFlip() {
        let anchor = CGPoint(x: rect.maxX - 20, y: rect.minY + 5)
        let box = ChartGeometry.readoutBoxRect(anchor: anchor, size: readoutBoxSize, gap: readoutBoxGap, plotRect: rect)
        XCTAssertTrue(approxEqual(box.maxX, anchor.x - readoutBoxGap), "both-edges flip grows left of the anchor")
        XCTAssertTrue(approxEqual(box.minY, anchor.y + readoutBoxGap), "both-edges flip grows below the anchor")
    }
}
