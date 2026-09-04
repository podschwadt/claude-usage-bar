import Foundation

/// Swift mirror of the JSON contract emitted by `parser/claude_usage.py`.
/// Decoded with `.convertFromSnakeCase`, so `used_pct` maps to `usedPct`.
///
/// Keep this in sync with SCHEMA_VERSION in the parser.
enum MetricKey {
    static let session = "session"
    static let week = "week_all_models"
    static let fable = "week_fable"
}

struct ResetInfo: Codable {
    let raw: String?
    let at: String?
    let secondsUntil: Int?
    let timezone: String?
}

struct Metric: Codable {
    let key: String
    let label: String
    let usedPct: Double
    let remainingPct: Double
    let reset: ResetInfo?
}

struct Activity: Codable {
    let windowDays: Int?
    let requests: Int?
    let sessions: Int?
    /// /usage states these counts cover local sessions on this machine only.
    let localOnly: Bool?
}

struct UsageSnapshot: Codable {
    let ok: Bool
    let error: String?
    let schemaVersion: Int?
    let schemaOk: Bool?
    let missingKeys: [String]?
    let plan: String?
    let metrics: [String: Metric]?
    let activity: Activity?
    let queriedAt: String?
    let raw: String?

    /// True only when the query succeeded *and* the expected lines were found.
    /// Anything less must render as an explicit unknown state rather than a
    /// confident number, because the source is scraped text.
    var isTrustworthy: Bool { ok && (schemaOk ?? false) }

    func metric(_ key: String) -> Metric? { metrics?[key] }

    /// The limit that will actually bite first: whichever of session / weekly
    /// has less headroom.
    var binding: Metric? {
        [metric(MetricKey.session), metric(MetricKey.week)]
            .compactMap { $0 }
            .min { $0.remainingPct < $1.remainingPct }
    }

    static func failure(_ message: String) -> UsageSnapshot {
        UsageSnapshot(ok: false, error: message, schemaVersion: nil, schemaOk: false,
                      missingKeys: nil, plan: nil, metrics: nil, activity: nil,
                      queriedAt: nil, raw: nil)
    }
}
