import ClaudeUsageBarCore
import XCTest

/// Pins `PrefsStore`'s on-disk contract: key names, absence defaults, the
/// invalid-interval fallback, and that persisting one pref never touches
/// another's key. Runs against a scratch `UserDefaults` suite, wiped before
/// and after every test, so these assertions never touch the app's real
/// saved prefs.
final class PrefsStoreTests: XCTestCase {
    private let suiteName = "com.claudeusagebar.tests.PrefsStoreTests"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: - Key strings are pinned literally: an on-disk pref saved by
    // any earlier build must keep loading under the same name.

    func testKeyStringsArePinned() {
        defaults.set(Display.BarLayout.rows.rawValue, forKey: "barLayout")
        defaults.set(BarColor.green.rawValue, forKey: "barColor")
        defaults.set(Display.NumberMode.used.rawValue, forKey: "barNumbers")
        defaults.set(300.0, forKey: "refreshInterval")
        defaults.set(false, forKey: "showCountdown")

        let prefs = PrefsStore.load(from: defaults)
        XCTAssertTrue(prefs.layout == .rows, "the \"barLayout\" key name is pinned")
        XCTAssertTrue(prefs.barColor == .green, "the \"barColor\" key name is pinned")
        XCTAssertTrue(prefs.numbers == .used, "the \"barNumbers\" key name is pinned")
        XCTAssertTrue(prefs.refreshInterval == 300, "the \"refreshInterval\" key name is pinned")
        XCTAssertTrue(prefs.showCountdown == false, "the \"showCountdown\" key name is pinned")
    }

    // MARK: - Absence defaults: an empty domain loads UsagePrefs.standard
    // exactly, per-field.

    func testEmptyDomainLoadsStandard() {
        XCTAssertTrue(
            PrefsStore.load(from: defaults) == .standard, "an empty defaults domain loads UsagePrefs.standard exactly")
    }

    // MARK: - Unparseable raw values: a stored string no current enum case
    // matches (the shape a renamed case leaves on disk) falls back per-field
    // to UsagePrefs.standard.

    func testUnparseableRawValuesFallBackToStandard() {
        defaults.set("bogus", forKey: "barLayout")
        defaults.set("bogus", forKey: "barColor")
        defaults.set("bogus", forKey: "barNumbers")

        let prefs = PrefsStore.load(from: defaults)
        XCTAssertTrue(prefs.layout == UsagePrefs.standard.layout, "an unparseable barLayout loads the standard layout")
        XCTAssertTrue(
            prefs.barColor == UsagePrefs.standard.barColor, "an unparseable barColor loads the standard color")
        XCTAssertTrue(
            prefs.numbers == UsagePrefs.standard.numbers, "an unparseable barNumbers loads the standard mode")
    }

    // MARK: - Invalid-interval fallback: an absent, zero, or negative
    // stored value falls back to 60 (`v > 0 ? v : 60`).

    func testInvalidIntervalFallsBackTo60() {
        XCTAssertTrue(PrefsStore.load(from: defaults).refreshInterval == 60, "an absent value falls back to 60")

        defaults.set(0.0, forKey: "refreshInterval")
        XCTAssertTrue(PrefsStore.load(from: defaults).refreshInterval == 60, "zero falls back to 60")

        defaults.set(-30.0, forKey: "refreshInterval")
        XCTAssertTrue(PrefsStore.load(from: defaults).refreshInterval == 60, "a negative value falls back to 60")
    }

    // MARK: - Round trip: persisting each pref, then reloading, reproduces
    // exactly the value persisted.

    func testRoundTripEachPref() {
        let cases: [UsagePref] = [
            .layout(.rows), .barColor(.purple), .numbers(.used), .refreshInterval(900), .showCountdown(false),
        ]
        for pref in cases {
            PrefsStore.persist(pref, to: defaults)
        }

        let prefs = PrefsStore.load(from: defaults)
        XCTAssertTrue(prefs.layout == .rows, "layout round-trips")
        XCTAssertTrue(prefs.barColor == .purple, "barColor round-trips")
        XCTAssertTrue(prefs.numbers == .used, "numbers round-trips")
        XCTAssertTrue(prefs.refreshInterval == 900, "refreshInterval round-trips")
        XCTAssertTrue(prefs.showCountdown == false, "showCountdown round-trips")
    }

    // MARK: - persist writes only the one key its pref touches.

    func testPersistWritesOnlyItsOwnKey() {
        PrefsStore.persist(.barColor(.red), to: defaults)

        XCTAssertNotNil(defaults.object(forKey: "barColor"), "the touched key is written")
        XCTAssertNil(defaults.object(forKey: "barLayout"), "an untouched key is left absent")
        XCTAssertNil(defaults.object(forKey: "barNumbers"), "an untouched key is left absent")
        XCTAssertNil(defaults.object(forKey: "refreshInterval"), "an untouched key is left absent")
        XCTAssertNil(defaults.object(forKey: "showCountdown"), "an untouched key is left absent")
    }
}
