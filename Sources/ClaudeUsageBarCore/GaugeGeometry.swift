import CoreGraphics

/// Geometry for the menu bar gauges; all values in points. Pure math so the
/// frames can be unit-tested without a graphics context.
package enum GaugeGeometry {

    // shared
    package static let barHeight: CGFloat = 3
    package static let barCornerRadius: CGFloat = 1.5
    package static let imageHeight: CGFloat = 20  // centered inside the ~22pt status item

    // columns layout: text over bar, cells side by side (~100pt total for 3)
    package static let columnMinWidth: CGFloat = 28
    package static let columnGap: CGFloat = 4
    package static let columnTextHeight: CGFloat = 11  // 9pt font line height
    package static let columnTextToBarSpacing: CGFloat = 2
    /// The column font's ink sits slightly below center in its nominal line
    /// box; lifting the content by this much corrects for that optically.
    package static let columnOpticalLift: CGFloat = 1

    // rows layout: "S89" text + bar, cells stacked
    package static let rowHeight: CGFloat = 6
    package static let rowGap: CGFloat = 1
    /// Minimum row text column width. Widened per-render when a gauge's
    /// text measures wider than this (e.g. "W100" in the row font), so
    /// `rowsFrames` never clips a glyph.
    package static let rowMinTextWidth: CGFloat = 18
    package static let rowTextToBarGap: CGFloat = 3
    /// Fixed row bar width; unlike the text column, the bar does not grow
    /// with content, so the image width is simply `textWidth + gap + this`.
    package static let rowBarWidth: CGFloat = 30

    package struct CellFrames {
        package let textRect: CGRect
        package let barRect: CGRect
    }

    /// Total width of `cellCount` column cells of the given per-cell width,
    /// laid out left to right with `columnGap` between them. Shared by
    /// `columnsImageSize` and `columnsCountdownRects`, which both need where
    /// the gauge cells end and the trailing countdown cell begins.
    private static func columnsCellsWidth(cellCount: Int, columnWidth: CGFloat) -> CGFloat {
        CGFloat(cellCount) * columnWidth + CGFloat(max(0, cellCount - 1)) * columnGap
    }

    /// The columns layout's shared text-top-inset: vertically centers the
    /// text+bar content group inside `imageHeight`, nudged up by
    /// `columnOpticalLift` to correct for the font's low-sitting ink. Used
    /// by `columnsFrames`; the countdown cell spans the full image height
    /// and centers on its own.
    private static func columnsTextTopInset() -> CGFloat {
        let contentHeight = columnTextHeight + columnTextToBarSpacing + barHeight
        return max(0, (imageHeight - contentHeight) / 2 - columnOpticalLift)
    }

    /// Extra width a trailing countdown cell adds to an image size:
    /// `columnGap + countdownWidth` when present, 0 (no cell, no gap) when
    /// `countdownWidth` is 0 — the toggle-off/no-anchor state must reproduce
    /// the pre-countdown size exactly. Shared by `columnsImageSize` and
    /// `rowsImageSize`.
    private static func countdownExtra(_ countdownWidth: CGFloat) -> CGFloat {
        countdownWidth > 0 ? columnGap + countdownWidth : 0
    }

    /// Total image size for a row of `cellCount` column gauges of the given
    /// per-cell width, laid out left to right with `columnGap` between them,
    /// plus an optional trailing text-only countdown cell of `countdownWidth`
    /// (see `countdownExtra`).
    package static func columnsImageSize(cellCount: Int, columnWidth: CGFloat, countdownWidth: CGFloat = 0) -> CGSize {
        let cellsWidth = columnsCellsWidth(cellCount: cellCount, columnWidth: columnWidth)
        return CGSize(width: cellsWidth + countdownExtra(countdownWidth), height: imageHeight)
    }

    /// Stacked countdown-line rects, one per element of `lineHeights` (1 or
    /// 2 of them, each the box height its line's glyphs need - see
    /// `StatusBarRenderer.countdownLineBoxHeight`), top to bottom in the
    /// order given (the larger unit is always first). The group is centered
    /// as a whole inside `blockHeight`: when the boxes sum to less than
    /// `blockHeight` the slack splits evenly above and below; the maximizer's
    /// usual result sums to exactly `blockHeight`, so the first box then
    /// starts at 0 and the last ends at `blockHeight`. Shared by
    /// `columnsCountdownRects` and `rowsCountdownRects`.
    private static func countdownLineRects(
        x: CGFloat, width: CGFloat, blockHeight: CGFloat,
        lineHeights: [CGFloat]
    ) -> [CGRect] {
        precondition(
            lineHeights.count == 1 || lineHeights.count == 2,
            "countdown lineHeights must have 1 or 2 elements, got \(lineHeights.count)")
        let total = lineHeights.reduce(0, +)
        var y = max(0, (blockHeight - total) / 2)
        return lineHeights.map { height in
            let rect = CGRect(x: x, y: y, width: width, height: height)
            y += height
            return rect
        }
    }

    /// Trailing countdown cell for the columns layout: `lineHeights.count`
    /// rects stacked top to bottom, the group centered inside the full
    /// `imageHeight`, placed after the last gauge cell separated by
    /// `columnGap`. Nil when `countdownWidth` is 0 (no cell drawn).
    package static func columnsCountdownRects(
        cellCount: Int, columnWidth: CGFloat, countdownWidth: CGFloat,
        lineHeights: [CGFloat]
    ) -> [CGRect]? {
        guard countdownWidth > 0 else { return nil }
        let x = columnsCellsWidth(cellCount: cellCount, columnWidth: columnWidth) + columnGap
        return countdownLineRects(x: x, width: countdownWidth, blockHeight: imageHeight, lineHeights: lineHeights)
    }

    /// Per-cell text/bar frames for the columns layout, vertically centered
    /// as a group inside `imageHeight`, with `columnOpticalLift` nudging the
    /// content up to correct for the font's low-sitting ink.
    package static func columnsFrames(cellCount: Int, columnWidth: CGFloat) -> [CellFrames] {
        let topInset = columnsTextTopInset()
        return (0..<cellCount).map { i in
            let x = CGFloat(i) * (columnWidth + columnGap)
            let textRect = CGRect(x: x, y: topInset, width: columnWidth, height: columnTextHeight)
            let barRect = CGRect(
                x: x, y: topInset + columnTextHeight + columnTextToBarSpacing,
                width: columnWidth, height: barHeight)
            return CellFrames(textRect: textRect, barRect: barRect)
        }
    }

    /// Height of `cellCount` stacked row cells, `rowGap` between them.
    /// Shared by every rows-layout function below that needs the stacked
    /// block's own height before centering it inside `imageHeight`.
    private static func rowsContentHeight(cellCount: Int) -> CGFloat {
        CGFloat(cellCount) * rowHeight + CGFloat(max(0, cellCount - 1)) * rowGap
    }

    /// Width of one row cell's text-plus-bar content, before any trailing
    /// countdown cell. Shared by `rowsImageSize` and `rowsCountdownRects`,
    /// which both need where the gauge block ends and the countdown cell
    /// begins.
    private static func rowsWidth(textWidth: CGFloat) -> CGFloat {
        textWidth + rowTextToBarGap + rowBarWidth
    }

    /// Total image size for `cellCount` stacked row gauges of the given text
    /// column width; width is `textWidth + rowTextToBarGap +
    /// rowBarWidth` plus any trailing countdown cell (see `countdownExtra`). Height is `max(imageHeight, contentHeight)` so the
    /// content is never squeezed below the status item's usual height even
    /// when there are only 1 or 2 cells.
    package static func rowsImageSize(cellCount: Int, textWidth: CGFloat, countdownWidth: CGFloat = 0) -> CGSize {
        let contentHeight = rowsContentHeight(cellCount: cellCount)
        return CGSize(
            width: rowsWidth(textWidth: textWidth) + countdownExtra(countdownWidth),
            height: max(imageHeight, contentHeight))
    }

    /// Trailing countdown cell for the rows layout: `lineHeights.count` rects
    /// stacked top to bottom, the group centered inside the stacked-rows
    /// block's full height, placed to the right of the block separated by
    /// `columnGap` (the same side-by-side gap the columns layout uses —
    /// `rowGap`/`rowTextToBarGap` are both intra-block spacings, not a fit
    /// for a block-to-block gap). Nil when `countdownWidth` is 0.
    package static func rowsCountdownRects(
        cellCount: Int, textWidth: CGFloat, countdownWidth: CGFloat,
        lineHeights: [CGFloat]
    ) -> [CGRect]? {
        guard countdownWidth > 0 else { return nil }
        let blockHeight = max(imageHeight, rowsContentHeight(cellCount: cellCount))
        let x = rowsWidth(textWidth: textWidth) + columnGap
        return countdownLineRects(x: x, width: countdownWidth, blockHeight: blockHeight, lineHeights: lineHeights)
    }

    /// Per-cell text/bar frames for the rows layout, stacked top to bottom
    /// with `rowGap` between them and vertically centered as a group inside
    /// `imageHeight`. The bar is always exactly `rowBarWidth` wide.
    package static func rowsFrames(cellCount: Int, textWidth: CGFloat) -> [CellFrames] {
        let contentHeight = rowsContentHeight(cellCount: cellCount)
        let topInset = max(0, (max(imageHeight, contentHeight) - contentHeight) / 2)
        let barX = textWidth + rowTextToBarGap
        return (0..<cellCount).map { i in
            let y = topInset + CGFloat(i) * (rowHeight + rowGap)
            let textRect = CGRect(x: 0, y: y, width: textWidth, height: rowHeight)
            let barRect = CGRect(
                x: barX, y: y + (rowHeight - barHeight) / 2,
                width: rowBarWidth, height: barHeight)
            return CellFrames(textRect: textRect, barRect: barRect)
        }
    }

    /// Left-anchored fill inside a track; fraction is clamped to 0...1.
    package static func fillRect(track: CGRect, fraction: Double) -> CGRect {
        let clamped = fraction.clamped(to: 0...1)
        return CGRect(
            x: track.minX, y: track.minY,
            width: track.width * CGFloat(clamped), height: track.height)
    }
}
