import Foundation

/// User-configurable display and polling settings, carried on
/// `UsageState.prefs` and changed only through `UsageEvent.setPref`.
package struct UsagePrefs: Equatable {
    package var layout: Display.BarLayout
    package var barColor: BarColor
    package var numbers: Display.NumberMode
    /// Poll interval in seconds. Menu choices are 30/60/300/900.
    package var refreshInterval: Int
    package var showCountdown: Bool

    package init(
        layout: Display.BarLayout, barColor: BarColor, numbers: Display.NumberMode,
        refreshInterval: Int, showCountdown: Bool
    ) {
        self.layout = layout
        self.barColor = barColor
        self.numbers = numbers
        self.refreshInterval = refreshInterval
        self.showCountdown = showCountdown
    }

    /// Defaults for a fresh install: columns, blue fill, remaining-percent
    /// numbers, a one-minute poll, countdown shown.
    package static let standard = UsagePrefs(
        layout: .columns, barColor: .blue, numbers: .remaining, refreshInterval: 60, showCountdown: true)
}

/// One pref-change payload, carried by `UsageEvent.setPref` - a single event
/// case rather than one event type per preference.
package enum UsagePref: Equatable {
    case layout(Display.BarLayout)
    case barColor(BarColor)
    case numbers(Display.NumberMode)
    case refreshInterval(Int)
    case showCountdown(Bool)
}

/// Interpreter-side mapping between `UsagePrefs`/`UsagePref` and their
/// on-disk `UserDefaults` representation. Key names and value types are
/// a compatibility contract: prefs saved by any earlier build keep loading
/// unchanged. Raw-value strings for layout/color/numbers,
/// `refreshInterval` as a `Double` (`v > 0 ? Int(v) : 60` for an absent or
/// invalid value), `showCountdown` reading `object(forKey:)` rather than
/// `bool(forKey:)` so an absent key defaults to true instead of `bool`'s
/// false.
package enum PrefsStore {
    private static let layoutKey = "barLayout"
    private static let colorKey = "barColor"
    private static let numbersKey = "barNumbers"
    private static let intervalKey = "refreshInterval"
    private static let showCountdownKey = "showCountdown"

    /// Reads all five prefs, falling back per-field to `UsagePrefs.standard`
    /// when a key is absent or its stored value fails to parse.
    package static func load(from defaults: UserDefaults) -> UsagePrefs {
        let layout =
            Display.BarLayout(rawValue: defaults.string(forKey: layoutKey) ?? "") ?? UsagePrefs.standard.layout
        let barColor = BarColor(rawValue: defaults.string(forKey: colorKey) ?? "") ?? UsagePrefs.standard.barColor
        let numbers =
            Display.NumberMode(rawValue: defaults.string(forKey: numbersKey) ?? "") ?? UsagePrefs.standard.numbers
        let storedInterval = defaults.double(forKey: intervalKey)
        let refreshInterval = storedInterval > 0 ? Int(storedInterval) : UsagePrefs.standard.refreshInterval
        let showCountdown = defaults.object(forKey: showCountdownKey) as? Bool ?? UsagePrefs.standard.showCountdown
        return UsagePrefs(
            layout: layout, barColor: barColor, numbers: numbers,
            refreshInterval: refreshInterval, showCountdown: showCountdown)
    }

    /// Writes ONLY the key `pref` touches, in that key's on-disk type
    /// (raw-value string; `refreshInterval` as `Double`).
    package static func persist(_ pref: UsagePref, to defaults: UserDefaults) {
        switch pref {
        case let .layout(layout): defaults.set(layout.rawValue, forKey: layoutKey)
        case let .barColor(barColor): defaults.set(barColor.rawValue, forKey: colorKey)
        case let .numbers(numbers): defaults.set(numbers.rawValue, forKey: numbersKey)
        case let .refreshInterval(seconds): defaults.set(Double(seconds), forKey: intervalKey)
        case let .showCountdown(on): defaults.set(on, forKey: showCountdownKey)
        }
    }
}

/// Boxes a `UsagePref` for `NSMenuItem.representedObject`, so the one
/// `pickPref` handler can recover the exact payload each generated menu item
/// carries.
package final class PrefBox: NSObject {
    package let pref: UsagePref

    package init(_ pref: UsagePref) {
        self.pref = pref
    }
}
