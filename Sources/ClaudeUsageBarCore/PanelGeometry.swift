import CoreGraphics

/// Layout constants and frame math for the history panel: all section
/// frames, top-down, in a flipped container (y grows downward from the
/// panel's top edge). Pure math, unit-testable without AppKit.
package enum PanelGeometry {

    package static let contentWidth: CGFloat = 280
    /// Top and bottom panel margin; the sides get the wider `sideMargin`.
    package static let margin: CGFloat = 8
    /// Left and right panel margin, wider than the vertical `margin` so the
    /// content sits clear of the glass edges (matching the roomier insets of
    /// the system's menu bar panels).
    package static let sideMargin: CGFloat = 16
    package static let cornerRadius: CGFloat = 12
    package static let sectionHeaderHeight: CGFloat = 30
    package static let chartHeight: CGFloat = 110
    package static let footerTopGap: CGFloat = 8
    package static let footerHeight: CGFloat = 16

    /// The three ring gauges (session/week/fable) at the top of the panel:
    /// diameter fits 3 evenly spaced across `contentWidth` with room either
    /// side, a label line above each ring, and `ringsRowVerticalPadding` of
    /// breathing room above and below.
    package static let ringDiameter: CGFloat = 80
    package static let ringStrokeWidth: CGFloat = 7
    package static let ringLabelHeight: CGFloat = 14
    package static let ringLabelGap: CGFloat = 4
    package static let ringsRowVerticalPadding: CGFloat = 8
    package static let ringsRowHeight: CGFloat =
        ringLabelHeight + ringLabelGap + ringDiameter + 2 * ringsRowVerticalPadding

    /// Full panel width, content plus the left and right side margins.
    package static let panelWidth: CGFloat = contentWidth + 2 * sideMargin

    package struct PanelLayout: Equatable {
        package let size: CGSize
        package let ringsRow: CGRect
        package let sessionHeader: CGRect
        package let sessionChart: CGRect
        package let weekHeader: CGRect
        package let weekChart: CGRect
        package let footer: CGRect
    }

    /// Frames for every panel section, stacked top-down: ring gauges,
    /// session chart group, week chart group, footer. The 30 pt
    /// section-header blocks carry the visual air between groups, so no
    /// extra spacing is added around them; the panel gets `margin` top and
    /// bottom and the wider `sideMargin` on the left and right.
    package static func layout() -> PanelLayout {
        var y = margin

        let ringsRow = CGRect(x: sideMargin, y: y, width: contentWidth, height: ringsRowHeight)
        y += ringsRowHeight

        let sessionHeader = CGRect(x: sideMargin, y: y, width: contentWidth, height: sectionHeaderHeight)
        y += sectionHeaderHeight

        let sessionChart = CGRect(x: sideMargin, y: y, width: contentWidth, height: chartHeight)
        y += chartHeight

        let weekHeader = CGRect(x: sideMargin, y: y, width: contentWidth, height: sectionHeaderHeight)
        y += sectionHeaderHeight

        let weekChart = CGRect(x: sideMargin, y: y, width: contentWidth, height: chartHeight)
        y += chartHeight

        // Breathing room above the footer text; below it only the panel
        // margin remains, keeping the bottom chin small.
        y += footerTopGap
        let footer = CGRect(x: sideMargin, y: y, width: contentWidth, height: footerHeight)
        y += footerHeight + margin

        return PanelLayout(
            size: CGSize(width: panelWidth, height: y),
            ringsRow: ringsRow,
            sessionHeader: sessionHeader,
            sessionChart: sessionChart,
            weekHeader: weekHeader,
            weekChart: weekChart,
            footer: footer
        )
    }

    /// Start/end angles (AppKit path-space degrees: 0 = 3 o'clock, increasing
    /// counterclockwise - the convention `NSBezierPath.appendArc` itself
    /// uses) for a ring gauge's filled arc, covering `fraction` (0...1,
    /// clamped) of the circle. The rings view is FLIPPED, which mirrors
    /// path-space angles vertically: -90 in path space lands on 12 o'clock
    /// on screen (the arc's anchor, its "zero"), and a counterclockwise
    /// path-space sweep (drawn with `clockwise: false`) renders clockwise on
    /// screen - so as the displayed `fraction` shrinks, the arc's tip
    /// counts down counterclockwise back toward the top.
    package static func ringArc(fraction: Double) -> (start: CGFloat, end: CGFloat) {
        let clamped = fraction.clamped(to: 0...1)
        let start: CGFloat = -90
        let end = start + CGFloat(clamped) * 360
        return (start: start, end: end)
    }

    /// Screen-coordinate origin (bottom-left origin, y not flipped) for the
    /// panel, mimicking native menu positioning: the panel's top edge sits
    /// at the status button's bottom (`buttonFrame.minY`), left-aligned to
    /// the button unless that would push the panel past the button's
    /// screen, in which case it right-aligns instead (native menu
    /// behavior). Never clamps x to 0 — a display left of the primary has a
    /// negative `visibleFrame` origin, and left alignment there must return
    /// that true negative x.
    package static func origin(buttonFrame: CGRect, panelSize: CGSize, visibleFrame: CGRect) -> CGPoint {
        let y = buttonFrame.minY - panelSize.height
        let leftAligned = buttonFrame.minX
        let x =
            leftAligned + panelSize.width > visibleFrame.maxX
            ? buttonFrame.maxX - panelSize.width
            : leftAligned
        return CGPoint(x: x, y: y)
    }
}
