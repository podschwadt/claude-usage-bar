import AppKit

/// Panel content views built from a `PanelModel`: the section header rule,
/// the ring gauges row, and one label/value stat row.

/// 70% white, per user request - semantic separator/tertiary tints read too
/// dark against this panel's vibrancy material, full white too bright.
fileprivate let captionTint = NSColor(white: 1, alpha: 0.7)

/// Centered "SESSION" / "THIS WEEK" style section title: uppercase, kerned,
/// tertiary label color, with a hairline rule flanking each side.
final class SectionHeaderView: NSView {
    private static let fontSize: CGFloat = 10
    private static let kern: CGFloat = 1.0
    private static let ruleGap: CGFloat = 8
    /// 24% white, per user request — the flanking rules recede while the
    /// title itself keeps the brighter `captionTint`.
    private static let ruleTint = NSColor(white: 1, alpha: 0.24)

    private let attributedTitle: NSAttributedString

    init(title: String, frame: CGRect) {
        attributedTitle = NSAttributedString(
            string: title.uppercased(),
            attributes: [
                .font: NSFont.systemFont(ofSize: Self.fontSize, weight: .medium),
                .foregroundColor: captionTint,
                .kern: Self.kern,
            ])
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        fatalError("SectionHeaderView does not support coding")
    }

    override func draw(_ dirtyRect: CGRect) {
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
        Self.ruleTint.setStroke()
        path.stroke()
    }
}

/// Three ring ("countdown wheel") gauges — session, week, Fable — evenly
/// spaced across the row, iStat-battery style: a track at low alpha, an arc
/// over it covering the metric's displayed fraction, the displayed % big in
/// the center and a small caption beneath.
final class RingsRowView: NSView {
    private static let valueFontSize: CGFloat = 17
    private static let captionFontSize: CGFloat = 12
    private static let captionGap: CGFloat = 2
    private static let labelFontSize: CGFloat = 10
    private static let labelKern: CGFloat = 1.0
    private static let trackAlpha: CGFloat = 0.2

    private let rings: [RingModel]

    override var isFlipped: Bool { true }

    init(rings: [RingModel], frame: CGRect) {
        self.rings = rings
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        fatalError("RingsRowView does not support coding")
    }

    override func draw(_ dirtyRect: CGRect) {
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
                .foregroundColor: captionTint,
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
                    .foregroundColor: NSColor.white,
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
