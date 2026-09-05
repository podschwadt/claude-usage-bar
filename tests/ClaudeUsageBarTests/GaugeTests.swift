import AppKit
import ClaudeUsageBarCore
import XCTest

/// Shared geometry fixtures for the GaugeGeometry sections below.
private let sampleColumnWidth: CGFloat = 30
private let sampleRowTextWidth: CGFloat = GaugeGeometry.rowMinTextWidth

/// Tolerance for the direct rect-overlap checks below (`approxEqual`, from
/// `TestSupport`, has its own tighter tolerance).
private let geometryEpsilon: CGFloat = 0.001

/// Shared metric fixtures for the StatusBarRenderer sections below.
private let session = Metric(key: MetricKey.session, usedPct: 11, remainingPct: 89, reset: nil)
private let week = Metric(key: MetricKey.week, usedPct: 55, remainingPct: 45, reset: nil)
private let fable = Metric(key: MetricKey.fable, usedPct: 80, remainingPct: 20, reset: nil)
private let metrics = [session, week, fable]
private let base = BarColor.blue.nsColor

/// Runs each metric through the real `UsageState.presentation` lens (a
/// one-metric state with the given Numbers mode), preserving list order,
/// so these tests exercise the same path `render()` does.
private func presentations(_ metrics: [Metric], numbers: Display.NumberMode) -> [MetricPresentation] {
    metrics.map { metric in
        var prefs = UsagePrefs.standard
        prefs.numbers = numbers
        var state = UsageState.initial(now: 0, prefs: prefs)
        state.session = MetricState(metric: metric, resetAnchor: nil, remainingSeconds: nil)
        return state.presentations[0]
    }
}

private let columnsRemaining = StatusBarRenderer.gauges(
    presentations: presentations(metrics, numbers: .remaining), layout: .columns, baseColor: base)
private let rowsRemaining = StatusBarRenderer.gauges(
    presentations: presentations(metrics, numbers: .remaining), layout: .rows, baseColor: base)
private let columnsUsed = StatusBarRenderer.gauges(
    presentations: presentations(metrics, numbers: .used), layout: .columns, baseColor: base)

final class GaugeTests: XCTestCase {
    // MARK: - GaugeGeometry

    func testGaugeGeometryColumnsAndRows() {
        for cellCount in 1...3 {
            let columnsSize = GaugeGeometry.columnsImageSize(cellCount: cellCount, columnWidth: sampleColumnWidth)
            let columnsFrames = GaugeGeometry.columnsFrames(cellCount: cellCount, columnWidth: sampleColumnWidth)
            XCTAssertTrue(columnsFrames.count == cellCount, "columns frames count for \(cellCount) cell(s)")

            let columnsBounds = CGRect(origin: .zero, size: columnsSize)
                .insetBy(dx: -geometryEpsilon, dy: -geometryEpsilon)
            for cell in columnsFrames {
                XCTAssertTrue(
                    columnsBounds.contains(cell.textRect), "columns textRect fits image (\(cellCount) cell(s))")
                XCTAssertTrue(columnsBounds.contains(cell.barRect), "columns barRect fits image (\(cellCount) cell(s))")
            }
            for i in 0..<(cellCount - 1) {
                let a = columnsFrames[i].barRect
                let b = columnsFrames[i + 1].barRect
                XCTAssertTrue(
                    a.maxX + GaugeGeometry.columnGap <= b.minX + geometryEpsilon,
                    "columns cell \(i) does not overlap cell \(i + 1)")
            }
            let expectedColumnsWidth =
                CGFloat(cellCount) * sampleColumnWidth
                + CGFloat(cellCount - 1) * GaugeGeometry.columnGap
            XCTAssertTrue(
                approxEqual(Double(columnsSize.width), Double(expectedColumnsWidth)),
                "columns image width formula for \(cellCount) cell(s)")

            let rowsSize = GaugeGeometry.rowsImageSize(cellCount: cellCount, textWidth: sampleRowTextWidth)
            let rowsFrames = GaugeGeometry.rowsFrames(cellCount: cellCount, textWidth: sampleRowTextWidth)
            XCTAssertTrue(rowsFrames.count == cellCount, "rows frames count for \(cellCount) cell(s)")

            let rowsBounds = CGRect(origin: .zero, size: rowsSize)
                .insetBy(dx: -geometryEpsilon, dy: -geometryEpsilon)
            for cell in rowsFrames {
                XCTAssertTrue(rowsBounds.contains(cell.textRect), "rows textRect fits image (\(cellCount) cell(s))")
                XCTAssertTrue(rowsBounds.contains(cell.barRect), "rows barRect fits image (\(cellCount) cell(s))")
            }
            for i in 0..<(cellCount - 1) {
                let a = rowsFrames[i].barRect
                let b = rowsFrames[i + 1].barRect
                XCTAssertTrue(a.maxY <= b.minY + geometryEpsilon, "rows cell \(i) does not overlap cell \(i + 1)")
            }
            for cell in rowsFrames {
                XCTAssertTrue(
                    cell.barRect.width == GaugeGeometry.rowBarWidth,
                    "rows bar width is fixed at rowBarWidth (\(cellCount) cell(s))")
            }

            // Image width is textWidth + gap + the fixed bar width. Height
            // centers the content group inside `imageHeight`, so even a
            // single row (contentHeight well under 20) still yields a
            // 20pt-tall image.
            let expectedRowsWidth = sampleRowTextWidth + GaugeGeometry.rowTextToBarGap + GaugeGeometry.rowBarWidth
            XCTAssertTrue(
                approxEqual(Double(rowsSize.width), Double(expectedRowsWidth)),
                "rows image width formula for \(cellCount) cell(s)")
            XCTAssertTrue(rowsSize.height == 20, "rows image height for \(cellCount) cell(s) is exactly 20")
        }

        // fillRect: clamped left-anchored fill.
        let track = CGRect(x: 5, y: 10, width: 40, height: 3)
        let half = GaugeGeometry.fillRect(track: track, fraction: 0.5)
        XCTAssertTrue(approxEqual(Double(half.width), 20), "fillRect(0.5) is half the track width")
        XCTAssertTrue(half.origin == track.origin, "fillRect(0.5) keeps the track's origin")
        XCTAssertTrue(half.height == track.height, "fillRect(0.5) keeps the track's height")

        let over = GaugeGeometry.fillRect(track: track, fraction: 1.2)
        XCTAssertTrue(over.width == track.width, "fillRect(1.2) clamps to the full track width")

        let under = GaugeGeometry.fillRect(track: track, fraction: -0.3)
        XCTAssertTrue(under.width == 0, "fillRect(-0.3) clamps to zero width")
    }

    // MARK: - StatusBarRenderer.gauges (pure model)

    func testGaugesPureModel() {
        XCTAssertTrue(columnsRemaining.count == 3, "gauges(...) returns one gauge per metric")
        XCTAssertTrue(
            columnsRemaining.map { $0.text } == ["S 89%", "W 45%", "F 20%"],
            "columns text in remaining mode")

        XCTAssertTrue(
            rowsRemaining.map { $0.text } == ["S89", "W45", "F20"],
            "rows text in remaining mode")

        XCTAssertTrue(
            columnsUsed.map { $0.text } == ["S 11%", "W 55%", "F 80%"],
            "columns text in used mode")

        XCTAssertTrue(approxEqual(rowsRemaining[0].fillFraction, 0.89), "session fillFraction in remaining mode")
        XCTAssertTrue(approxEqual(rowsRemaining[1].fillFraction, 0.45), "week fillFraction in remaining mode")
        XCTAssertTrue(approxEqual(rowsRemaining[2].fillFraction, 0.20), "fable fillFraction in remaining mode")

        XCTAssertTrue(rowsRemaining[0].fillColor == base, "session (89% remaining) fill is the base color")
        XCTAssertTrue(rowsRemaining[0].textColor == .labelColor, "session (89% remaining) text is label color")
        XCTAssertTrue(rowsRemaining[1].fillColor == base, "week (45% remaining) fill is the base color")
        XCTAssertTrue(rowsRemaining[1].textColor == .labelColor, "week (45% remaining) text is label color")
        XCTAssertTrue(rowsRemaining[2].fillColor == .systemOrange, "fable (20% remaining) fill is orange")
        XCTAssertTrue(rowsRemaining[2].textColor == .systemOrange, "fable (20% remaining) text is orange")

        let critical = Metric(key: MetricKey.session, usedPct: 95, remainingPct: 5, reset: nil)
        let criticalGauge = StatusBarRenderer.gauges(
            presentations: presentations([critical], numbers: .remaining), layout: .rows, baseColor: base)[0]
        XCTAssertTrue(criticalGauge.fillColor == .systemRed, "5% remaining fill is red")
        XCTAssertTrue(criticalGauge.textColor == .systemRed, "5% remaining text is red")

        // A snapshot missing a metric (e.g. an older CLI without a Fable line)
        // must still produce one gauge per metric present, not three.
        let partialGauges = StatusBarRenderer.gauges(
            presentations: presentations([session, week], numbers: .remaining), layout: .rows, baseColor: base)
        XCTAssertTrue(partialGauges.count == 2, "gauges(...) with 2 metrics returns 2 gauges")
    }

    // MARK: - StatusBarRenderer.image / placeholderImage (AppKit drawing)

    func testImageAndPlaceholderRendering() {
        let columnsImage = StatusBarRenderer.image(gauges: columnsRemaining, layout: .columns, countdownLines: nil)
        XCTAssertTrue(columnsImage.size.width > 0, "columns image has positive width")
        XCTAssertTrue(columnsImage.size.height == 20, "columns image height is 20")
        XCTAssertTrue(columnsImage.isTemplate == false, "columns image is not a template image")
        forceDraw(columnsImage)

        let rowsImage = StatusBarRenderer.image(gauges: rowsRemaining, layout: .rows, countdownLines: nil)
        XCTAssertTrue(rowsImage.size.width > 0, "rows image has positive width")
        XCTAssertTrue(rowsImage.size.height == 20, "rows image height is 20")
        XCTAssertTrue(rowsImage.isTemplate == false, "rows image is not a template image")
        forceDraw(rowsImage)

        let placeholder = StatusBarRenderer.placeholderImage(text: "CL ...", color: .labelColor)
        XCTAssertTrue(placeholder.size.height == 20, "placeholder image height is 20")
        XCTAssertTrue(placeholder.size.width > 0, "placeholder image has positive width")
        XCTAssertTrue(placeholder.isTemplate == false, "placeholder image is not a template image")
        forceDraw(placeholder)
    }

    // MARK: - A1 regression: no gauge's measured text exceeds its cell width.
    //
    // "S100" fit the old hard-coded rowTextWidth of 18, but "W100" did not
    // (and still measures wider than rowMinTextWidth at the current 7pt
    // semibold row font): `layout(for:layout:)` must measure every gauge's
    // text via the production `font(for:)` and widen the cell instead of
    // clipping whatever doesn't fit a fixed constant.

    func testTextFitsWithinMeasuredCellWidth() {
        let boundaryMetrics: [Metric] = [
            Metric(key: MetricKey.session, usedPct: 0, remainingPct: 100, reset: nil),
            Metric(key: MetricKey.week, usedPct: 100, remainingPct: 0, reset: nil),
            Metric(key: MetricKey.fable, usedPct: 0, remainingPct: 100, reset: nil),
        ]
        for testLayout in Display.BarLayout.allCases {
            for numbers in Display.NumberMode.allCases {
                var boundaryGauges = StatusBarRenderer.gauges(
                    presentations: presentations(boundaryMetrics, numbers: numbers),
                    layout: testLayout, baseColor: base)
                // Direct construction via the package init, covering "W100"
                // itself regardless of which `NumberMode` produces it above.
                boundaryGauges.append(
                    BarGauge(text: "W100", fillFraction: 1.0, fillColor: base, textColor: .labelColor))

                let font = StatusBarRenderer.font(for: testLayout)
                let (size, cells, _) = StatusBarRenderer.layout(for: boundaryGauges, layout: testLayout)
                XCTAssertTrue(
                    cells.count == boundaryGauges.count,
                    "layout(for:layout:) cell count matches gauge count (\(testLayout), \(numbers))")
                XCTAssertTrue(
                    size.width > 0 && size.height > 0,
                    "layout(for:layout:) produces a positive image size (\(testLayout), \(numbers))")
                for (gauge, cell) in zip(boundaryGauges, cells) {
                    let measured = StatusBarRenderer.textWidth(gauge.text, font: font)
                    XCTAssertTrue(
                        measured <= cell.textRect.width + 0.01,
                        "\"\(gauge.text)\" (\(testLayout)) fits its cell's textRect width")
                }
            }
        }
    }

    // MARK: - Countdown cell (GaugeGeometry pure geometry)

    func testCountdownCellGeometry() {
        let countdownWidth: CGFloat = 26
        // Two representative line-height fixtures: one that sums to exactly
        // `imageHeight` (the maximizer's usual result — mirrors the spec's own
        // 9/11 example) and one that leaves slack, to pin the group-centering
        // behavior distinctly from the exact-fit case.
        let exactTwoLineHeights: [CGFloat] = [9, 11]
        let slackTwoLineHeights: [CGFloat] = [6, 8]
        let oneLineHeightsFixtures: [[CGFloat]] = [[10], [15]]

        for cellCount in 1...3 {
            // columns
            let absentColumnsSize = GaugeGeometry.columnsImageSize(cellCount: cellCount, columnWidth: sampleColumnWidth)
            let presentColumnsSize = GaugeGeometry.columnsImageSize(
                cellCount: cellCount, columnWidth: sampleColumnWidth, countdownWidth: countdownWidth)
            XCTAssertTrue(
                approxEqual(
                    Double(presentColumnsSize.width),
                    Double(absentColumnsSize.width + GaugeGeometry.columnGap + countdownWidth)),
                "columns image width grows by gap+countdownWidth (\(cellCount) cell(s))")
            XCTAssertTrue(
                presentColumnsSize.height == absentColumnsSize.height,
                "columns image height unaffected by countdown (\(cellCount) cell(s))")

            let zeroColumnsSize = GaugeGeometry.columnsImageSize(
                cellCount: cellCount, columnWidth: sampleColumnWidth, countdownWidth: 0)
            XCTAssertTrue(
                zeroColumnsSize == absentColumnsSize,
                "columns countdownWidth 0 matches the absent-countdown size exactly (\(cellCount) cell(s))")

            let columnsCells = GaugeGeometry.columnsFrames(cellCount: cellCount, columnWidth: sampleColumnWidth)
            let presentColumnsBounds = CGRect(origin: .zero, size: presentColumnsSize)
                .insetBy(dx: -geometryEpsilon, dy: -geometryEpsilon)

            for lineHeights in oneLineHeightsFixtures + [exactTwoLineHeights, slackTwoLineHeights] {
                let label = "\(lineHeights.count) line(s), heights \(lineHeights)"
                let noRects = GaugeGeometry.columnsCountdownRects(
                    cellCount: cellCount, columnWidth: sampleColumnWidth, countdownWidth: 0, lineHeights: lineHeights)
                XCTAssertTrue(
                    noRects == nil,
                    "columns countdown rects nil when countdownWidth is 0 (\(cellCount) cell(s), \(label))")

                let rects = GaugeGeometry.columnsCountdownRects(
                    cellCount: cellCount, columnWidth: sampleColumnWidth, countdownWidth: countdownWidth,
                    lineHeights: lineHeights)!
                XCTAssertTrue(
                    rects.count == lineHeights.count,
                    "columns countdown rects count matches lineHeights.count (\(cellCount) cell(s), \(label))")
                for (rect, height) in zip(rects, lineHeights) {
                    XCTAssertTrue(
                        presentColumnsBounds.contains(rect),
                        "columns countdown rect fits the (widened) image (\(cellCount) cell(s), \(label))")
                    XCTAssertTrue(
                        approxEqual(Double(rect.width), Double(countdownWidth)),
                        "columns countdown rect width equals countdownWidth (\(cellCount) cell(s), \(label))")
                    XCTAssertTrue(
                        approxEqual(Double(rect.height), Double(height)),
                        "columns countdown rect height equals its own line's box height (\(cellCount) cell(s), \(label))"
                    )
                    for cell in columnsCells {
                        XCTAssertTrue(
                            !cell.textRect.intersects(rect) && !cell.barRect.intersects(rect),
                            "columns countdown rect does not overlap a gauge cell (\(cellCount) cell(s), \(label))")
                    }
                }
                // The group is centered as a whole inside imageHeight: the total
                // (sum of box heights) fits, and any leftover slack splits evenly
                // above the first box and below the last.
                let total = lineHeights.reduce(0, +)
                let expectedTopInset = max(0, (GaugeGeometry.imageHeight - total) / 2)
                XCTAssertTrue(
                    approxEqual(Double(rects[0].minY), Double(expectedTopInset)),
                    "columns countdown group top inset centers it in imageHeight (\(cellCount) cell(s), \(label))")
                XCTAssertTrue(
                    approxEqual(Double(rects[rects.count - 1].maxY), Double(expectedTopInset + total)),
                    "columns countdown group bottom edge matches its centered position (\(cellCount) cell(s), \(label))"
                )
                for i in 0..<(rects.count - 1) {
                    XCTAssertTrue(
                        approxEqual(Double(rects[i].maxY), Double(rects[i + 1].minY)),
                        "columns countdown lines \(i)/\(i + 1) meet with no gap or overlap (\(cellCount) cell(s), \(label))"
                    )
                }
            }

            // rows
            let absentRowsSize = GaugeGeometry.rowsImageSize(cellCount: cellCount, textWidth: sampleRowTextWidth)
            let presentRowsSize = GaugeGeometry.rowsImageSize(
                cellCount: cellCount, textWidth: sampleRowTextWidth, countdownWidth: countdownWidth)
            XCTAssertTrue(
                approxEqual(
                    Double(presentRowsSize.width),
                    Double(absentRowsSize.width + GaugeGeometry.columnGap + countdownWidth)),
                "rows image width grows by gap+countdownWidth (\(cellCount) cell(s))")
            XCTAssertTrue(
                presentRowsSize.height == absentRowsSize.height,
                "rows image height unaffected by countdown (\(cellCount) cell(s))")

            let zeroRowsSize = GaugeGeometry.rowsImageSize(
                cellCount: cellCount, textWidth: sampleRowTextWidth, countdownWidth: 0)
            XCTAssertTrue(
                zeroRowsSize == absentRowsSize,
                "rows countdownWidth 0 matches the absent-countdown size exactly (\(cellCount) cell(s))")

            let rowsCells = GaugeGeometry.rowsFrames(cellCount: cellCount, textWidth: sampleRowTextWidth)
            let presentRowsBounds = CGRect(origin: .zero, size: presentRowsSize)
                .insetBy(dx: -geometryEpsilon, dy: -geometryEpsilon)
            let rowsBlockHeight = presentRowsSize.height

            for lineHeights in oneLineHeightsFixtures + [exactTwoLineHeights, slackTwoLineHeights] {
                let label = "\(lineHeights.count) line(s), heights \(lineHeights)"
                let noRects = GaugeGeometry.rowsCountdownRects(
                    cellCount: cellCount, textWidth: sampleRowTextWidth, countdownWidth: 0, lineHeights: lineHeights)
                XCTAssertTrue(
                    noRects == nil, "rows countdown rects nil when countdownWidth is 0 (\(cellCount) cell(s), \(label))"
                )

                let rects = GaugeGeometry.rowsCountdownRects(
                    cellCount: cellCount, textWidth: sampleRowTextWidth, countdownWidth: countdownWidth,
                    lineHeights: lineHeights)!
                XCTAssertTrue(
                    rects.count == lineHeights.count,
                    "rows countdown rects count matches lineHeights.count (\(cellCount) cell(s), \(label))")
                for (rect, height) in zip(rects, lineHeights) {
                    XCTAssertTrue(
                        presentRowsBounds.contains(rect),
                        "rows countdown rect fits the (widened) image (\(cellCount) cell(s), \(label))")
                    XCTAssertTrue(
                        approxEqual(Double(rect.width), Double(countdownWidth)),
                        "rows countdown rect width equals countdownWidth (\(cellCount) cell(s), \(label))")
                    XCTAssertTrue(
                        approxEqual(Double(rect.height), Double(height)),
                        "rows countdown rect height equals its own line's box height (\(cellCount) cell(s), \(label))")
                    for cell in rowsCells {
                        XCTAssertTrue(
                            !cell.textRect.intersects(rect) && !cell.barRect.intersects(rect),
                            "rows countdown rect does not overlap a gauge cell (\(cellCount) cell(s), \(label))")
                    }
                }
                let total = lineHeights.reduce(0, +)
                let expectedTopInset = max(0, (rowsBlockHeight - total) / 2)
                XCTAssertTrue(
                    approxEqual(Double(rects[0].minY), Double(expectedTopInset)),
                    "rows countdown group top inset centers it in the block height (\(cellCount) cell(s), \(label))")
                XCTAssertTrue(
                    approxEqual(Double(rects[rects.count - 1].maxY), Double(expectedTopInset + total)),
                    "rows countdown group bottom edge matches its centered position (\(cellCount) cell(s), \(label))")
                for i in 0..<(rects.count - 1) {
                    XCTAssertTrue(
                        approxEqual(Double(rects[i].maxY), Double(rects[i + 1].minY)),
                        "rows countdown lines \(i)/\(i + 1) meet with no gap or overlap (\(cellCount) cell(s), \(label))"
                    )
                }
            }
        }
    }

    // MARK: - Countdown line box height (StatusBarRenderer.countdownLineBoxHeight)

    func testCountdownLineBoxHeight() {
        let digitFont = NSFont.monospacedDigitSystemFont(ofSize: 20, weight: .bold)
        XCTAssertTrue(
            approxEqual(
                Double(StatusBarRenderer.countdownLineBoxHeight("2:39", font: digitFont)),
                Double(ceil(digitFont.capHeight) + 1)),
            "a digits/colon/period-only line boxes to capHeight+1")
        XCTAssertTrue(
            approxEqual(
                Double(StatusBarRenderer.countdownLineBoxHeight("0:16", font: digitFont)),
                Double(ceil(digitFont.capHeight) + 1)),
            "a digits/colon-only line boxes to capHeight+1 regardless of leading digit")
        XCTAssertTrue(
            approxEqual(
                Double(StatusBarRenderer.countdownLineBoxHeight("2.3d", font: digitFont)),
                Double(ceil(digitFont.ascender))),
            "a line with a letter glyph (\"d\") boxes to the font's full ascender")
        XCTAssertTrue(
            approxEqual(
                Double(StatusBarRenderer.countdownLineBoxHeight("5:00", font: digitFont)),
                Double(ceil(digitFont.capHeight) + 1)),
            "an hour-only clock line still boxes to capHeight+1 (no letters)")
    }

    // MARK: - Countdown font (StatusBarRenderer.countdownFont maximizer)

    func testCountdownFontMaximizer() {
        // "As large as possible" must actually mean maximal: the picked size
        // fits, but one point larger would not.
        let countdownLineFixtures: [[String]] = [["16m"], ["2.3d"], ["2:39", "2.3d"]]
        for lines in countdownLineFixtures {
            let picked = StatusBarRenderer.countdownFont(lines: lines)
            let pickedHeight = lines.reduce(CGFloat(0)) {
                $0 + StatusBarRenderer.countdownLineBoxHeight($1, font: picked)
            }
            XCTAssertTrue(
                pickedHeight <= GaugeGeometry.imageHeight,
                "countdownFont(lines: \(lines)) boxes fit imageHeight")
            let oneUp = NSFont.monospacedDigitSystemFont(ofSize: picked.pointSize + 1, weight: .bold)
            let oneUpHeight = lines.reduce(CGFloat(0)) {
                $0 + StatusBarRenderer.countdownLineBoxHeight($1, font: oneUp)
            }
            XCTAssertTrue(
                oneUpHeight > GaugeGeometry.imageHeight,
                "countdownFont(lines: \(lines)) is maximal: one point larger overflows imageHeight")
        }
        // Two stacked lines each get less room than one, so the picked size for
        // 2 lines must be no larger than for 1.
        XCTAssertTrue(
            StatusBarRenderer.countdownFont(lines: ["2:39", "2.3d"]).pointSize
                <= StatusBarRenderer.countdownFont(lines: ["2.3d"]).pointSize,
            "countdownFont for 2 lines is no larger than for 1 line")
        // Pinned per the validated design: "H:MM" over "X.Yd" (top box 9,
        // bottom box 11) lands on exactly 11pt.
        XCTAssertTrue(
            StatusBarRenderer.countdownFont(lines: ["2:39", "2.3d"]).pointSize == 11,
            "countdownFont([\"2:39\", \"2.3d\"]) is 11pt")
    }

    // MARK: - Placeholder countdown line (no-session regression)
    //
    // A session with no reset anchor used to drop its line, leaving the week
    // countdown alone in the cell and sized to the full image height - nearly
    // twice its usual size. The dashed stand-in restores the two-line size
    // without widening the status item.

    func testPlaceholderCountdownLineKeepsTheTwoLineSize() {
        let live = ["2:39", "2.3d"]
        let dashed = [Display.unknownClockCountdown, "2.3d"]
        let weekAlone = ["2.3d"]

        XCTAssertTrue(
            StatusBarRenderer.countdownFont(lines: dashed).pointSize
                == StatusBarRenderer.countdownFont(lines: live).pointSize,
            "a dashed session line sizes the countdown font exactly as a live one does")
        XCTAssertTrue(
            StatusBarRenderer.countdownFont(lines: dashed).pointSize
                < StatusBarRenderer.countdownFont(lines: weekAlone).pointSize,
            "the dashed two-line readout is smaller than the week line alone (the bug)")

        for testLayout in Display.BarLayout.allCases {
            let gauges = StatusBarRenderer.gauges(
                presentations: presentations(metrics, numbers: .remaining), layout: testLayout, baseColor: base)
            let liveImage = StatusBarRenderer.image(gauges: gauges, layout: testLayout, countdownLines: live)
            let dashedImage = StatusBarRenderer.image(gauges: gauges, layout: testLayout, countdownLines: dashed)
            XCTAssertTrue(
                dashedImage.size.width <= liveImage.size.width,
                "the dashed readout is no wider than the live one (\(testLayout))")
            XCTAssertTrue(
                dashedImage.size.height == liveImage.size.height,
                "the dashed readout keeps the image height (\(testLayout))")
            forceDraw(dashedImage)  // must not crash
        }
    }

    // MARK: - Countdown cell (StatusBarRenderer drawing)

    func testCountdownCellDrawing() {
        let twoLineCountdown = ["2:39", "2.3d"]
        let oneLineCountdown = ["0:16"]
        for testLayout in Display.BarLayout.allCases {
            let gauges = StatusBarRenderer.gauges(
                presentations: presentations(metrics, numbers: .remaining), layout: testLayout, baseColor: base)
            let absentImage = StatusBarRenderer.image(gauges: gauges, layout: testLayout, countdownLines: nil)

            for lines in [oneLineCountdown, twoLineCountdown] {
                let presentImage = StatusBarRenderer.image(gauges: gauges, layout: testLayout, countdownLines: lines)
                let cdFont = StatusBarRenderer.countdownFont(lines: lines)
                let maxLineWidth = lines.map { StatusBarRenderer.textWidth($0, font: cdFont) }.max()!
                let expectedWidth = absentImage.size.width + GaugeGeometry.columnGap + maxLineWidth
                XCTAssertTrue(
                    approxEqual(Double(presentImage.size.width), Double(expectedWidth)),
                    "image(...) width with a \(lines.count)-line countdown grows by gap+max line width (\(testLayout))")
                XCTAssertTrue(
                    presentImage.isTemplate == false,
                    "countdown image is not a template image (\(testLayout), \(lines.count) line(s))")
                forceDraw(presentImage)  // must not crash

                let lineHeights = lines.map { StatusBarRenderer.countdownLineBoxHeight($0, font: cdFont) }
                let (_, _, countdownRects) = StatusBarRenderer.layout(
                    for: gauges, layout: testLayout, countdownWidth: maxLineWidth, countdownLineHeights: lineHeights)
                for (line, rect) in zip(lines, countdownRects!) {
                    let measured = StatusBarRenderer.textWidth(line, font: cdFont)
                    XCTAssertTrue(
                        measured <= rect.width + 0.01,
                        "\"\(line)\" fits its measured countdown rect width (\(testLayout), \(lines.count) line(s))")
                }
            }

            // Absent countdown (nil) reproduces the no-countdown size exactly.
            let stillAbsentImage = StatusBarRenderer.image(gauges: gauges, layout: testLayout, countdownLines: nil)
            XCTAssertTrue(
                stillAbsentImage.size == absentImage.size,
                "image(...) with countdownLines nil reproduces the no-countdown size (\(testLayout))")
        }
    }
}
