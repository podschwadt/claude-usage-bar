import ClaudeUsageBarCore
import XCTest

/// Fixture `queried_at`, matching the shape emitted by the real parser
/// (fractional seconds, explicit offset - see `SnapshotDecodingTests`).

final class HistoryMathTests: XCTestCase {
    // sessionWindow: anchored to the reset boundary when known, spanning
    // exactly sessionLength seconds ending at the reset.
    func testSessionWindowAnchored() {
        let resetAt = 100_000
        let w = HistoryMath.sessionWindow(resetAtUnix: resetAt, now: 90_000)
        XCTAssertTrue(w.start == resetAt - HistoryMath.sessionLength, "sessionWindow anchored start")
        XCTAssertTrue(w.end == resetAt, "sessionWindow anchored end")
    }

    // sessionWindow: no reset known -> trailing window ending at `now`, same
    // duration as the anchored case (the fallback swaps the anchor, not the
    // length).
    func testSessionWindowTrailing() {
        let now = 90_000
        let w = HistoryMath.sessionWindow(resetAtUnix: nil, now: now)
        XCTAssertTrue(w.start == now - HistoryMath.sessionLength, "sessionWindow trailing start")
        XCTAssertTrue(w.end == now, "sessionWindow trailing end")
    }

    // weekWindow: same two shapes, weekLength duration.
    func testWeekWindowAnchored() {
        let resetAt = 1_000_000
        let w = HistoryMath.weekWindow(resetAtUnix: resetAt, now: 900_000)
        XCTAssertTrue(w.start == resetAt - HistoryMath.weekLength, "weekWindow anchored start")
        XCTAssertTrue(w.end == resetAt, "weekWindow anchored end")
    }

    func testWeekWindowTrailing() {
        let now = 900_000
        let w = HistoryMath.weekWindow(resetAtUnix: nil, now: now)
        XCTAssertTrue(w.start == now - HistoryMath.weekLength, "weekWindow trailing start")
        XCTAssertTrue(w.end == now, "weekWindow trailing end")
    }

    // sessionStart: a known queried_at + secondsUntil derives resetAnchor -
    // sessionLength; either input missing propagates nil.
    func testSessionStartDerivation() {
        let secondsUntil = 9540
        let anchor = PanelModel.resetAnchor(queriedAt: queriedAtFixture, secondsUntil: secondsUntil)!
        let derived = PanelModel.sessionStart(queriedAt: queriedAtFixture, secondsUntil: secondsUntil)
        XCTAssertTrue(derived == anchor - HistoryMath.sessionLength, "sessionStart == resetAnchor - sessionLength")
        XCTAssertTrue(derived == anchor - 18000, "sessionStart subtracts exactly 5h (18000s) from the anchor")

        XCTAssertTrue(
            PanelModel.sessionStart(queriedAt: nil, secondsUntil: secondsUntil) == nil,
            "sessionStart is nil when queried_at is nil")
        XCTAssertTrue(
            PanelModel.sessionStart(queriedAt: queriedAtFixture, secondsUntil: nil) == nil,
            "sessionStart is nil when secondsUntil is nil")
    }
}
