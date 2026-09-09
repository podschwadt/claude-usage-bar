import AppKit

/// Draws one chart (session: 1 series; week: 2 series) from a `PanelModel`
/// section, or a centered placeholder string when there isn't yet enough
/// history to plot.
final class ChartView: NSView {
    private static let placeholderFontSize: CGFloat = 12
    private static let hoverRuleAlpha: CGFloat = 0.3
    private static let hoverDotDiameter: CGFloat = 6
    private static let hoverBoxCornerRadius: CGFloat = 4
    private static let hoverBoxBackgroundAlpha: CGFloat = 0.8
    private static let hoverBoxPadding: CGFloat = 6
    private static let hoverBoxRowHeight: CGFloat = 14
    private static let hoverBoxSwatchDiameter: CGFloat = 6
    private static let hoverBoxSwatchGap: CGFloat = 5
    private static let hoverBoxGapFromPoint: CGFloat = 8
    private static let hoverBoxLabelValueGap: CGFloat = 6
    private static let hoverTimeFontSize: CGFloat = 11
    private static let hoverValueFontSize: CGFloat = 11

    private let series: [ChartSeriesModel]
    private let timeWindow: TimeWindow
    private let placeholder: String?
    private let spansDays: Bool

    /// View-local hover state (not part of `PanelModel` - purely a per-view
    /// interaction concern): the mouse's x position in the view's own
    /// coordinate space, or nil when the mouse is outside the chart.
    private var hoverX: CGFloat?

    override var isFlipped: Bool { true }

    init(series: [ChartSeriesModel], window: TimeWindow, placeholder: String?, spansDays: Bool, frame: CGRect) {
        self.series = series
        self.timeWindow = window
        self.placeholder = placeholder
        self.spansDays = spansDays
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        fatalError("ChartView does not support coding")
    }

    /// `.activeAlways` because this is an `LSUIElement` accessory app: it is
    /// never the active application, so the usual `.activeInKeyWindow`
    /// tracking option would silently never fire.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self, userInfo: nil))
    }

    /// Placeholder-state charts (no series points) ignore hover: there is
    /// nothing to snap to.
    override func mouseMoved(with event: NSEvent) {
        guard placeholder == nil else { return }
        hoverX = convert(event.locationInWindow, from: nil).x
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hoverX = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: CGRect) {
        if let placeholder {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: Self.placeholderFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let text = NSAttributedString(string: placeholder, attributes: attributes)
            let size = text.size()
            text.draw(at: CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
            return
        }

        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let gridColor = (isDark ? NSColor.white : NSColor.black).withAlphaComponent(0.06)

        // Reserve a strip below the plot rect for x-axis tick labels and a
        // gutter to its left for y-axis percent labels, so both draw clear
        // of the grid/series instead of on top of the gradient fill.
        let plotRect = CGRect(
            x: bounds.minX + ChartRenderer.yAxisGutterWidth, y: bounds.minY,
            width: bounds.width - ChartRenderer.yAxisGutterWidth,
            height: bounds.height - ChartRenderer.tickLabelStripHeight)

        // Reversed: `ChartRenderer` paints back to front, so handing it the
        // series in reverse puts the model's first series (the primary one -
        // week, not fable) on top, while hover readout rows below keep the
        // model's own order.
        let drawSeries = series.reversed().map {
            (color: $0.color, points: ChartGeometry.points(segment: $0.points, window: timeWindow, rect: plotRect))
        }
        let tickLabels = ChartGeometry.ticks(
            window: timeWindow, maxCount: ChartGeometry.maxTickCount,
            offsetFromGMT: TimeZone.current.secondsFromGMT()
        ).map { ts in
            (
                x: ChartGeometry.xPosition(ts: ts, window: timeWindow, rect: plotRect),
                label: Display.chartTickLabel(date: Date(timeIntervalSince1970: TimeInterval(ts)), spansDays: spansDays)
            )
        }
        let yAxisLabels = zip(ChartGeometry.gridFractions, ChartGeometry.gridYs(rect: plotRect)).map { fraction, y in
            (y: y, label: "\(Int(fraction))%")
        }
        let model = ChartDrawModel(
            gridColor: gridColor, series: drawSeries, tickLabels: tickLabels, yAxisLabels: yAxisLabels)
        ChartRenderer.draw(model, plotRect: plotRect, scale: window?.backingScaleFactor ?? 2)

        if let hoverX, plotRect.width > 0 {
            drawHover(at: hoverX, plotRect: plotRect, isDark: isDark)
        }
    }

    /// AppKit-only hover readout (untested per this project's convention -
    /// only the pure `ChartGeometry.nearestIndex` helper it calls is unit
    /// tested): a vertical hairline at the snapped x, a dot on each series at
    /// its nearest sample, and a compact box giving the time plus each
    /// series' displayed % at that sample.
    private func drawHover(at x: CGFloat, plotRect: CGRect, isDark: Bool) {
        let snappedX = x.clamped(to: plotRect.minX...plotRect.maxX)

        let rule = NSBezierPath()
        rule.move(to: CGPoint(x: snappedX, y: plotRect.minY))
        rule.line(to: CGPoint(x: snappedX, y: plotRect.maxY))
        rule.lineWidth = 1
        NSColor.labelColor.withAlphaComponent(Self.hoverRuleAlpha).setStroke()
        rule.stroke()

        var hoverTs: Int?
        var anchor: CGPoint?
        var rows: [(color: NSColor, label: String?, value: String)] = []
        for s in series {
            guard
                let index = ChartGeometry.nearestIndex(
                    points: s.points, x: snappedX, window: timeWindow, rect: plotRect)
            else { continue }
            let sample = s.points[index]
            let mapped = ChartGeometry.points(segment: [sample], window: timeWindow, rect: plotRect)[0]
            if hoverTs == nil { hoverTs = sample.ts }
            if anchor == nil || mapped.y < anchor!.y { anchor = mapped }  // topmost dot anchors the box

            let dotRect = CGRect(
                x: mapped.x - Self.hoverDotDiameter / 2, y: mapped.y - Self.hoverDotDiameter / 2,
                width: Self.hoverDotDiameter, height: Self.hoverDotDiameter)
            s.color.setFill()
            NSBezierPath(ovalIn: dotRect).fill()

            rows.append((color: s.color, label: s.label, value: Display.pct(sample.value)))
        }
        guard let hoverTs, let anchor else { return }

        let time = Display.hoverTimeLabel(
            date: Date(timeIntervalSince1970: TimeInterval(hoverTs)), spansDays: spansDays)
        drawReadoutBox(time: time, rows: rows, anchor: anchor, plotRect: plotRect, isDark: isDark)
    }

    /// Draws the hover readout box - background, border, and its text/swatch
    /// rows - at the rect `ChartGeometry.readoutBoxRect` places for `anchor`
    /// (the topmost hovered dot). Labeled rows (the week chart) align in two
    /// columns - legend name left, value right-aligned to the box edge - so
    /// the numbers line up; unlabeled rows draw the value beside the swatch.
    private func drawReadoutBox(
        time: String, rows: [(color: NSColor, label: String?, value: String)],
        anchor: CGPoint, plotRect: CGRect, isDark: Bool
    ) {
        let timeFont = NSFont.systemFont(ofSize: Self.hoverTimeFontSize, weight: .semibold)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: Self.hoverValueFontSize, weight: .regular)
        let timeText = NSAttributedString(
            string: time,
            attributes: [
                .font: timeFont, .foregroundColor: NSColor.labelColor,
            ])
        let labelTexts = rows.map { row in
            row.label.map {
                NSAttributedString(string: $0, attributes: [.font: valueFont, .foregroundColor: row.color])
            }
        }
        let valueTexts = rows.map {
            NSAttributedString(string: $0.value, attributes: [.font: valueFont, .foregroundColor: $0.color])
        }

        let swatchColumn = Self.hoverBoxSwatchDiameter + Self.hoverBoxSwatchGap
        let labelColumn: CGFloat =
            labelTexts.compactMap { $0?.size().width }.max()
            .map { $0 + Self.hoverBoxLabelValueGap } ?? 0
        let rowWidths = valueTexts.map { labelColumn + $0.size().width }
        let size = ChartGeometry.readoutBoxSize(
            timeWidth: timeText.size().width, rowWidths: rowWidths,
            rowHeight: Self.hoverBoxRowHeight, swatchColumn: swatchColumn, padding: Self.hoverBoxPadding)
        let box = ChartGeometry.readoutBoxRect(
            anchor: anchor, size: size, gap: Self.hoverBoxGapFromPoint, plotRect: plotRect)

        let path = NSBezierPath(
            roundedRect: box, xRadius: Self.hoverBoxCornerRadius, yRadius: Self.hoverBoxCornerRadius)
        (isDark ? NSColor.black : NSColor.white).withAlphaComponent(Self.hoverBoxBackgroundAlpha).setFill()
        path.fill()
        NSColor.gray.setStroke()
        path.lineWidth = 1
        path.stroke()

        var y = box.minY + Self.hoverBoxPadding
        timeText.draw(at: CGPoint(x: box.minX + Self.hoverBoxPadding, y: y))
        y += Self.hoverBoxRowHeight
        for i in rows.indices {
            let (labelText, valueText) = (labelTexts[i], valueTexts[i])
            rows[i].color.setFill()
            NSBezierPath(
                ovalIn: CGRect(
                    x: box.minX + Self.hoverBoxPadding,
                    y: y + (Self.hoverBoxRowHeight - Self.hoverBoxSwatchDiameter) / 2,
                    width: Self.hoverBoxSwatchDiameter, height: Self.hoverBoxSwatchDiameter
                )
            ).fill()
            let textX = box.minX + Self.hoverBoxPadding + swatchColumn
            if let labelText {
                labelText.draw(at: CGPoint(x: textX, y: y))
                valueText.draw(at: CGPoint(x: box.maxX - Self.hoverBoxPadding - valueText.size().width, y: y))
            } else {
                valueText.draw(at: CGPoint(x: textX, y: y))
            }
            y += Self.hoverBoxRowHeight
        }
    }
}
