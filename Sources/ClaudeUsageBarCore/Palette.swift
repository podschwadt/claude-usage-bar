import AppKit

/// Named bar-fill themes echoing the iStat Menus palette, as Apple's system
/// tints: dynamic colors that adapt to Light/Dark Mode and Increase Contrast.
package enum BarColor: String, CaseIterable {
    case blue, green, yellow, orange, red, pink, purple, graphite

    package var title: String {
        rawValue.capitalized
    }

    package var nsColor: NSColor {
        switch self {
        case .blue: return .systemBlue
        case .green: return .systemGreen
        case .yellow: return .systemYellow
        case .orange: return .systemOrange
        case .red: return .systemRed
        case .pink: return .systemPink
        case .purple: return .systemPurple
        case .graphite: return .systemGray
        }
    }
}

/// The panel's custom tints as dynamic colors: AppKit resolves them against
/// the drawing view's effective appearance inside `draw(_:)`, so views need
/// no light/dark branching. The caption and rule tints keep their original
/// white values as the dark variants; the light variants are black at a
/// slightly lower alpha, since black on a light backdrop reads heavier than
/// white on a dark one. The grid and hover box tints keep both of their
/// original values.
package extension NSColor {
    /// Section titles and ring labels. Custom rather than a semantic label
    /// tint: in the original Dark Mode tuning, `secondaryLabelColor` and
    /// `tertiaryLabelColor` read too dim against the panel's vibrancy
    /// material and full white too bright.
    static let panelCaption = dynamic(
        "panelCaption",
        light: NSColor(white: 0, alpha: 0.6),
        dark: NSColor(white: 1, alpha: 0.7))

    /// Hairline rules flanking a section title; dimmer than the title.
    static let panelRule = dynamic(
        "panelRule",
        light: NSColor(white: 0, alpha: 0.2),
        dark: NSColor(white: 1, alpha: 0.24))

    /// Chart gridlines.
    static let chartGrid = dynamic(
        "chartGrid",
        light: NSColor(white: 0, alpha: 0.06),
        dark: NSColor(white: 1, alpha: 0.06))

    /// Backdrop of the chart's hover box: the appearance's base tone, so the
    /// series-colored text on it keeps its contrast.
    static let chartHoverBoxBackground = dynamic(
        "chartHoverBoxBackground",
        light: NSColor(white: 1, alpha: 0.8),
        dark: NSColor(white: 0, alpha: 0.8))

    /// `name` identifies the color when debugging. `bestMatch` folds each
    /// appearance's high-contrast and vibrant variants into plain aqua or
    /// darkAqua.
    private static func dynamic(_ name: String, light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: NSColor.Name(name)) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    /// ASCII hex digits only; `Character.isHexDigit` also admits fullwidth
    /// digit forms, which are not valid here.
    private static let hexDigits = Set("0123456789abcdefABCDEF")

    /// Accepts "RRGGBB" with an optional leading "#"; nil for anything else.
    /// Each of the 6 characters must be an ASCII hex digit: checking that
    /// explicitly (rather than trusting `UInt32(_:radix:)`) rejects a value
    /// like "+0A84F", which that initializer would otherwise parse as a
    /// signed integer. Backs the `barColorHex` override, a fixed color by
    /// design.
    convenience init?(hexString: String) {
        var digits = hexString
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.count == 6, digits.allSatisfy({ Self.hexDigits.contains($0) }),
            let value = UInt32(digits, radix: 16)
        else { return nil }

        let red = CGFloat((value >> 16) & 0xFF) / 255
        let green = CGFloat((value >> 8) & 0xFF) / 255
        let blue = CGFloat(value & 0xFF) / 255
        self.init(srgbRed: red, green: green, blue: blue, alpha: 1)
    }
}
