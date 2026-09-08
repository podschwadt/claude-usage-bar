import AppKit

/// Precomputed drawing inputs for one chart: colors and screen-space points
/// already produced by `ChartGeometry`. `ChartRenderer` only strokes and
/// fills what it is handed - no geometry math lives here.
package struct ChartDrawModel {
    package let gridColor: NSColor
    package let series: [(color: NSColor, points: [CGPoint])]
    package let tickLabels: [(x: CGFloat, label: String)]
    package let yAxisLabels: [(y: CGFloat, label: String)]

    package init(
        gridColor: NSColor, series: [(color: NSColor, points: [CGPoint])],
        tickLabels: [(x: CGFloat, label: String)], yAxisLabels: [(y: CGFloat, label: String)]
    ) {
        self.gridColor = gridColor
        self.series = series
        self.tickLabels = tickLabels
        self.yAxisLabels = yAxisLabels
    }
}

/// AppKit chart drawing: horizontal grid, per-series line + gradient fill,
/// x-axis tick labels, y-axis percent labels. Series are painted back to
/// front in array order, so the last series in `model.series` ends up on
/// top of the ones before it. Fills and lines are two separate passes -
/// every fill, then every line - so no series' line is ever veiled by a
/// later series' translucent fill; only lines can occlude lines. Straight segments only, no
/// smoothing, matching the iStat design spec. Assumes the caller draws
/// inside a flipped view (see `ChartGeometry`'s own doc comment:
/// `plotRect.minY` is a displayed 100%, `plotRect.maxY` the 0% baseline)
/// and that `plotRect` already excludes the tick-label strip below it (see
/// `tickLabelStripHeight`) and the y-axis gutter to its left (see
/// `yAxisGutterWidth`) — grid and series fills stop at `plotRect`'s edges,
/// so a label drawn inside `plotRect` would sit on top of them instead of
/// clear of them.
package enum ChartRenderer {
    private static let tickFontSize: CGFloat = 9
    private static let tickLabelAlpha: CGFloat = 0.5
    private static let tickLabelHeight: CGFloat = 12
    private static let tickLabelGap: CGFloat = 4
    // Series lines are stroked well above hairline width so overlapping
    // series stay distinguishable, and their fills are kept faint enough
    // that two or three stacked gradients do not muddy into one wash.
    private static let seriesLineWidth: CGFloat = 1.5
    private static let fillAlphaAtLine: CGFloat = 0.28
    private static let fillAlphaAtBaseline: CGFloat = 0.06
    private static let yAxisLabelFontSize: CGFloat = 9
    private static let yAxisLabelAlpha: CGFloat = 0.5
    private static let yAxisLabelGap: CGFloat = 4

    /// Vertical space the caller must reserve below `plotRect` for tick
    /// labels: `plotRect = bounds` shortened at the bottom by exactly this
    /// much, so the grid/series never draw under the label strip and the
    /// labels never draw under the grid/series.
    package static let tickLabelStripHeight: CGFloat = tickLabelHeight + tickLabelGap

    /// Horizontal space the caller must reserve on the left of `plotRect`
    /// for the y-axis percent labels ("0%".."100%"): `plotRect = bounds`
    /// narrowed on the left by exactly this much, the same "reserve a strip,
    /// draw only inside it" rule `tickLabelStripHeight` follows for the
    /// x-axis.
    package static let yAxisGutterWidth: CGFloat = 30

    package static func draw(_ model: ChartDrawModel, plotRect: CGRect, scale: CGFloat) {
        drawGrid(model.gridColor, plotRect: plotRect, scale: scale)
        for series in model.series {
            drawFill(series, plotRect: plotRect)
        }
        for series in model.series {
            drawLine(series)
        }
        drawTickLabels(model.tickLabels, plotRect: plotRect)
        drawYAxisLabels(model.yAxisLabels, plotRect: plotRect)
    }

    private static func drawGrid(_ color: NSColor, plotRect: CGRect, scale: CGFloat) {
        let path = NSBezierPath()
        for y in ChartGeometry.gridYs(rect: plotRect) {
            path.move(to: CGPoint(x: plotRect.minX, y: y))
            path.line(to: CGPoint(x: plotRect.maxX, y: y))
        }
        path.lineWidth = 1 / scale
        color.setStroke()
        path.stroke()
    }

    /// The gradient under one series' line, from the line down to the 0%
    /// baseline. A series with fewer than 2 points has nothing to draw a
    /// line between and is skipped entirely (no lone dot, no empty fill),
    /// here and in `drawLine`.
    private static func drawFill(_ series: (color: NSColor, points: [CGPoint]), plotRect: CGRect) {
        guard series.points.count >= 2 else { return }

        let fillPath = NSBezierPath()
        fillPath.move(to: CGPoint(x: series.points[0].x, y: plotRect.maxY))
        for point in series.points { fillPath.line(to: point) }
        fillPath.line(to: CGPoint(x: series.points[series.points.count - 1].x, y: plotRect.maxY))
        fillPath.close()

        if let gradient = NSGradient(
            starting: series.color.withAlphaComponent(fillAlphaAtLine),
            ending: series.color.withAlphaComponent(fillAlphaAtBaseline)
        ) {
            // Defined by explicit points (not `angle:`) so the direction is
            // unambiguous regardless of the flipped coordinate space: the
            // gradient starts at the series' highest point on screen (where
            // the line sits) and ends at the baseline (0%, plotRect.maxY).
            let lineY = series.points.map(\.y).min() ?? plotRect.minY
            NSGraphicsContext.saveGraphicsState()
            fillPath.addClip()
            gradient.draw(
                from: CGPoint(x: plotRect.midX, y: lineY),
                to: CGPoint(x: plotRect.midX, y: plotRect.maxY))
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// One series' line, drawn opaque over every fill (see `draw`).
    private static func drawLine(_ series: (color: NSColor, points: [CGPoint])) {
        guard series.points.count >= 2 else { return }

        let linePath = NSBezierPath()
        linePath.move(to: series.points[0])
        for point in series.points.dropFirst() { linePath.line(to: point) }
        linePath.lineWidth = seriesLineWidth
        series.color.setStroke()
        linePath.stroke()
    }

    /// Ticks are assumed to already be in ascending x order (the order
    /// `ChartGeometry.ticks` + the caller's mapping produce them in).
    /// Drawn in the strip below `plotRect` (`tickLabelGap` below
    /// `plotRect.maxY`, the caller's reserved `tickLabelStripHeight`),
    /// never inside it — clamped horizontally to `plotRect`'s x range, and
    /// skipped outright if drawing one would overlap the previously drawn
    /// label.
    private static func drawTickLabels(_ labels: [(x: CGFloat, label: String)], plotRect: CGRect) {
        guard !labels.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: tickFontSize),
            .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(tickLabelAlpha),
        ]

        var previousMaxX = -CGFloat.infinity
        for (x, label) in labels {
            let text = NSAttributedString(string: label, attributes: attributes)
            let size = text.size()
            var origin = CGPoint(x: x - size.width / 2, y: plotRect.maxY + tickLabelGap)
            origin.x = max(plotRect.minX, min(origin.x, plotRect.maxX - size.width))

            guard origin.x >= previousMaxX else { continue }
            text.draw(at: origin)
            previousMaxX = origin.x + size.width + tickLabelGap
        }
    }

    /// Drawn right-aligned in the gutter to the left of `plotRect`
    /// (`yAxisLabelGap` clear of `plotRect.minX`, the caller's reserved
    /// `yAxisGutterWidth`), each label vertically centered on its grid line.
    private static func drawYAxisLabels(_ labels: [(y: CGFloat, label: String)], plotRect: CGRect) {
        guard !labels.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: yAxisLabelFontSize),
            .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(yAxisLabelAlpha),
        ]

        for (y, label) in labels {
            let text = NSAttributedString(string: label, attributes: attributes)
            let size = text.size()
            let origin = CGPoint(x: plotRect.minX - yAxisLabelGap - size.width, y: y - size.height / 2)
            text.draw(at: origin)
        }
    }
}
