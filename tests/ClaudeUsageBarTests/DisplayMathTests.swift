import AppKit
import ClaudeUsageBarCore
import XCTest

final class DisplayMathTests: XCTestCase {
    func testUsedPercentAndFillFraction() {
        // Used percent is canonical; remaining is derived.
        XCTAssertTrue(Display.remainingPct(fromUsed: 11) == 89, "remainingPct(fromUsed: 11)")
        XCTAssertTrue(Display.displayPct(usedPct: 11, mode: .used) == 11, "displayPct used mode is identity")
        XCTAssertTrue(Display.displayPct(usedPct: 11, mode: .remaining) == 89, "displayPct remaining mode derives")

        // Fill fraction clamps to 0...1 regardless of how far out of range the
        // used-percent value strays.
        XCTAssertTrue(Display.fillFraction(usedPct: 120, mode: .used) == 1.0, "fillFraction clamps high in used mode")
        XCTAssertTrue(
            Display.fillFraction(usedPct: 120, mode: .remaining) == 0.0, "fillFraction clamps high in remaining mode")
        XCTAssertTrue(Display.fillFraction(usedPct: -5, mode: .used) == 0.0, "fillFraction clamps low in used mode")
        XCTAssertTrue(
            Display.fillFraction(usedPct: -5, mode: .remaining) == 1.0, "fillFraction clamps low in remaining mode")
        XCTAssertTrue(approxEqual(Display.fillFraction(usedPct: 55, mode: .used), 0.55), "fillFraction 55 used")
        XCTAssertTrue(
            approxEqual(Display.fillFraction(usedPct: 55, mode: .remaining), 0.45), "fillFraction 55 remaining")
    }

    func testColorThresholds() {
        // severity(remaining:) boundaries (<=, not <).
        XCTAssertTrue(Display.severity(remaining: 10) == .critical, "severity(remaining: 10) is critical")
        XCTAssertTrue(Display.severity(remaining: 10.1) == .warning, "severity(remaining: 10.1) is warning")
        XCTAssertTrue(Display.severity(remaining: 25) == .warning, "severity(remaining: 25) is warning")
        XCTAssertTrue(Display.severity(remaining: 25.1) == .normal, "severity(remaining: 25.1) is normal")
        XCTAssertTrue(Display.severity(remaining: 100) == .normal, "severity(remaining: 100) is normal")

        // Band-to-color mapping: text tint, then bar fill (which falls back
        // to the caller's base colour once headroom is comfortable).
        XCTAssertTrue(Display.color(band: .critical) == .systemRed, "critical text is red")
        XCTAssertTrue(Display.color(band: .warning) == .systemOrange, "warning text is orange")
        XCTAssertTrue(Display.color(band: .normal) == .labelColor, "normal text is label")
        let green = BarColor.green.nsColor
        XCTAssertTrue(Display.barFillColor(band: .critical, base: green) == .systemRed, "critical fill is red")
        XCTAssertTrue(Display.barFillColor(band: .warning, base: green) == .systemOrange, "warning fill is orange")
        XCTAssertTrue(Display.barFillColor(band: .normal, base: green) == green, "normal fill is the base colour")
    }

    func testBarColorThemes() {
        // BarColor: eight named themes, each a distinct system tint
        // (light/dark resolution is covered in AppearanceTests).
        XCTAssertTrue(BarColor.allCases.count == 8, "BarColor has 8 cases")
        let tints = BarColor.allCases.map(\.nsColor)
        XCTAssertTrue(Set(tints).count == tints.count, "every theme maps to a distinct tint")
        XCTAssertTrue(BarColor.blue.nsColor == .systemBlue, "blue is the system blue tint")
        XCTAssertTrue(BarColor.graphite.nsColor == .systemGray, "graphite is the system gray tint")
    }

    func testHexStringParsing() {
        // NSColor(hexString:) parsing.
        XCTAssertTrue(NSColor(hexString: "0A84FF") != nil, "hexString without # parses")
        XCTAssertTrue(NSColor(hexString: "#0A84FF") != nil, "hexString with # parses")
        XCTAssertTrue(NSColor(hexString: "0A84F") == nil, "hexString too short is nil")
        XCTAssertTrue(NSColor(hexString: "0A84FF7") == nil, "hexString too long is nil")
        XCTAssertTrue(NSColor(hexString: "GGGGGG") == nil, "hexString non-hex digits is nil")
        XCTAssertTrue(NSColor(hexString: "") == nil, "hexString empty is nil")

        // A leading "+"/"-" is a valid prefix for `UInt32(_:radix:)` but not a
        // hex digit; each of the 6 characters must reject it explicitly.
        XCTAssertTrue(NSColor(hexString: "+0A84F") == nil, "hexString with a leading + (still 6 chars) is nil")
        XCTAssertTrue(NSColor(hexString: "+0A84FF") == nil, "hexString with a leading + (7 chars) is nil")

        if let plain = NSColor(hexString: "0A84FF"), let hashed = NSColor(hexString: "#0A84FF") {
            XCTAssertTrue(
                approxEqual(Double(plain.redComponent), Double(hashed.redComponent)),
                "hexString with/without # match: red")
            XCTAssertTrue(
                approxEqual(Double(plain.greenComponent), Double(hashed.greenComponent)),
                "hexString with/without # match: green")
            XCTAssertTrue(
                approxEqual(Double(plain.blueComponent), Double(hashed.blueComponent)),
                "hexString with/without # match: blue")

            XCTAssertTrue(approxEqual(Double(plain.redComponent), 10.0 / 255), "blue red component")
            XCTAssertTrue(approxEqual(Double(plain.greenComponent), 132.0 / 255), "blue green component")
            XCTAssertTrue(approxEqual(Double(plain.blueComponent), 255.0 / 255), "blue blue component")
        } else {
            XCTFail("blue hex should parse")
        }
    }

    func testNumberFormatting() {
        // wholeNumber rounds and drops the percent sign, half away from zero
        // (not %.0f's round-half-to-even, which prints "0" for 0.5).
        XCTAssertTrue(Display.wholeNumber(89.6) == "90", "wholeNumber(89.6)")
        XCTAssertTrue(Display.wholeNumber(100.0) == "100", "wholeNumber(100.0)")
        XCTAssertTrue(Display.wholeNumber(0.4) == "0", "wholeNumber(0.4)")
        XCTAssertTrue(Display.wholeNumber(0.5) == "1", "wholeNumber(0.5) rounds half away from zero")
        XCTAssertTrue(Display.wholeNumber(2.5) == "3", "wholeNumber(2.5) rounds half away from zero")

        // pct(_:) keeps a decimal only when the value is not already whole.
        XCTAssertTrue(Display.pct(96.5) == "96.5%", "pct(96.5) keeps one decimal")
        XCTAssertTrue(Display.pct(96.0) == "96%", "pct(96.0) drops the decimal")
    }

    func testCountdownFormatting() {
        // countdown(seconds:): nil for nil/0/negative, otherwise the largest one
        // or two units that fit.
        XCTAssertTrue(Display.countdown(seconds: nil) == nil, "countdown(nil) is nil")
        XCTAssertTrue(Display.countdown(seconds: 0) == nil, "countdown(0) is nil")
        XCTAssertTrue(Display.countdown(seconds: -5) == nil, "countdown(negative) is nil")
        XCTAssertTrue(Display.countdown(seconds: 60 * 16) == "16m", "countdown(16m)")
        XCTAssertTrue(Display.countdown(seconds: 3600 * 2 + 60 * 39) == "2h39m", "countdown(2h39m)")
        XCTAssertTrue(Display.countdown(seconds: 3600 * 2) == "2h", "countdown(2h) with no leftover minutes")
        XCTAssertTrue(Display.countdown(seconds: 86400) == "1d", "countdown(1d)")
        XCTAssertTrue(Display.countdown(seconds: 86400 * 2 + 3600 * 18) == "2d18h", "countdown(2d18h)")
        XCTAssertTrue(Display.countdown(seconds: 30) == "1m", "countdown(30s) floors up to a 1m minimum")

        // clockCountdown(seconds:): "H:MM", nil only for a nil (unknown)
        // anchor; zero/negative pins at "0:00", the true remaining time at
        // or past the reset moment.
        XCTAssertTrue(Display.clockCountdown(seconds: nil) == nil, "clockCountdown(nil) is nil")
        XCTAssertTrue(Display.clockCountdown(seconds: 0) == "0:00", "clockCountdown(0) pins at 0:00")
        XCTAssertTrue(Display.clockCountdown(seconds: -5) == "0:00", "clockCountdown(negative) pins at 0:00")
        XCTAssertTrue(Display.clockCountdown(seconds: 60) == "0:01", "clockCountdown(60s)")
        XCTAssertTrue(Display.clockCountdown(seconds: 3599) == "0:59", "clockCountdown(3599s) stays under an hour")
        XCTAssertTrue(Display.clockCountdown(seconds: 3600 * 5) == "5:00", "clockCountdown(5h)")
        XCTAssertTrue(Display.clockCountdown(seconds: 3600 * 2 + 60 * 39) == "2:39", "clockCountdown(2h39m)")

        // daysCountdown(seconds:): "X.Yd", nil only for a nil (unknown)
        // anchor; zero/negative pins at "0.0d".
        XCTAssertTrue(Display.daysCountdown(seconds: nil) == nil, "daysCountdown(nil) is nil")
        XCTAssertTrue(Display.daysCountdown(seconds: 0) == "0.0d", "daysCountdown(0) pins at 0.0d")
        XCTAssertTrue(Display.daysCountdown(seconds: -5) == "0.0d", "daysCountdown(negative) pins at 0.0d")
        XCTAssertTrue(
            Display.daysCountdown(seconds: Int(86400 * 2.34)) == "2.3d", "daysCountdown(2.34d) rounds to one decimal")
        XCTAssertTrue(Display.daysCountdown(seconds: Int(86400 * 0.5)) == "0.5d", "daysCountdown(0.5d) under a day")
        XCTAssertTrue(Display.daysCountdown(seconds: Int(86400 * 0.05)) == "0.1d", "daysCountdown(0.05d) rounds up")
    }

    func testCountdownLines() {
        let live = { (seconds: Int?, key: String) in
            MetricState(
                metric: Metric(key: key, usedPct: 50, remainingPct: 50, reset: nil),
                resetAnchor: seconds.map { 1_000 + $0 }, remainingSeconds: seconds)
        }
        let session = live(3600 * 2 + 60 * 39, MetricKey.session)
        let week = live(Int(86400 * 2.34), MetricKey.week)
        let anchorlessSession = live(nil, MetricKey.session)
        let anchorlessWeek = live(nil, MetricKey.week)

        // Both anchors known: the live two-line readout.
        XCTAssertTrue(
            Display.countdownLines(session: session, week: week) == ["2:39", "2.3d"],
            "both anchors known stacks the two live countdowns")

        // A present metric with an unknown anchor keeps its line as dashes, so
        // the surviving countdown still renders at its two-line size.
        XCTAssertTrue(
            Display.countdownLines(session: anchorlessSession, week: week) == ["-:--", "2.3d"],
            "an anchorless session dashes out instead of dropping its line")
        XCTAssertTrue(
            Display.countdownLines(session: session, week: anchorlessWeek) == ["2:39", "-.-d"],
            "an anchorless week dashes out instead of dropping its line")
        XCTAssertTrue(
            Display.countdownLines(session: anchorlessSession, week: anchorlessWeek) == ["-:--", "-.-d"],
            "two anchorless metrics dash out both lines")

        // A metric absent from the snapshot has no line at all; neither
        // present means no countdown cell.
        XCTAssertTrue(
            Display.countdownLines(session: nil, week: week) == ["2.3d"],
            "an absent session drops its line entirely")
        XCTAssertTrue(
            Display.countdownLines(session: session, week: nil) == ["2:39"],
            "an absent week drops its line entirely")
        XCTAssertTrue(
            Display.countdownLines(session: nil, week: nil) == nil,
            "neither metric present draws no countdown cell")

        // The placeholders mirror the shape of the format they stand in for.
        XCTAssertTrue(
            Display.unknownClockCountdown.count == Display.clockCountdown(seconds: 0)!.count,
            "the clock placeholder is as wide in characters as \"0:00\"")
        XCTAssertTrue(
            Display.unknownDaysCountdown.count == Display.daysCountdown(seconds: 0)!.count,
            "the days placeholder is as wide in characters as \"0.0d\"")
    }

    func testLocaleAwareTimeFormatting() {
        // A fixed wall-clock instant in the SYSTEM time zone, since
        // `DateFormatter` renders in `.current` regardless of the `locale:`
        // under test - pinning a UTC epoch instead would make the expected
        // hour drift with the machine's own time zone.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let date = calendar.date(
            from: DateComponents(year: 2026, month: 9, day: 4, hour: 14, minute: 32, second: 7))!
        let twentyFourHour = Locale(identifier: "en_GB")
        let twelveHour = Locale(identifier: "en_US")

        // .time: "14:32" in a 24-hour locale, "2:32" plus an am/pm marker in
        // a 12-hour one. Semantic checks, not exact literals - locale data
        // shifts between OS versions.
        let time24 = Display.string(.time, date, locale: twentyFourHour)
        XCTAssertTrue(time24.contains("14:32"), "24-hour locale .time contains \"14:32\": \(time24)")
        XCTAssertTrue(
            !time24.lowercased().contains("pm") && !time24.lowercased().contains("am"),
            "24-hour locale .time carries no am/pm marker: \(time24)")

        let time12 = Display.string(.time, date, locale: twelveHour)
        XCTAssertTrue(time12.contains("2:32"), "12-hour locale .time contains \"2:32\": \(time12)")
        XCTAssertTrue(
            time12.lowercased().contains("pm") || time12.lowercased().contains("am"),
            "12-hour locale .time carries an am/pm marker: \(time12)")

        // .timeWithSeconds: same hour convention, with seconds.
        let seconds24 = Display.string(.timeWithSeconds, date, locale: twentyFourHour)
        XCTAssertTrue(seconds24.contains("14:32:07"), ".timeWithSeconds 24-hour: \(seconds24)")
        let seconds12 = Display.string(.timeWithSeconds, date, locale: twelveHour)
        XCTAssertTrue(seconds12.contains("2:32:07"), ".timeWithSeconds 12-hour: \(seconds12)")
        XCTAssertTrue(
            seconds12.lowercased().contains("pm") || seconds12.lowercased().contains("am"),
            ".timeWithSeconds 12-hour carries an am/pm marker: \(seconds12)")

        // .dayAndTime: weekday, day-of-month, and time together. The
        // day-of-month is asserted specifically (not merely "contains 4"),
        // since the time field alone ("14:32"/"2:32") also contains a "4"
        // and would otherwise satisfy a check with the day-of-month removed.
        let dayAndTime24 = Display.string(.dayAndTime, date, locale: twentyFourHour)
        XCTAssertTrue(dayAndTime24.contains("14:32"), ".dayAndTime 24-hour contains the time: \(dayAndTime24)")
        XCTAssertTrue(
            dayAndTime24.range(of: #"\b4\b"#, options: .regularExpression) != nil,
            ".dayAndTime 24-hour contains the day-of-month as its own token: \(dayAndTime24)")
        let dayAndTime12 = Display.string(.dayAndTime, date, locale: twelveHour)
        XCTAssertTrue(dayAndTime12.contains("2:32"), ".dayAndTime 12-hour contains the time: \(dayAndTime12)")
        XCTAssertTrue(
            dayAndTime12.range(of: #"\b4\b"#, options: .regularExpression) != nil,
            ".dayAndTime 12-hour contains the day-of-month as its own token: \(dayAndTime12)")
        XCTAssertTrue(
            dayAndTime12.lowercased().contains("pm") || dayAndTime12.lowercased().contains("am"),
            ".dayAndTime 12-hour carries an am/pm marker: \(dayAndTime12)")

        // .day: no time field at all, in either locale.
        let day = Display.string(.day, date, locale: twentyFourHour)
        XCTAssertTrue(day.contains("4"), ".day contains the day-of-month: \(day)")
        XCTAssertTrue(!day.contains("32"), ".day has no time field: \(day)")

        // hoverTimeLabel/chartTickLabel/clockTime must agree with the
        // equivalent direct `Display.string(...)` call - the point of the
        // consolidation is that there is exactly one formatting path. Pinned
        // to a 12-hour locale (rather than the default) so a regression to a
        // hard-coded "HH:mm"-style pattern would actually fail these on a
        // 24-hour machine instead of passing vacuously.
        XCTAssertTrue(
            Display.chartTickLabel(date: date, spansDays: false, locale: twelveHour)
                == Display.string(.time, date, locale: twelveHour),
            "chartTickLabel(spansDays: false) matches .time")
        XCTAssertTrue(
            Display.chartTickLabel(date: date, spansDays: true, locale: twelveHour)
                == Display.string(.day, date, locale: twelveHour),
            "chartTickLabel(spansDays: true) matches .day")
        XCTAssertTrue(
            Display.hoverTimeLabel(date: date, spansDays: false, locale: twelveHour)
                == Display.string(.time, date, locale: twelveHour),
            "hoverTimeLabel(spansDays: false) matches .time")
        XCTAssertTrue(
            Display.hoverTimeLabel(date: date, spansDays: true, locale: twelveHour)
                == Display.string(.dayAndTime, date, locale: twelveHour),
            "hoverTimeLabel(spansDays: true) matches .dayAndTime")
        XCTAssertTrue(
            Display.clockTime(date, locale: twelveHour) == Display.string(.timeWithSeconds, date, locale: twelveHour),
            "clockTime matches .timeWithSeconds")
    }

    func testIso8601StringRoundTrips() {
        // iso8601String(_:) is the inverse of iso8601Date(_:): formatting
        // then reparsing must land on the same instant.
        let date = Date(timeIntervalSince1970: 1_788_532_327)
        let formatted = Display.iso8601String(date)
        guard let reparsed = Display.iso8601Date(formatted) else {
            XCTFail("iso8601String output failed to reparse: \(formatted)")
            return
        }
        XCTAssertTrue(
            abs(reparsed.timeIntervalSince1970 - date.timeIntervalSince1970) < 0.001,
            "iso8601String round-trips through iso8601Date: \(formatted)")
    }

    func testFailureAndDateParsing() {
        // UsageSnapshot.failure(_:): an explicit unknown state, never trustworthy.
        let failure = UsageSnapshot.failure("boom")
        XCTAssertTrue(!failure.ok, "failure(_:) is not ok")
        XCTAssertTrue(failure.error == "boom", "failure(_:) preserves the message")
        XCTAssertTrue(!failure.isTrustworthy, "failure(_:) is not trustworthy")

        // Display.iso8601Date: the parser always emits microseconds, but a
        // no-fraction timestamp (or garbage) must be handled too.
        XCTAssertTrue(
            Display.iso8601Date("2026-09-05T11:05:49.689837-04:00") != nil,
            "iso8601Date parses a timestamp with fractional seconds")
        XCTAssertTrue(
            Display.iso8601Date("2026-09-05T11:05:49-04:00") != nil,
            "iso8601Date parses a timestamp without fractional seconds")
        XCTAssertTrue(Display.iso8601Date("not a date") == nil, "iso8601Date rejects garbage")
    }
}
