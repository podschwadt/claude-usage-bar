import AppKit

/// All user-facing formatting lives here so the menu bar and the dropdown
/// cannot drift apart.
package enum Display {

    /// How the three gauges are arranged in the menu bar.
    package enum BarLayout: String, CaseIterable {
        case columns, rows

        package var title: String {
            switch self {
            case .columns: return "Columns"
            case .rows: return "Rows"
            }
        }
    }

    /// Whether numbers (and bar fill) express headroom left or quota consumed.
    package enum NumberMode: String, CaseIterable {
        case remaining, used

        package var title: String {
            switch self {
            case .remaining: return "Remaining %"
            case .used: return "Used %"
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

    /// Remaining-percent thresholds below which the readout turns red or
    /// orange to flag that a quota is running low.
    package static let criticalRemainingPct: Double = 10
    package static let warningRemainingPct: Double = 25

    /// Where a remaining-percent value falls on the low-headroom warning
    /// ladder: `.critical` at or below `criticalRemainingPct`, `.warning` at
    /// or below `warningRemainingPct`, `.normal` above both.
    package enum Severity: Equatable {
        case normal, warning, critical
    }

    /// Classifies a remaining percentage on the `Severity` ladder.
    package static func severity(remaining: Double) -> Severity {
        if remaining <= criticalRemainingPct { return .critical }
        if remaining <= warningRemainingPct { return .warning }
        return .normal
    }

    /// Text tint for a warning band: only deviates from the default label
    /// colour when the number deserves attention, the native macOS
    /// convention.
    package static func color(band: Severity) -> NSColor {
        switch band {
        case .critical: return .systemRed
        case .warning: return .systemOrange
        case .normal: return .labelColor
        }
    }

    /// Fill tint for a warning band: same low-headroom warning as
    /// `color(band:)`, but falls back to the user's chosen base colour once
    /// headroom is comfortable.
    package static func barFillColor(band: Severity, base: NSColor) -> NSColor {
        switch band {
        case .critical: return .systemRed
        case .warning: return .systemOrange
        case .normal: return base
        }
    }

    /// "16m", "2h39m", "2d18h" - the largest one or two units that fit,
    /// larger unit first - compact enough for a menu or panel row.
    package static func countdown(seconds: Int?) -> String? {
        guard let s = seconds, s > 0 else { return nil }
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return h > 0 ? "\(d)d\(h)h" : "\(d)d" }
        if h > 0 { return m > 0 ? "\(h)h\(m)m" : "\(h)h" }
        return "\(max(1, m))m"
    }

    /// "2:39", "0:16", "0:00" - the menu bar's top countdown line: hours
    /// (unpadded) and minutes (zero-padded) until the session resets,
    /// however many hours that is. Pins at "0:00" for zero/negative seconds
    /// (the true remaining time at or past the reset moment); nil only when
    /// the anchor itself is unknown.
    package static func clockCountdown(seconds: Int?) -> String? {
        guard let s = seconds else { return nil }
        guard s > 0 else { return "0:00" }
        let h = s / 3600, m = (s % 3600) / 60
        return String(format: "%d:%02d", h, m)
    }

    /// "2.3d", "0.5d", "0.0d" - the menu bar's bottom countdown line: days
    /// until the week resets, to one decimal place. Pins at "0.0d" for
    /// zero/negative seconds (the true remaining time at or past the reset
    /// moment); nil only when the anchor itself is unknown.
    package static func daysCountdown(seconds: Int?) -> String? {
        guard let s = seconds else { return nil }
        guard s > 0 else { return "0.0d" }
        return String(format: "%.1fd", Double(s) / 86400)
    }

    /// Stand-ins for a countdown whose anchor is unknown: each live format
    /// with every variable digit dashed out, so the line keeps its width and
    /// shape without implying a time.
    package static let unknownClockCountdown = "-:--"
    package static let unknownDaysCountdown = "-.-d"

    /// The menu bar's stacked countdown lines - session over week, in that
    /// order. A metric present in the snapshot always contributes a line: an
    /// unknown reset anchor dashes out (`unknownClockCountdown` /
    /// `unknownDaysCountdown`) rather than dropping out, since the countdown
    /// font grows to fill the cell and a lone surviving line would otherwise
    /// render at roughly twice the usual two-line size. Nil when neither
    /// metric is present, which draws no countdown cell at all.
    package static func countdownLines(session: MetricState?, week: MetricState?) -> [String]? {
        let lines = [
            session.map { clockCountdown(seconds: $0.remainingSeconds) ?? unknownClockCountdown },
            week.map { daysCountdown(seconds: $0.remainingSeconds) ?? unknownDaysCountdown },
        ].compactMap { $0 }
        return lines.isEmpty ? nil : lines
    }

    /// Whole numbers print without a decimal ("96%"); a fractional value
    /// keeps one decimal place ("96.5%").
    package static func pct(_ value: Double) -> String {
        value == value.rounded()
            ? String(format: "%.0f%%", value)
            : String(format: "%.1f%%", value)
    }

    /// Rounds half away from zero (0.5 -> "1", unlike `%.0f`'s round-half-to-
    /// even, which would print "0"), without the percent sign, for the
    /// narrow rows layout where every character counts.
    package static func wholeNumber(_ value: Double) -> String {
        String(Int(value.rounded()))
    }

    /// The canonical percentage tracked internally is quota used; remaining
    /// headroom is always derived from it.
    package static func remainingPct(fromUsed usedPct: Double) -> Double {
        100 - usedPct
    }

    /// Picks the used or remaining view of a used-percent value.
    package static func displayPct(usedPct: Double, mode: NumberMode) -> Double {
        switch mode {
        case .used: return usedPct
        case .remaining: return remainingPct(fromUsed: usedPct)
        }
    }

    /// The bar-fill fraction for a used-percent value, clamped to a valid
    /// fraction regardless of how far outside 0...100 the input strays.
    package static func fillFraction(usedPct: Double, mode: NumberMode) -> Double {
        (displayPct(usedPct: usedPct, mode: mode) / 100).clamped(to: 0...1)
    }

    /// Formatters for `queried_at`, built once rather than per call. Both
    /// fractional (microsecond) and whole-second timestamps parse; the
    /// parser emits the fractional form.
    private static let iso8601WithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let iso8601Plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Parses an ISO 8601 timestamp such as `queried_at`. Tries fractional
    /// seconds first (the parser's usual format, since a bare
    /// `ISO8601DateFormatter()` rejects those and would otherwise always
    /// fail), then falls back to the no-fraction variant.
    package static func iso8601Date(_ string: String) -> Date? {
        iso8601WithFraction.date(from: string) ?? iso8601Plain.date(from: string)
    }

    /// A date/time template, resolved against a locale rather than pinned to
    /// literal digits, so the macOS "24-Hour Time" setting is respected
    /// instead of only ever printing 24-hour strings.
    package enum TimeFormat {
        /// "14:32" / "2:32 PM" - a bare hour-and-minute skeleton.
        case time
        /// "12:03:14" / "12:03:14 PM" - adds seconds.
        case timeWithSeconds
        /// "Thu 4 14:32" / "Thu 4 2:32 PM" - weekday, day-of-month, time.
        case dayAndTime
        /// "Thu 4" - weekday and day-of-month, no time field at all.
        case day

        /// The `dateFormat(fromTemplate:options:locale:)` skeleton for this
        /// case. `j` is the locale-resolved hour field - the whole reason
        /// this enum exists instead of a literal pattern like `"HH:mm"`.
        fileprivate var template: String {
            switch self {
            case .time: return "jm"
            case .timeWithSeconds: return "jms"
            case .dayAndTime: return "EEEdjm"
            case .day: return "EEEd"
            }
        }
    }

    /// Cache key for a formatter resolved from a `TimeFormat` template
    /// against a specific locale. Includes the RESOLVED pattern string
    /// (from `DateFormatter.dateFormat(fromTemplate:options:locale:)`), not
    /// just the template and a locale identifier, because two `Locale`
    /// values can share an identifier string while resolving the `j` hour
    /// field differently: `Locale.current` (like `.autoupdatingCurrent`)
    /// carries the live System Settings 24-hour override, while a pinned
    /// `Locale(identifier: Locale.current.identifier)` reads the same
    /// identifier but does not - it falls back to the locale's own default
    /// hour cycle. Keying on the identifier alone would let a pinned-locale
    /// request collide with (and return) a cached `.current`/
    /// `.autoupdatingCurrent` formatter, or vice versa, purely because the
    /// identifier strings coincide. Keying on the resolved pattern instead
    /// makes the two cases distinct whenever they actually behave
    /// differently, and `localeKey(for:)` is kept alongside it only to keep
    /// `.autoupdatingCurrent` entries namespaced apart from pinned locales
    /// that happen to resolve to the identical pattern.
    private struct TimeFormatterKey: Hashable {
        let format: TimeFormat
        let localeKey: String
        let resolvedPattern: String
    }

    /// "$autoupdatingCurrent" for `Locale.autoupdatingCurrent` itself, else
    /// the locale's own identifier - see `TimeFormatterKey`.
    private static func localeKey(for locale: Locale) -> String {
        locale == Locale.autoupdatingCurrent ? "$autoupdatingCurrent" : locale.identifier
    }

    /// The pattern `format`'s template resolves to against `locale` - a
    /// cheap static call (`DateFormatter.dateFormat(fromTemplate:options:
    /// locale:)`) that allocates no formatter, used both as the actual
    /// `dateFormat` and as the disambiguating half of `TimeFormatterKey`.
    private static func resolvedPattern(for format: TimeFormat, locale: Locale) -> String {
        DateFormatter.dateFormat(fromTemplate: format.template, options: 0, locale: locale) ?? format.template
    }

    private static var timeFormatterCache: [TimeFormatterKey: DateFormatter] = [:]
    private static let timeFormatterCacheLock = NSLock()

    /// Drops every cached formatter so the next `string(_:_:locale:)` call
    /// re-resolves against the current locale. `DateFormatter` freezes its
    /// resolved `dateFormat` at configuration time, so without this a
    /// running app would keep printing 24-hour strings after the user flips
    /// System Settings' "24-Hour Time" toggle mid-session.
    private static func invalidateTimeFormatterCache() {
        timeFormatterCacheLock.lock()
        timeFormatterCache.removeAll()
        timeFormatterCacheLock.unlock()
    }

    private static let localeChangeObserver: NSObjectProtocol = {
        NotificationCenter.default.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification,
            object: nil,
            queue: nil
        ) { _ in
            invalidateTimeFormatterCache()
        }
    }()

    /// Registers `localeChangeObserver` on first use of the time-formatting
    /// path. Reading a `static let` triggers its one-time initializer, which
    /// is all this needs - the returned token is never unregistered because
    /// the observer must live for the process lifetime.
    private static func ensureLocaleObserverRegistered() {
        _ = localeChangeObserver
    }

    private static func timeFormatter(_ format: TimeFormat, locale: Locale) -> DateFormatter {
        ensureLocaleObserverRegistered()
        let pattern = resolvedPattern(for: format, locale: locale)
        let key = TimeFormatterKey(format: format, localeKey: localeKey(for: locale), resolvedPattern: pattern)
        timeFormatterCacheLock.lock()
        defer { timeFormatterCacheLock.unlock() }
        if let cached = timeFormatterCache[key] { return cached }
        let f = DateFormatter()
        f.locale = locale
        f.dateFormat = pattern
        timeFormatterCache[key] = f
        return f
    }

    /// Formats `date` per `format`, resolving the hour convention (12- vs
    /// 24-hour) from `locale` - `.autoupdatingCurrent` in production, pinned
    /// in tests. One entry point for every date/time string in the app, so
    /// the menu bar and the panel cannot drift apart, and so macOS's
    /// 12/24-hour setting is honored everywhere instead of nowhere.
    package static func string(
        _ format: TimeFormat, _ date: Date, locale: Locale = .autoupdatingCurrent
    )
        -> String
    {
        timeFormatter(format, locale: locale).string(from: date)
    }

    /// "13:00" within the session window, "Thu 4" across the week window (a
    /// bare weekday would repeat across exactly 7 days of ticks - "Thu ...
    /// Thu" - so the day-of-month disambiguates which occurrence this is).
    package static func chartTickLabel(
        date: Date, spansDays: Bool, locale: Locale = .autoupdatingCurrent
    ) -> String {
        string(spansDays ? .day : .time, date, locale: locale)
    }

    /// Chart hover-readout time line: "14:32" for the session chart (a
    /// single day, so the time alone disambiguates), "Thu 4 14:32" for the
    /// week chart - unlike `chartTickLabel`'s axis ticks, the hover box
    /// always includes the time regardless of `spansDays`.
    package static func hoverTimeLabel(
        date: Date, spansDays: Bool, locale: Locale = .autoupdatingCurrent
    ) -> String {
        string(spansDays ? .dayAndTime : .time, date, locale: locale)
    }

    /// "12:03:14" - shared by the panel footer and the menu's "Updated" row.
    package static func clockTime(_ date: Date, locale: Locale = .autoupdatingCurrent) -> String {
        string(.timeWithSeconds, date, locale: locale)
    }

    /// Formats `date` as an ISO 8601 string with fractional seconds - the
    /// inverse of `iso8601Date(_:)`, reusing the same formatter so the two
    /// stay in sync. Used to synthesize `queried_at` strings for debug
    /// scenarios; production snapshots always carry a server-provided string.
    package static func iso8601String(_ date: Date) -> String {
        iso8601WithFraction.string(from: date)
    }

    /// "Session — 96% left · resets in 16m". `remainingSeconds` must come
    /// from the anchor rule (`PanelModel.remainingSeconds`), never from the
    /// snapshot's `seconds_until`, which is frozen at fetch time and drifts
    /// stale between polls.
    package static func menuRow(for metric: Metric, remainingSeconds: Int?) -> String {
        var text = "\(name(for: metric.key))  —  \(pct(metric.remainingPct)) left"
        if let c = countdown(seconds: remainingSeconds) {
            text += "  ·  resets in \(c)"
        } else if let raw = metric.reset?.raw {
            text += "  ·  resets \(raw)"
        }
        return text
    }
}
