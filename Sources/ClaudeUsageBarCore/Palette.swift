import AppKit

/// Named bar-fill themes echoing the iStat Menus palette; the hex values are
/// Apple's dark-appearance system tints, which stay readable on both light
/// and dark menu bars.
package enum BarColor: String, CaseIterable {
    case blue, green, yellow, orange, red, pink, purple, graphite

    private static let blueHex = "0A84FF"
    private static let greenHex = "32D74B"
    private static let yellowHex = "FFD60A"
    private static let orangeHex = "FF9F0A"
    private static let redHex = "FF453A"
    private static let pinkHex = "FF375F"
    private static let purpleHex = "BF5AF2"
    private static let graphiteHex = "98989D"

    package var title: String {
        rawValue.capitalized
    }

    package var hex: String {
        switch self {
        case .blue: return Self.blueHex
        case .green: return Self.greenHex
        case .yellow: return Self.yellowHex
        case .orange: return Self.orangeHex
        case .red: return Self.redHex
        case .pink: return Self.pinkHex
        case .purple: return Self.purpleHex
        case .graphite: return Self.graphiteHex
        }
    }

    package var nsColor: NSColor {
        NSColor(hexString: hex) ?? .systemBlue
    }
}

package extension NSColor {
    /// ASCII hex digits only; `Character.isHexDigit` also admits fullwidth
    /// digit forms, which are not valid here.
    private static let hexDigits = Set("0123456789abcdefABCDEF")

    /// Accepts "RRGGBB" with an optional leading "#"; nil for anything else.
    /// Each of the 6 characters must be an ASCII hex digit: checking that
    /// explicitly (rather than trusting `UInt32(_:radix:)`) rejects a value
    /// like "+0A84F", which that initializer would otherwise parse as a
    /// signed integer.
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
