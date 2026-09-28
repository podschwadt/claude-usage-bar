import AppKit

/// Panel content views built from a `PanelModel`: the section header rule,
/// the ring gauges row, and one label/value stat row.
///
/// Every color set here adapts to the appearance — the `labelColor` family,
/// the panel tints in Palette.swift, and the model's system tints — so the
/// views carry no light/dark state; AppKit redraws them when the effective
/// appearance changes. The one fixed color is a `barColorHex` override,
/// which stays put by design.

/// Centered "SESSION" / "THIS WEEK" style section title: uppercase, kerned,
/// in the panel caption tint, with a hairline rule flanking each side.
package final class SectionHeaderView: NSView {
    private static let fontSize: CGFloat = 10
    private static let kern: CGFloat = 1.0
    private static let ruleGap: CGFloat = 8

    private let attributedTitle: NSAttributedString

    package init(title: String, frame: CGRect) {
        attributedTitle = NSAttributedString(
            string: title.uppercased(),
            attributes: [
                .font: NSFont.systemFont(ofSize: Self.fontSize, weight: .medium),
                .foregroundColor: NSColor.panelCaption,
                .kern: Self.kern,
            ])
        super.init(frame: frame)
    }

    package required init?(coder: NSCoder) {
        fatalError("SectionHeaderView does not support coding")
    }

    package override func draw(_ dirtyRect: CGRect) {
        let labelSize = attributedTitle.size()
        let labelRect = CGRect(
            x: (bounds.width - labelSize.width) / 2, y: (bounds.height - labelSize.height) / 2,
            width: labelSize.width, height: labelSize.height)
        attributedTitle.draw(in: labelRect)

        let midY = bounds.midY
        let path = NSBezierPath()
        path.move(to: CGPoint(x: 0, y: midY))
        path.line(to: CGPoint(x: max(0, labelRect.minX - Self.ruleGap), y: midY))
        path.move(to: CGPoint(x: labelRect.maxX + Self.ruleGap, y: midY))
        path.line(to: CGPoint(x: bounds.width, y: midY))
        path.lineWidth = 1
        NSColor.panelRule.setStroke()
        path.stroke()
    }
}

/// Three ring ("countdown wheel") gauges — session, week, Fable — evenly
/// spaced across the row, iStat-battery style: a track at low alpha, an arc
/// over it covering the metric's displayed fraction, the displayed % big in
/// the center and a small caption beneath.
package final class RingsRowView: NSView {
    private static let valueFontSize: CGFloat = 17
    private static let captionFontSize: CGFloat = 12
    private static let captionGap: CGFloat = 2
    private static let labelFontSize: CGFloat = 10
    private static let labelKern: CGFloat = 1.0
    private static let trackAlpha: CGFloat = 0.2

    private let rings: [RingModel]

    package override var isFlipped: Bool { true }

    package init(rings: [RingModel], frame: CGRect) {
        self.rings = rings
        super.init(frame: frame)
    }

    package required init?(coder: NSCoder) {
        fatalError("RingsRowView does not support coding")
    }

    package override func draw(_ dirtyRect: CGRect) {
        guard !rings.isEmpty else { return }
        let slotWidth = bounds.width / CGFloat(rings.count)
        let ringCenterY =
            PanelGeometry.ringsRowVerticalPadding + PanelGeometry.ringLabelHeight
            + PanelGeometry.ringLabelGap + PanelGeometry.ringDiameter / 2
        for (i, ring) in rings.enumerated() {
            let centerX = slotWidth * (CGFloat(i) + 0.5)
            Self.drawLabel(ring.label, centerX: centerX, y: PanelGeometry.ringsRowVerticalPadding)
            Self.draw(ring, center: CGPoint(x: centerX, y: ringCenterY))
        }
    }

    private static func drawLabel(_ label: String, centerX: CGFloat, y: CGFloat) {
        let text = NSAttributedString(
            string: label,
            attributes: [
                .font: NSFont.systemFont(ofSize: labelFontSize, weight: .medium),
                .foregroundColor: NSColor.panelCaption,
                .kern: labelKern,
            ])
        let size = text.size()
        text.draw(at: CGPoint(x: centerX - size.width / 2, y: y))
    }

    private static func draw(_ ring: RingModel, center: CGPoint) {
        let radius = (PanelGeometry.ringDiameter - PanelGeometry.ringStrokeWidth) / 2
        let ovalRect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)

        let track = NSBezierPath(ovalIn: ovalRect)
        track.lineWidth = PanelGeometry.ringStrokeWidth
        ring.color.withAlphaComponent(trackAlpha).setStroke()
        track.stroke()

        if ring.fraction > 0 {
            let arc = PanelGeometry.ringArc(fraction: ring.fraction)
            let fill = NSBezierPath()
            fill.appendArc(
                withCenter: center, radius: radius, startAngle: arc.start, endAngle: arc.end, clockwise: false)
            fill.lineWidth = PanelGeometry.ringStrokeWidth
            fill.lineCapStyle = .round
            ring.color.setStroke()
            fill.stroke()
        }

        let valueText = NSAttributedString(
            string: ring.value,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: valueFontSize, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
            ])
        let captionText: NSAttributedString? =
            ring.caption.isEmpty
            ? nil
            : NSAttributedString(
                string: ring.caption,
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: captionFontSize, weight: .medium),
                    .foregroundColor: NSColor.labelColor,
                ])

        let valueSize = valueText.size()
        let captionSize = captionText?.size() ?? .zero
        let blockHeight = valueSize.height + (captionText == nil ? 0 : captionGap + captionSize.height)

        var y = center.y - blockHeight / 2
        valueText.draw(at: CGPoint(x: center.x - valueSize.width / 2, y: y))
        if let captionText {
            y += valueSize.height + captionGap
            captionText.draw(at: CGPoint(x: center.x - captionSize.width / 2, y: y))
        }
    }
}
