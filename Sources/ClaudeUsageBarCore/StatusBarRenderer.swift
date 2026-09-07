import AppKit

/// One gauge cell: everything the drawing code needs, nothing it must compute.
package struct BarGauge {
    package let text: String
    package let fillFraction: Double
    package let fillColor: NSColor
    package let textColor: NSColor

    /// Explicit for cross-module test fixtures (see `ResetInfo.init`).
    package init(text: String, fillFraction: Double, fillColor: NSColor, textColor: NSColor) {
        self.text = text
        self.fillFraction = fillFraction
        self.fillColor = fillColor
        self.textColor = textColor
    }
}

/// Builds the menu bar gauge images. Split into a pure model step
/// (`gauges(...)`, unit-tested without a graphics context) and an AppKit
/// drawing step (`image(...)`), matching the split in `Display`.
package enum StatusBarRenderer {

    package static let columnFontSize: CGFloat = 9
    package static let rowFontSize: CGFloat = 7
    package static let placeholderFontSize: CGFloat = 9
    /// Rows run heavier than columns: at this small a point size, semibold
    /// reads more legibly than medium without needing more vertical space.
    static let columnFontWeight: NSFont.Weight = .medium
    static let rowFontWeight: NSFont.Weight = .semibold
    static let trackColor = NSColor.tertiaryLabelColor

    /// The countdown draws in its own, much larger font (see `countdownFont`)
    /// rather than the gauge font, so it reads at a glance; that size alone
    /// makes the two-line readout the most prominent thing in the menu bar
    /// cell, so it uses the same semantic `labelColor` as the gauge text and
    /// inverts with the menu bar appearance.
    static let countdownFontWeight: NSFont.Weight = .regular
    /// Upper bound for `countdownFont`'s size search: far beyond any size
    /// that could fit `GaugeGeometry.imageHeight`, just a loop backstop.
    private static let maxCountdownFontSize = 200

    /// PURE (unit-tested): presentations -> drawable gauge models. The mode
    /// and threshold math is already resolved in `MetricPresentation`; this
    /// only formats text and maps bands to colors.
    package static func gauges(
        presentations: [MetricPresentation], layout: Display.BarLayout, baseColor: NSColor
    ) -> [BarGauge] {
        presentations.map { p in
            let tag = Display.tag(for: p.key)
            let text: String
            switch layout {
            case .columns: text = "\(tag) \(Display.pct(p.displayedPct))"
            case .rows: text = "\(tag)\(Display.wholeNumber(p.displayedPct))"
            }
            return BarGauge(
                text: text,
                fillFraction: p.fillFraction,
                fillColor: Display.barFillColor(band: p.band, base: baseColor),
                textColor: Display.color(band: p.band)
            )
        }
    }

    /// AppKit: the font used to measure and draw a given layout's gauge text.
    package static func font(for layout: Display.BarLayout) -> NSFont {
        switch layout {
        case .columns: return NSFont.monospacedDigitSystemFont(ofSize: columnFontSize, weight: columnFontWeight)
        case .rows: return NSFont.monospacedDigitSystemFont(ofSize: rowFontSize, weight: rowFontWeight)
        }
    }

    /// AppKit: `text`'s rendered width in `font`, rounded up so
    /// `NSAttributedString.draw(in:)` never silently clips the trailing
    /// glyph of a rect sized from a truncated measurement.
    package static func textWidth(_ text: String, font: NSFont) -> CGFloat {
        ceil(NSAttributedString(string: text, attributes: [.font: font]).size().width)
    }

    /// AppKit: the vertical box one countdown line needs at `font`'s size. A
    /// line with any letter glyph (e.g. "d"/"h" in "2.3d") can rise above cap
    /// height into the font's ascender, so it needs the full ascender; a
    /// line of only digits/colon/period (e.g. "2:39") never does, and needs
    /// only cap height plus a point of breathing room.
    package static func countdownLineBoxHeight(_ line: String, font: NSFont) -> CGFloat {
        line.contains(where: \.isLetter) ? ceil(font.ascender) : ceil(font.capHeight) + 1
    }

    /// AppKit: the largest whole-point monospaced-digit size whose `lines`,
    /// each boxed per `countdownLineBoxHeight`, still sum to no more than
    /// `GaugeGeometry.imageHeight` - the countdown's "as large as possible"
    /// requirement, encoded as a search over candidate sizes bounded by
    /// `imageHeight`, with per-line box heights (rather than one worst-case
    /// metric shared by every line) so a digits-only line does not pay for
    /// room a letter-bearing line alone would need.
    package static func countdownFont(lines: [String]) -> NSFont {
        var best = NSFont.monospacedDigitSystemFont(ofSize: 1, weight: countdownFontWeight)
        for size in 2...maxCountdownFontSize {
            let candidate = NSFont.monospacedDigitSystemFont(ofSize: CGFloat(size), weight: countdownFontWeight)
            let totalHeight = lines.reduce(CGFloat(0)) { $0 + countdownLineBoxHeight($1, font: candidate) }
            guard totalHeight <= GaugeGeometry.imageHeight else { break }
            best = candidate
        }
        return best
    }

    /// PURE geometry (unit-tested): image size + per-cell frames for
    /// `gauges`, measuring every gauge's text so a wide value (e.g. "W100")
    /// is never clipped by an under-sized cell. `countdownWidth` (0 =
    /// absent) reserves a trailing text-only cell for the countdown, stacked
    /// as `countdownLineHeights.count` (1 or 2) rects sized per
    /// `countdownLineHeights`; `countdownRects` is nil exactly when
    /// `countdownWidth` is 0.
    package static func layout(
        for gauges: [BarGauge], layout: Display.BarLayout,
        countdownWidth: CGFloat = 0, countdownLineHeights: [CGFloat] = []
    )
        -> (size: CGSize, cells: [GaugeGeometry.CellFrames], countdownRects: [CGRect]?)
    {
        let font = Self.font(for: layout)
        let measuredWidth = gauges.map { textWidth($0.text, font: font) }.max() ?? 0
        switch layout {
        case .columns:
            let columnWidth = max(GaugeGeometry.columnMinWidth, measuredWidth)
            return (
                GaugeGeometry.columnsImageSize(
                    cellCount: gauges.count, columnWidth: columnWidth,
                    countdownWidth: countdownWidth),
                GaugeGeometry.columnsFrames(cellCount: gauges.count, columnWidth: columnWidth),
                GaugeGeometry.columnsCountdownRects(
                    cellCount: gauges.count, columnWidth: columnWidth,
                    countdownWidth: countdownWidth, lineHeights: countdownLineHeights)
            )
        case .rows:
            let width = max(GaugeGeometry.rowMinTextWidth, measuredWidth)
            return (
                GaugeGeometry.rowsImageSize(
                    cellCount: gauges.count, textWidth: width,
                    countdownWidth: countdownWidth),
                GaugeGeometry.rowsFrames(cellCount: gauges.count, textWidth: width),
                GaugeGeometry.rowsCountdownRects(
                    cellCount: gauges.count, textWidth: width,
                    countdownWidth: countdownWidth, lineHeights: countdownLineHeights)
            )
        }
    }

    /// AppKit: measures text, computes frames, draws tracks/fills/text, plus
    /// the optional trailing countdown cell (nil hides it — the toggle-off
    /// or unknown-anchor state), stacked one line per array element, each
    /// line drawn in `countdownFont(lines:)` and `NSColor.labelColor`, which
    /// resolves against the menu bar's appearance at draw time — a font of
    /// its own, not the layout's gauge font, since it draws much larger than
    /// the gauge numbers beside it.
    package static func image(gauges: [BarGauge], layout: Display.BarLayout, countdownLines: [String]?) -> NSImage {
        let font = Self.font(for: layout)
        let cdFont = countdownLines.map { countdownFont(lines: $0) }
        let countdownLineHeights: [CGFloat] = {
            guard let countdownLines, let cdFont else { return [] }
            return countdownLines.map { countdownLineBoxHeight($0, font: cdFont) }
        }()
        let countdownWidth: CGFloat = {
            guard let countdownLines, let cdFont else { return 0 }
            return countdownLines.map { textWidth($0, font: cdFont) }.max() ?? 0
        }()
        let (size, frames, countdownRects) = Self.layout(
            for: gauges, layout: layout, countdownWidth: countdownWidth,
            countdownLineHeights: countdownLineHeights)

        let columnParagraphStyle = NSMutableParagraphStyle()
        columnParagraphStyle.alignment = .center

        let image = NSImage(size: size, flipped: true) { _ in
            for (gauge, cell) in zip(gauges, frames) {
                let track = NSBezierPath(
                    roundedRect: cell.barRect,
                    xRadius: GaugeGeometry.barCornerRadius,
                    yRadius: GaugeGeometry.barCornerRadius)
                trackColor.setFill()
                track.fill()

                // A gauge with any fill at all still gets a visible nub: the
                // track alone would otherwise be indistinguishable from 0%.
                if gauge.fillFraction > 0 {
                    let fillRect = GaugeGeometry.fillRect(track: cell.barRect, fraction: gauge.fillFraction)
                    let visibleWidth = max(fillRect.width, GaugeGeometry.barCornerRadius * 2)
                    let fill = NSBezierPath(
                        roundedRect: CGRect(
                            x: fillRect.minX, y: fillRect.minY,
                            width: visibleWidth, height: fillRect.height),
                        xRadius: GaugeGeometry.barCornerRadius,
                        yRadius: GaugeGeometry.barCornerRadius)
                    gauge.fillColor.setFill()
                    fill.fill()
                }

                switch layout {
                case .columns:
                    NSAttributedString(
                        string: gauge.text,
                        attributes: [
                            .font: font, .foregroundColor: gauge.textColor,
                            .paragraphStyle: columnParagraphStyle,
                        ]
                    ).draw(in: cell.textRect)
                case .rows:
                    let textRect = verticallyCentered(textRect: cell.textRect, font: font)
                    NSAttributedString(
                        string: gauge.text,
                        attributes: [
                            .font: font, .foregroundColor: gauge.textColor,
                        ]
                    ).draw(in: textRect)
                }
            }

            if let countdownLines, let cdFont, let countdownRects {
                for (line, rect) in zip(countdownLines, countdownRects) {
                    let textRect = verticallyCentered(textRect: rect, font: cdFont)
                    var attributes: [NSAttributedString.Key: Any] = [
                        .font: cdFont, .foregroundColor: NSColor.labelColor,
                    ]
                    // Columns center gauge text horizontally in its cell (see
                    // above); the countdown lines can differ in measured
                    // width ("2h" vs "39m"), so they get the same treatment.
                    // Rows draw gauge text left-aligned, so the countdown
                    // follows suit there too.
                    if layout == .columns { attributes[.paragraphStyle] = columnParagraphStyle }
                    NSAttributedString(string: line, attributes: attributes).draw(in: textRect)
                }
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// AppKit: one-line text image for the loading and error states.
    package static func placeholderImage(text: String, color: NSColor) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: placeholderFontSize, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let measured = NSAttributedString(string: text, attributes: attributes).size()
        let size = CGSize(width: ceil(measured.width), height: GaugeGeometry.imageHeight)

        let image = NSImage(size: size, flipped: true) { _ in
            let textRect = CGRect(
                x: 0, y: (size.height - measured.height) / 2,
                width: size.width, height: measured.height)
            NSAttributedString(string: text, attributes: attributes).draw(in: textRect)
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Positions a row's text so the font's cap-height glyphs sit centered in
    /// the row. The returned rect is expanded to the font's full line height:
    /// `draw(in:)` clips to its rect, and the row is shorter than the line
    /// box, so drawing into the row rect itself would crop the glyph bottoms.
    /// Row text is tags and digits (no descenders), so the extra rect height
    /// only ever covers empty space in the inter-row gap.
    private static func verticallyCentered(textRect: CGRect, font: NSFont) -> CGRect {
        let lineHeight = font.ascender - font.descender  // descender is negative
        let capTop = textRect.midY - font.capHeight / 2
        let top = capTop - (font.ascender - font.capHeight)
        return CGRect(x: textRect.minX, y: top, width: textRect.width, height: ceil(lineHeight))
    }
}
