import AppKit

/// All user-facing formatting lives here so the menu bar and the dropdown
/// cannot drift apart.
enum Display {

    /// What the compact menu bar readout shows on its first line.
    enum BarMode: String, CaseIterable {
        /// Whichever of session / weekly has less headroom left.
        case auto
        case session
        case week
        case fable

        var title: String {
            switch self {
            case .auto: return "Tightest limit (auto)"
            case .session: return "Session"
            case .week: return "Week (all models)"
            case .fable: return "Fable only"
            }
        }
    }

    /// One-letter tag used in the menu bar, where horizontal space is scarce.
    static func tag(for key: String) -> String {
        switch key {
        case MetricKey.session: return "S"
        case MetricKey.week: return "W"
        case MetricKey.fable: return "F"
        default: return String(key.prefix(1)).uppercased()
        }
    }

    /// Human name used in the dropdown menu.
    static func name(for key: String) -> String {
        switch key {
        case MetricKey.session: return "Session"
        case MetricKey.week: return "Week (all models)"
        case MetricKey.fable: return "Week (Fable)"
        default: return key.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// Menu bar tint: only deviates from the default label colour when the
    /// number deserves attention, which is the native macOS convention.
    static func color(remaining: Double) -> NSColor {
        if remaining <= 10 { return .systemRed }
        if remaining <= 25 { return .systemOrange }
        return .labelColor
    }

    /// "16m", "2h39m", "2d18h" - compact enough for a menu row.
    static func countdown(seconds: Int?) -> String? {
        guard let s = seconds, s > 0 else { return nil }
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return h > 0 ? "\(d)d\(h)h" : "\(d)d" }
        if h > 0 { return m > 0 ? "\(h)h\(m)m" : "\(h)h" }
        return "\(max(1, m))m"
    }

    /// Percentages come back as whole numbers almost always; avoid "96.0%".
    static func pct(_ value: Double) -> String {
        value == value.rounded()
            ? String(format: "%.0f%%", value)
            : String(format: "%.1f%%", value)
    }

    /// "Session — 96% left · resets in 16m"
    static func menuRow(for metric: Metric) -> String {
        var text = "\(name(for: metric.key))  —  \(pct(metric.remainingPct)) left"
        if let c = countdown(seconds: metric.reset?.secondsUntil) {
            text += "  ·  resets in \(c)"
        } else if let raw = metric.reset?.raw {
            text += "  ·  resets \(raw)"
        }
        return text
    }
}
