import ClaudeUsageBarCore
import Foundation
import XCTest

/// Fixture shaped exactly like real `parser/claude_usage.py` output
/// (schema_version 1), covering all three metric keys the UI relies on.
private let validFixture = """
    {
      "ok": true,
      "error": null,
      "schema_version": 1,
      "schema_ok": true,
      "missing_keys": [],
      "plan": "Max",
      "metrics": {
        "session": {
          "key": "session",
          "label": "session",
          "used_pct": 11,
          "remaining_pct": 89,
          "reset": {
            "raw": "Sep 4 at 1:40pm (America/Denver)",
            "at": "2026-09-04T13:40:00-06:00",
            "seconds_until": 1020,
            "timezone": "America/Denver"
          }
        },
        "week_all_models": {
          "key": "week_all_models",
          "label": "week (all models)",
          "used_pct": 55,
          "remaining_pct": 45,
          "reset": {
            "raw": "Sep 7 at 8am (America/Denver)",
            "at": "2026-09-07T08:00:00-06:00",
            "seconds_until": 250800,
            "timezone": "America/Denver"
          }
        },
        "week_fable": {
          "key": "week_fable",
          "label": "week (Fable)",
          "used_pct": 10,
          "remaining_pct": 90,
          "reset": {
            "raw": "Sep 7 at 8am (America/Denver)",
            "at": "2026-09-07T08:00:00-06:00",
            "seconds_until": 250800,
            "timezone": "America/Denver"
          }
        }
      },
      "activity": {
        "window_days": 7,
        "requests": 55,
        "sessions": 7,
        "local_only": true
      },
      "queried_at": "2026-09-04T13:23:00.123456-06:00",
      "raw": "Current session: 11% used ..."
    }
    """

/// Same schema but `seconds_until` is absent for the session metric, to
/// exercise `menuRow`'s fallback to the raw reset phrase. The parser's
/// `reset.raw` never carries a "resets " prefix (that word is consumed by
/// the regex before the capture group begins), so `menuRow` prepending
/// "resets " itself must not double up.
private let rawOnlyResetFixture = """
    {
      "ok": true,
      "error": null,
      "schema_version": 1,
      "schema_ok": true,
      "missing_keys": [],
      "plan": "Max",
      "metrics": {
        "session": {
          "key": "session",
          "label": "session",
          "used_pct": 11,
          "remaining_pct": 89,
          "reset": {
            "raw": "Sep 4 at 1:40pm (America/Denver)",
            "at": null,
            "seconds_until": null,
            "timezone": "America/Denver"
          }
        },
        "week_all_models": {
          "key": "week_all_models",
          "label": "week (all models)",
          "used_pct": 55,
          "remaining_pct": 45,
          "reset": null
        }
      },
      "activity": {},
      "queried_at": "2026-09-04T13:23:00.123456-06:00",
      "raw": "Current session: 11% used ..."
    }
    """

/// Same shape but with `schema_ok: false`, as the parser emits when a
/// required metric line went missing from `/usage` output.
private let untrustworthyFixture = """
    {
      "ok": true,
      "error": null,
      "schema_version": 1,
      "schema_ok": false,
      "missing_keys": ["session"],
      "plan": "Max",
      "metrics": {},
      "activity": {},
      "queried_at": "2026-09-04T13:23:00-06:00",
      "raw": "unexpected /usage text"
    }
    """

private func decode(_ json: String) -> UsageSnapshot {
    UsageFetcher.decodeSnapshot(Data(json.utf8))
}

final class SnapshotDecodingTests: XCTestCase {
    // MARK: - Metric and activity decoding

    // Regression for the dict-key gotcha: `.convertFromSnakeCase` rewrites
    // dictionary keys too, so lookups by MetricKey silently returned nil.

    func testDecodesMetricsAndActivity() {
        let snap = decode(validFixture)
        XCTAssertTrue(snap.metric(MetricKey.week) != nil, "week metric present")
        XCTAssertTrue(snap.metric(MetricKey.fable) != nil, "fable metric present")

        let session = snap.metric(MetricKey.session)
        XCTAssertTrue(session?.usedPct == 11, "session used_pct")
        XCTAssertTrue(session?.remainingPct == 89, "session remaining_pct")
        XCTAssertTrue(session?.reset?.secondsUntil == 1020, "session seconds_until")

        let week = snap.metric(MetricKey.week)
        XCTAssertTrue(week?.usedPct == 55, "week used_pct")
        XCTAssertTrue(week?.remainingPct == 45, "week remaining_pct")
        XCTAssertTrue(week?.reset?.secondsUntil == 250800, "week seconds_until")

        let fable = snap.metric(MetricKey.fable)
        XCTAssertTrue(fable?.usedPct == 10, "fable used_pct")
        XCTAssertTrue(fable?.remainingPct == 90, "fable remaining_pct")
        XCTAssertTrue(fable?.reset?.secondsUntil == 250800, "fable seconds_until")

        XCTAssertTrue(snap.activity?.windowDays == 7, "activity window_days")
        XCTAssertTrue(snap.activity?.requests == 55, "activity requests")
        XCTAssertTrue(snap.activity?.sessions == 7, "activity sessions")
        XCTAssertTrue(snap.activity?.localOnly == true, "activity local_only")
    }

    // MARK: - Trustworthiness.

    func testTrustworthiness() {
        XCTAssertTrue(decode(validFixture).isTrustworthy, "trustworthy when ok and schema_ok")
        XCTAssertTrue(!decode(untrustworthyFixture).isTrustworthy, "not trustworthy when schema_ok is false")
    }

    // MARK: - Malformed input.

    func testMalformedInputDecoding() {
        let malformed = UsageFetcher.decodeSnapshot(Data("not json".utf8))
        XCTAssertTrue(!malformed.ok, "malformed input is not ok")
        XCTAssertTrue(
            malformed.error?.hasPrefix("could not decode parser output") ?? false,
            "malformed input reports a lowercase decode error")
    }

    // MARK: - Menu row with countdown

    // seconds_until present takes the countdown branch, never a doubled
    // "resets": reset.raw carries no "resets " prefix from the real parser.

    func testMenuRowWithCountdown() {
        let snap = decode(validFixture)
        if let sessionMetric = snap.metric(MetricKey.session) {
            let row = Display.menuRow(for: sessionMetric, remainingSeconds: 1020)  // 17m, caller-computed
            XCTAssertTrue(row.contains("resets in 17m"), "menuRow uses the countdown when remaining seconds are known")
            XCTAssertTrue(!row.contains("resets resets"), "menuRow never doubles \"resets\"")
        } else {
            XCTFail("session metric should be present for the menuRow check")
        }
    }

    // MARK: - Menu row fallback to raw reset

    // Remaining seconds unknown falls back to "resets " + reset.raw, which
    // must likewise never double the word.

    func testMenuRowFallbackToRawReset() {
        let rawOnlySnap = decode(rawOnlyResetFixture)
        if let rawOnlyMetric = rawOnlySnap.metric(MetricKey.session) {
            let row = Display.menuRow(for: rawOnlyMetric, remainingSeconds: nil)
            XCTAssertTrue(
                row.contains("resets Sep 4 at 1:40pm (America/Denver)"),
                "menuRow falls back to the raw reset phrase without a countdown")
            XCTAssertTrue(!row.contains("resets resets"), "menuRow never doubles \"resets\" in the raw fallback")
        } else {
            XCTFail("session metric should be present in the raw-only fixture")
        }
    }
}
