import Foundation
import SQLite3

/// One row of usage history: `used_pct` for each metric at a given moment,
/// tagged with the session it belongs to. Nothing here is nullable: a row is
/// recorded whole or not at all (see the recording site in
/// `StatusItemController.refresh`), so every column is safe to read as a
/// plain, non-optional value.
package struct Sample: Equatable {
    package let ts: Int  // unix seconds
    package let sessionStart: Int  // unix seconds at the start of this row's 5h session window - see PanelModel.sessionStart
    package let session, week, fable: Double  // used_pct

    package init(ts: Int, sessionStart: Int, session: Double, week: Double, fable: Double) {
        self.ts = ts
        self.sessionStart = sessionStart
        self.session = session
        self.week = week
        self.fable = fable
    }
}

/// Thrown by any `HistoryStore` operation; carries the sqlite result code
/// and `sqlite3_errmsg` text (already lowercase, e.g. "no such table").
package struct HistoryStoreError: Error, CustomStringConvertible {
    package let code: Int32
    package let message: String

    package var description: String { "sqlite error \(code): \(message)" }
}

/// Synchronous SQLite-backed store for usage history samples, one row per
/// trustworthy `/usage` fetch. Not thread-safe on purpose: the store assumes
/// a single confined caller (a serial queue owned by `HistoryCoordinator`)
/// rather than layering its own queue or mutex on top of that.
package final class HistoryStore {
    private var db: OpaquePointer?
    private var insertStatement: OpaquePointer?

    package init(url: URL) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        let rc = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard rc == SQLITE_OK else {
            let message = Self.errorMessage(handle)
            sqlite3_close_v2(handle)
            throw HistoryStoreError(code: rc, message: message)
        }
        db = handle

        try exec("PRAGMA journal_mode = WAL")
        try exec("PRAGMA synchronous = NORMAL")
        try exec("PRAGMA busy_timeout = 3000")
        // Exclusive locking mode is safe because the store is confined to a
        // single connection in a single process; in return, SQLite skips
        // the -shm file entirely (kept in-process heap memory instead),
        // which is what lets deinit's cleanup remove every WAL sidecar file.
        try exec("PRAGMA locking_mode = EXCLUSIVE")

        // Schema v1 tags every row with session_start and drops nullability
        // (see `Sample`). user_version starts at 0 for both a brand-new file
        // and every pre-v1 database (the old nullable schema never set it),
        // so one check covers "fresh install" and "needs migrating" alike;
        // the user approved dropping old data rather than migrating it in
        // place, so this just recreates the table.
        if try userVersion() < 1 {
            try exec("DROP TABLE IF EXISTS samples")
            try exec(
                """
                CREATE TABLE samples (
                  ts            INTEGER PRIMARY KEY,
                  session_start INTEGER NOT NULL,
                  session       REAL NOT NULL,
                  week          REAL NOT NULL,
                  fable         REAL NOT NULL
                ) STRICT
                """)
            try exec("PRAGMA user_version = 1")
        }
    }

    deinit {
        close()
    }

    /// Closes the store: finalizes the cached insert statement before
    /// closing the connection (closing with a live prepared statement
    /// leaves sqlite3_close_v2 unable to fully close it — it "zombies"
    /// until the statement is finalized elsewhere, which never happens once
    /// this object is gone — which alone would leave the WAL sidecar files
    /// behind forever), then switches back to a rollback journal, which
    /// checkpoints and deletes the -wal file; combined with exclusive
    /// locking mode (no -shm file to begin with), a clean close leaves no
    /// sidecar files. Idempotent (a repeat call, or a call before opening
    /// finished, sees the pointers already nil and does nothing) since both
    /// `deinit` and an explicit caller (`HistoryCoordinator.close()`, from
    /// the app's willTerminate handler) may end up calling it.
    package func close() {
        if let insertStatement {
            sqlite3_finalize(insertStatement)
            self.insertStatement = nil
        }
        if let db {
            sqlite3_exec(db, "PRAGMA journal_mode = DELETE", nil, nil, nil)
            sqlite3_close_v2(db)
            self.db = nil
        }
    }

    /// Inserts or replaces the row for `sample.ts`, so re-recording the same
    /// second (a duplicate refresh) overwrites rather than errors. Prepared
    /// once and reused via reset + clear_bindings, since this runs on every
    /// tick.
    package func insert(_ sample: Sample) throws {
        if insertStatement == nil {
            let sql =
                "INSERT OR REPLACE INTO samples (ts, session_start, session, week, fable) VALUES (?1, ?2, ?3, ?4, ?5)"
            guard sqlite3_prepare_v2(db, sql, -1, &insertStatement, nil) == SQLITE_OK else {
                throw lastError()
            }
        }
        let statement = insertStatement
        defer {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }

        sqlite3_bind_int64(statement, 1, Int64(sample.ts))
        sqlite3_bind_int64(statement, 2, Int64(sample.sessionStart))
        sqlite3_bind_double(statement, 3, sample.session)
        sqlite3_bind_double(statement, 4, sample.week)
        sqlite3_bind_double(statement, 5, sample.fable)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw lastError()
        }
    }

    /// Downsampled window query: `from` inclusive, `to` exclusive, grouped
    /// into `bucket`-second buckets (`bucket: 1` degenerates to raw rows,
    /// since `ts` is the primary key and every bucket then holds one row).
    /// A non-nil `sessionStart` keeps only rows whose `session_start` falls
    /// within `HistoryMath.sessionStartTolerance` of it — the session
    /// chart's identity scope, applied to raw rows before bucketing. The
    /// derived identity jitters by up to a minute across polls of the same
    /// session (see `PanelModel.sessionStart`), and the chart's time window
    /// jitters with it, so a window-only query can sweep in the tail of the
    /// previous session; nil (the week chart) spans sessions by design.
    /// avg() over a NOT NULL column, for a GROUP BY that only ever produces
    /// groups with at least one row, is never NULL — every column here
    /// decodes as a plain, non-optional value. A bucket can span rows from
    /// more than one session, so session_start (a single scalar, not an
    /// average) takes MIN(): which session it names does not matter for a
    /// chart, only that `Sample.sessionStart` always has a value.
    package func samples(from: Int, to: Int, bucket: Int, sessionStart: Int?) throws -> [Sample] {
        let sessionFilter = sessionStart == nil ? "" : " AND session_start BETWEEN ?4 AND ?5"
        let sql = """
            SELECT (ts / ?1) * ?1 AS bts, MIN(session_start), avg(session), avg(week), avg(fable)
            FROM samples WHERE ts >= ?2 AND ts < ?3\(sessionFilter) GROUP BY bts ORDER BY bts
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError()
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, Int64(bucket))
        sqlite3_bind_int64(statement, 2, Int64(from))
        sqlite3_bind_int64(statement, 3, Int64(to))
        if let sessionStart {
            sqlite3_bind_int64(statement, 4, Int64(sessionStart - HistoryMath.sessionStartTolerance))
            sqlite3_bind_int64(statement, 5, Int64(sessionStart + HistoryMath.sessionStartTolerance))
        }

        return try rows(from: statement)
    }

    /// Bucketed query for one panel chart's `window` (`window.end` is
    /// inclusive here, so this passes `samples`'s exclusive `to` as `end +
    /// 1`), scoped by `sessionStart` exactly as `samples` is. Falls back to
    /// a raw (`bucket: 1`) re-query when the bucketed result has fewer than
    /// 2 samples: a window younger than one bucket collapses every row into
    /// a single point - nothing to draw a line between - even though the
    /// underlying raw rows are enough to plot, and at that age the raw rows
    /// are few enough to return outright.
    package func chartSamples(window: TimeWindow, bucket: Int, sessionStart: Int?) throws -> [Sample] {
        let bucketed = try samples(from: window.start, to: window.end + 1, bucket: bucket, sessionStart: sessionStart)
        guard bucketed.count < 2, bucket != 1 else { return bucketed }
        return try samples(from: window.start, to: window.end + 1, bucket: 1, sessionStart: sessionStart)
    }

    package func clear() throws {
        try exec("DELETE FROM samples")
    }

    /// `~/Library/Application Support/com.claudeusagebar.app`, creating the
    /// directory first. Shared by `defaultURL()` (appends the database
    /// filename) and `UsageFetcher` (a benign, always-existing subprocess
    /// cwd). The bundle id is hardcoded rather than read from `Bundle.main`
    /// because the latter is nil under `swift run`.
    package static func appSupportDirectory() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        let dir = support.appendingPathComponent("com.claudeusagebar.app", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `~/Library/Application Support/com.claudeusagebar.app/history.sqlite`.
    /// `sqlite3_open_v2` creates the database file but never its parent
    /// directories, so a fresh install needs `appSupportDirectory()` to
    /// create those first, or it would fail to open with SQLITE_CANTOPEN.
    package static func defaultURL() throws -> URL {
        try appSupportDirectory().appendingPathComponent("history.sqlite")
    }

    // MARK: - Private helpers

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw lastError()
        }
    }

    /// `PRAGMA user_version` — a plain query (not `exec`), since it returns
    /// a row rather than just a result code. Used only by the migration
    /// check in `init`.
    private func userVersion() throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK else {
            throw lastError()
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw lastError() }
        return Int(sqlite3_column_int64(statement, 0))
    }

    /// Steps `statement` to completion, decoding each row:
    /// `samples(from:to:bucket:sessionStart:)` selects ts/bts, session_start,
    /// session, week, fable in that order.
    private func rows(from statement: OpaquePointer?) throws -> [Sample] {
        var result: [Sample] = []
        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw lastError() }
            result.append(
                Sample(
                    ts: Int(sqlite3_column_int64(statement, 0)),
                    sessionStart: Int(sqlite3_column_int64(statement, 1)),
                    session: sqlite3_column_double(statement, 2),
                    week: sqlite3_column_double(statement, 3),
                    fable: sqlite3_column_double(statement, 4)
                ))
        }
        return result
    }

    private func lastError() -> HistoryStoreError {
        HistoryStoreError(code: sqlite3_errcode(db), message: Self.errorMessage(db))
    }

    private static func errorMessage(_ handle: OpaquePointer?) -> String {
        guard let cString = sqlite3_errmsg(handle) else { return "unknown sqlite error" }
        return String(cString: cString)
    }
}
