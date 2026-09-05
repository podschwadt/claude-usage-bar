import Foundation

/// Swift mirror of the JSON contract emitted by `parser/claude_usage.py`.
/// Keys are mapped explicitly via `CodingKeys` rather than relying on
/// `.convertFromSnakeCase`: on macOS 13/14, that strategy also rewrites the
/// keys of `[String: Metric]` dictionaries, which would silently turn
/// `metrics["week_all_models"]` lookups into `metrics["weekAllModels"]` and
/// break every `metric(MetricKey.week)` call.
///
/// Fields mirror the parser's output; fields the app never reads are not
/// decoded (the decoder ignores unknown keys).
package enum MetricKey {
    package static let session = "session"
    package static let week = "week_all_models"
    package static let fable = "week_fable"
}

package struct ResetInfo: Codable, Equatable {
    package let raw: String?
    package let secondsUntil: Int?

    enum CodingKeys: String, CodingKey {
        case raw
        case secondsUntil = "seconds_until"
    }

    /// Explicit because the synthesized memberwise initializer is
    /// internal-only even for a `package`-access struct; tests build
    /// fixtures from outside this module. The same applies to every
    /// explicit `package init` below and to `BarGauge`.
    package init(raw: String?, secondsUntil: Int?) {
        self.raw = raw
        self.secondsUntil = secondsUntil
    }
}

package struct Metric: Codable, Equatable {
    package let key: String
    package let usedPct: Double
    package let remainingPct: Double
    package let reset: ResetInfo?

    enum CodingKeys: String, CodingKey {
        case key, reset
        case usedPct = "used_pct"
        case remainingPct = "remaining_pct"
    }

    /// Explicit for cross-module test fixtures (see `ResetInfo.init`).
    package init(key: String, usedPct: Double, remainingPct: Double, reset: ResetInfo?) {
        self.key = key
        self.usedPct = usedPct
        self.remainingPct = remainingPct
        self.reset = reset
    }
}

package struct Activity: Codable, Equatable {
    package let windowDays: Int?
    package let requests: Int?
    package let sessions: Int?
    /// /usage states these counts cover local sessions on this machine only.
    package let localOnly: Bool?

    enum CodingKeys: String, CodingKey {
        case requests, sessions
        case windowDays = "window_days"
        case localOnly = "local_only"
    }
}

package struct UsageSnapshot: Codable, Equatable {
    package let ok: Bool
    package let error: String?
    package let schemaOk: Bool?
    package let missingKeys: [String]?
    package let metrics: [String: Metric]?
    package let activity: Activity?
    package let queriedAt: String?
    package let raw: String?

    enum CodingKeys: String, CodingKey {
        case ok, error, metrics, activity, raw
        case schemaOk = "schema_ok"
        case missingKeys = "missing_keys"
        case queriedAt = "queried_at"
    }

    /// Explicit for cross-module test fixtures (see `ResetInfo.init`).
    package init(
        ok: Bool, error: String?, schemaOk: Bool?, missingKeys: [String]?,
        metrics: [String: Metric]?, activity: Activity?, queriedAt: String?, raw: String?
    ) {
        self.ok = ok
        self.error = error
        self.schemaOk = schemaOk
        self.missingKeys = missingKeys
        self.metrics = metrics
        self.activity = activity
        self.queriedAt = queriedAt
        self.raw = raw
    }

    /// True only when the query succeeded *and* the expected lines were found.
    /// Anything less must render as an explicit unknown state rather than a
    /// confident number, because the source is scraped text.
    package var isTrustworthy: Bool { ok && (schemaOk ?? false) }

    package func metric(_ key: String) -> Metric? { metrics?[key] }

    package static func failure(_ message: String) -> UsageSnapshot {
        UsageSnapshot(
            ok: false, error: message, schemaOk: false,
            missingKeys: nil, metrics: nil, activity: nil,
            queriedAt: nil, raw: nil)
    }
}
