import ClaudeUsageBarCore
import Foundation
import SQLite3
import XCTest

/// Every case opens its store under a fresh, non-existent nested directory
/// (mirroring what `HistoryStore.defaultURL()` does before opening, without
/// calling that method directly — it would touch the real Application
/// Support directory). `sqlite3_open_v2` creates the database file itself
/// but never its parent directories, so creating the nested dir first is
/// what proves that half of `defaultURL`'s contract.
private func makeStoreURL(root: URL) -> URL {
    let dir = root.appendingPathComponent("nested/deeper", isDirectory: true)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("history.sqlite")
}

/// Runs a raw sqlite3 statement against a connection the test opened
/// directly, bypassing `HistoryStore` entirely — used only to hand-build an
/// old-schema database file for the migration test below.
private func execRaw(_ db: OpaquePointer?, _ sql: String) {
    precondition(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK, "raw sqlite3_exec failed: \(sql)")
}

/// Every row, oldest first: `bucket: 1` degenerates to raw ascending rows
/// (see `HistoryStore.samples`'s doc comment).
private func allRows(_ store: HistoryStore) -> [Sample] {
    try! store.samples(from: 0, to: Int.max, bucket: 1, sessionStart: nil)
}

final class HistoryStoreTests: XCTestCase {
    var suiteRoot: URL!

    override func setUp() {
        super.setUp()
        suiteRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: suiteRoot)
        suiteRoot = nil
        super.tearDown()
    }

    // Opening under a fresh nested path (directory created up front, exactly
    // as `defaultURL()` creates its own directory before returning) must
    // succeed and leave a database file on disk.
    func testOpenCreatesDatabaseFile() {
        let url = makeStoreURL(root: suiteRoot.appendingPathComponent("open"))
        let store = try! HistoryStore(url: url)
        _ = store
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "open creates the database file")
    }

    // Insert -> query round trip: values (including session_start) and
    // ascending order.
    func testInsertQueryRoundTrip() {
        let url = makeStoreURL(root: suiteRoot.appendingPathComponent("roundtrip"))
        let store = try! HistoryStore(url: url)
        try! store.insert(Sample(ts: 200, sessionStart: 150, session: 20, week: 40, fable: 60))
        try! store.insert(Sample(ts: 100, sessionStart: 50, session: 10, week: 30, fable: 50))

        let all = allRows(store)
        XCTAssertTrue(all.count == 2, "allRows returns every inserted row")
        XCTAssertTrue(all.map(\.ts) == [100, 200], "allRows orders by ts ascending")
        XCTAssertTrue(
            all[0] == Sample(ts: 100, sessionStart: 50, session: 10, week: 30, fable: 50),
            "allRows round-trips the first row's values")
        XCTAssertTrue(
            all[1] == Sample(ts: 200, sessionStart: 150, session: 20, week: 40, fable: 60),
            "allRows round-trips the second row's values")
    }

    // Range filter: from inclusive, to exclusive.
    func testRangeFilter() {
        let url = makeStoreURL(root: suiteRoot.appendingPathComponent("range"))
        let store = try! HistoryStore(url: url)
        for ts in [100, 200, 300] {
            try! store.insert(
                Sample(
                    ts: ts, sessionStart: ts - 50, session: Double(ts), week: Double(ts), fable: Double(ts)))
        }

        let windowed = try! store.samples(from: 100, to: 300, bucket: 1, sessionStart: nil)
        XCTAssertTrue(windowed.map(\.ts) == [100, 200], "samples(from:to:) includes from, excludes to")
    }

    // Same-ts INSERT OR REPLACE: a duplicate refresh overwrites in place
    // rather than erroring or duplicating the row.
    func testSameTimestampReplace() {
        let url = makeStoreURL(root: suiteRoot.appendingPathComponent("replace"))
        let store = try! HistoryStore(url: url)
        try! store.insert(Sample(ts: 100, sessionStart: 10, session: 10, week: 10, fable: 10))
        try! store.insert(Sample(ts: 100, sessionStart: 99, session: 99, week: 99, fable: 99))

        let all = allRows(store)
        XCTAssertTrue(all.count == 1, "same-ts insert replaces rather than duplicates")
        XCTAssertTrue(
            all[0] == Sample(ts: 100, sessionStart: 99, session: 99, week: 99, fable: 99),
            "same-ts insert keeps the newer values")
    }

    // Bucket averaging: two rows landing in the same bucket average
    // together for the REAL columns; session_start (a scalar, not an
    // average) takes the MIN of the two rows' values.
    func testBucketAveraging() {
        let url = makeStoreURL(root: suiteRoot.appendingPathComponent("bucket"))
        let store = try! HistoryStore(url: url)
        try! store.insert(Sample(ts: 1000, sessionStart: 900, session: 10, week: 5, fable: 20))
        try! store.insert(Sample(ts: 1050, sessionStart: 800, session: 30, week: 15, fable: 40))

        let bucketed = try! store.samples(from: 1000, to: 1100, bucket: 100, sessionStart: nil)
        XCTAssertTrue(bucketed.count == 1, "two rows in one 100s bucket collapse to one point")
        XCTAssertTrue(bucketed[0].ts == 1000, "bucketed ts is the bucket's start")
        XCTAssertTrue(bucketed[0].sessionStart == 800, "bucketed session_start is the MIN of the two rows")
        XCTAssertTrue(bucketed[0].session == 20, "bucketed session is the average of the two rows")
        XCTAssertTrue(bucketed[0].week == 10, "bucketed week is the average of the two rows")
        XCTAssertTrue(bucketed[0].fable == 30, "bucketed fable is the average of the two rows")
    }

    // bucket: 1 degenerates to raw rows, since ts is the primary key.
    func testBucketOneDegeneratesToRawRows() {
        let url = makeStoreURL(root: suiteRoot.appendingPathComponent("bucket-one"))
        let store = try! HistoryStore(url: url)
        try! store.insert(Sample(ts: 10, sessionStart: 5, session: 1, week: 2, fable: 3))
        try! store.insert(Sample(ts: 20, sessionStart: 5, session: 4, week: 5, fable: 6))

        let raw = try! store.samples(from: 0, to: 100, bucket: 1, sessionStart: nil)
        XCTAssertTrue(
            raw == [
                Sample(ts: 10, sessionStart: 5, session: 1, week: 2, fable: 3),
                Sample(ts: 20, sessionStart: 5, session: 4, week: 5, fable: 6),
            ],
            "bucket: 1 returns raw rows unchanged")
    }

    // chartSamples: a bucketed query yielding >= 2 points is returned as-is,
    // no raw fallback.
    func testChartSamplesReturnsBucketedResultWhenEnoughPoints() {
        let url = makeStoreURL(root: suiteRoot.appendingPathComponent("chart-bucketed"))
        let store = try! HistoryStore(url: url)
        try! store.insert(Sample(ts: 1000, sessionStart: 900, session: 10, week: 5, fable: 20))
        try! store.insert(Sample(ts: 1500, sessionStart: 900, session: 20, week: 10, fable: 30))
        try! store.insert(Sample(ts: 3000, sessionStart: 900, session: 30, week: 15, fable: 40))

        let result = try! store.chartSamples(window: TimeWindow(start: 0, end: 3000), bucket: 1000, sessionStart: nil)
        XCTAssertTrue(
            result.map(\.ts) == [1000, 3000],
            "a bucketed query with >= 2 points is returned as-is, not re-queried raw")
        XCTAssertTrue(result[0].session == 15, "the 1000 bucket averages its two rows")
    }

    // chartSamples: a young window whose bucketed query collapses every row
    // into one point (fewer than 2 samples) re-queries at bucket: 1 and
    // returns the raw rows instead.
    func testChartSamplesFallsBackToRawWhenBucketedCollapses() {
        let url = makeStoreURL(root: suiteRoot.appendingPathComponent("chart-fallback"))
        let store = try! HistoryStore(url: url)
        try! store.insert(Sample(ts: 1000, sessionStart: 900, session: 10, week: 5, fable: 20))
        try! store.insert(Sample(ts: 1010, sessionStart: 900, session: 30, week: 15, fable: 40))

        // Both rows land in the same 1800s (HistoryMath.weekBucket) bucket,
        // collapsing to a single point; the raw (bucket: 1) retry recovers both.
        let result = try! store.chartSamples(
            window: TimeWindow(start: 0, end: 2000), bucket: HistoryMath.weekBucket, sessionStart: nil)
        XCTAssertTrue(
            result.map(\.ts) == [1000, 1010],
            "a bucketed query collapsing below 2 points falls back to the raw rows")
    }

    // chartSamples: an empty window returns [] even after the raw fallback.
    func testChartSamplesEmptyWindowReturnsEmpty() {
        let url = makeStoreURL(root: suiteRoot.appendingPathComponent("chart-empty"))
        let store = try! HistoryStore(url: url)
        try! store.insert(Sample(ts: 1000, sessionStart: 900, session: 10, week: 5, fable: 20))

        let result = try! store.chartSamples(
            window: TimeWindow(start: 5000, end: 6000), bucket: HistoryMath.weekBucket, sessionStart: nil)
        XCTAssertTrue(result.isEmpty, "an empty window returns no samples")
    }

    // Session identity filter, reconstructing the reported bug: the anchor
    // (and so the window) jitters up to a minute low between polls, sliding
    // the window start back over the previous session's last row. That row
    // sits inside the time window but its session_start names the previous
    // session, so the identity filter must drop it while keeping the current
    // session's rows — including ones whose own session_start jittered.
    func testSessionFilterExcludesPreviousSessionTail() {
        let url = makeStoreURL(root: suiteRoot.appendingPathComponent("session-filter"))
        let store = try! HistoryStore(url: url)
        let previousStart = 100_000
        let currentStart = previousStart + HistoryMath.sessionLength  // 118_000, contiguous sessions
        // Previous session's last poll, 5s before its reset, fully used.
        try! store.insert(Sample(ts: currentStart - 5, sessionStart: previousStart, session: 100, week: 50, fable: 50))
        // Current session's rows; the second one's derived identity jittered.
        try! store.insert(Sample(ts: currentStart + 300, sessionStart: currentStart, session: 5, week: 50, fable: 50))
        try! store.insert(
            Sample(ts: currentStart + 600, sessionStart: currentStart - 60, session: 8, week: 50, fable: 50))

        // The live anchor jittered 60s low, so the window starts 60s before
        // the recorded currentStart and now covers the previous row's ts.
        let window = TimeWindow(start: currentStart - 60, end: currentStart - 60 + HistoryMath.sessionLength)
        let result = try! store.chartSamples(window: window, bucket: 1, sessionStart: currentStart - 60)
        XCTAssertTrue(
            result.map(\.ts) == [currentStart + 300, currentStart + 600],
            "the previous session's tail inside the jittered window is excluded; jittered same-session rows are kept")
    }

    // Identity tolerance bounds: BETWEEN is inclusive, so a session_start
    // exactly sessionStartTolerance away matches and one second further does
    // not.
    func testSessionFilterToleranceBounds() {
        let url = makeStoreURL(root: suiteRoot.appendingPathComponent("session-tolerance"))
        let store = try! HistoryStore(url: url)
        let base = 50_000
        let tolerance = HistoryMath.sessionStartTolerance
        try! store.insert(Sample(ts: 1000, sessionStart: base - tolerance, session: 1, week: 1, fable: 1))
        try! store.insert(Sample(ts: 2000, sessionStart: base + tolerance, session: 2, week: 2, fable: 2))
        try! store.insert(Sample(ts: 3000, sessionStart: base - tolerance - 1, session: 3, week: 3, fable: 3))
        try! store.insert(Sample(ts: 4000, sessionStart: base + tolerance + 1, session: 4, week: 4, fable: 4))

        let result = try! store.samples(from: 0, to: 10_000, bucket: 1, sessionStart: base)
        XCTAssertTrue(
            result.map(\.ts) == [1000, 2000],
            "rows exactly at the tolerance bound match; one second past it are excluded")
    }

    // chartSamples applies the identity filter BEFORE the fewer-than-2-points
    // fallback decision: a stray other-session row must not count as a second
    // bucketed point (which would suppress the raw fallback and plot the
    // stray), and the raw fallback re-query must filter it too.
    func testChartSamplesFallbackKeepsSessionFilter() {
        let url = makeStoreURL(root: suiteRoot.appendingPathComponent("chart-fallback-filter"))
        let store = try! HistoryStore(url: url)
        try! store.insert(Sample(ts: 1000, sessionStart: 900, session: 10, week: 5, fable: 20))
        try! store.insert(Sample(ts: 1010, sessionStart: 900, session: 30, week: 15, fable: 40))
        // Stray row from another session, landing in a different 1800s bucket
        // (ts 1900) than the two rows above (ts < 1800).
        try! store.insert(Sample(ts: 1900, sessionStart: 5000, session: 99, week: 99, fable: 99))

        let result = try! store.chartSamples(
            window: TimeWindow(start: 0, end: 2000), bucket: HistoryMath.weekBucket, sessionStart: 900)
        XCTAssertTrue(
            result.map(\.ts) == [1000, 1010],
            "the stray row neither fakes a second bucketed point nor survives the raw fallback")
    }

    // clear() empties the table.
    func testClearEmptiesTable() {
        let url = makeStoreURL(root: suiteRoot.appendingPathComponent("clear"))
        let store = try! HistoryStore(url: url)
        try! store.insert(Sample(ts: 1, sessionStart: 1, session: 1, week: 1, fable: 1))
        try! store.clear()

        XCTAssertTrue(allRows(store).isEmpty, "clear() empties the table")
    }

    // Close and reopen: a second HistoryStore over the same file sees the
    // rows the first one wrote.
    func testReopenSeesWrittenRows() {
        let url = makeStoreURL(root: suiteRoot.appendingPathComponent("reopen"))
        var store: HistoryStore? = try! HistoryStore(url: url)
        try! store!.insert(Sample(ts: 7, sessionStart: 3, session: 70, week: 71, fable: 72))
        store = nil

        let reopened = try! HistoryStore(url: url)
        let all = allRows(reopened)
        XCTAssertTrue(
            all == [Sample(ts: 7, sessionStart: 3, session: 70, week: 71, fable: 72)],
            "a reopened store sees rows written before the previous store deallocated")
    }

    // -wal/-shm sidecars: WAL mode creates a -wal file while the store is
    // open; exclusive locking mode means no -shm file ever appears. That
    // second assertion only means something checked while still open — after
    // close, "-shm is gone" would be trivially true whether or not exclusive
    // locking mode actually took effect. The -wal file itself is only
    // removed once the store closes, which is true because `close()`
    // (called from `deinit` too) finalizes the cached insert statement
    // before closing the connection — closing with a live statement leaves
    // a zombie connection that never checkpoints or removes the sidecar.
    func testWalShmSidecars() {
        let url = makeStoreURL(root: suiteRoot.appendingPathComponent("sidecars"))
        let walPath = url.path + "-wal"
        let shmPath = url.path + "-shm"

        var store: HistoryStore? = try! HistoryStore(url: url)
        try! store!.insert(Sample(ts: 1, sessionStart: 1, session: 1, week: 1, fable: 1))
        XCTAssertTrue(FileManager.default.fileExists(atPath: walPath), "-wal sidecar exists while the store is open")
        XCTAssertTrue(
            !FileManager.default.fileExists(atPath: shmPath), "-shm sidecar never appears under exclusive locking mode")

        store = nil
        XCTAssertTrue(
            !FileManager.default.fileExists(atPath: walPath), "-wal sidecar is gone after the store deallocates")
    }

    // close() is idempotent, and removes the -wal sidecar immediately
    // without waiting for deinit.
    func testCloseIsIdempotent() {
        let url = makeStoreURL(root: suiteRoot.appendingPathComponent("close"))
        let walPath = url.path + "-wal"

        let store = try! HistoryStore(url: url)
        try! store.insert(Sample(ts: 1, sessionStart: 1, session: 1, week: 1, fable: 1))
        XCTAssertTrue(FileManager.default.fileExists(atPath: walPath), "-wal sidecar exists before close()")

        store.close()
        XCTAssertTrue(
            !FileManager.default.fileExists(atPath: walPath), "-wal sidecar is gone right after an explicit close()")

        store.close()
        XCTAssertTrue(true, "a second close() call does not crash")
    }

    // Migration: an old-shape database (nullable columns, no session_start,
    // not STRICT) is dropped and recreated with the new schema on open.
    // PRAGMA user_version defaults to 0 for a database that never set it,
    // which is exactly what every pre-v1 database is, so the same check
    // that bootstraps a fresh install also catches this case. Old rows are
    // gone (the user approved dropping old data rather than migrating it),
    // and inserts against the migrated store must work afterward.
    func testMigrationDropsOldSchema() {
        let url = makeStoreURL(root: suiteRoot.appendingPathComponent("migration"))
        var raw: OpaquePointer?
        precondition(
            sqlite3_open_v2(url.path, &raw, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
            "raw sqlite3_open_v2 failed")
        execRaw(
            raw,
            """
            CREATE TABLE samples (
              ts      INTEGER PRIMARY KEY,
              session REAL,
              week    REAL,
              fable   REAL
            )
            """)
        execRaw(raw, "INSERT INTO samples (ts, session, week, fable) VALUES (1, 10, 20, 30)")
        sqlite3_close_v2(raw)

        let store = try! HistoryStore(url: url)
        XCTAssertTrue(allRows(store).isEmpty, "migration drops the old table's rows")

        try! store.insert(Sample(ts: 100, sessionStart: 50, session: 1, week: 2, fable: 3))
        let afterInsert = allRows(store)
        XCTAssertTrue(
            afterInsert == [Sample(ts: 100, sessionStart: 50, session: 1, week: 2, fable: 3)],
            "inserts succeed against the migrated (new-shape) schema")
    }
}
