import Foundation

/// Owns the on-disk `HistoryStore` reference and confines every touch of
/// it — open, insert, query, clear — to one serial, off-main `queue`;
/// nothing outside this type can reach the store directly, so nothing
/// outside this type can touch it off that queue. The machine tracks only
/// availability (`UsageState.history`); this type is what actually opens,
/// reads, and writes.
///
/// Every write and query traps on failure (`try!`): a failure after a
/// successful open means the store is corrupt, a fail-hard condition
/// rather than a recoverable one, so no method here catches a store error
/// — it lets the trap surface instead of silently dropping a sample or
/// rendering an empty chart.
final class HistoryCoordinator {
    private let queue = DispatchQueue(label: "com.claudeusagebar.history", qos: .utility)
    /// Main-thread-owned reference; the store it points at is only ever
    /// used from `queue`.
    private var store: HistoryStore?

    /// Opens the store at `HistoryStore.defaultURL()` off-main and reports
    /// success or failure back on main via `onOpened`/`onFailed`. Shared by
    /// the initial open and `resetAndReopen`'s recovery path.
    func open(onOpened: @escaping () -> Void, onFailed: @escaping (String) -> Void) {
        queue.async { [weak self] in self?.openOnQueue(onOpened: onOpened, onFailed: onFailed) }
    }

    /// Opens the store; must already be running on `queue`. Shared by
    /// `open` and `resetAndReopen`'s recovery path, so both funnel through
    /// the same open-then-report logic.
    private func openOnQueue(onOpened: @escaping () -> Void, onFailed: @escaping (String) -> Void) {
        do {
            let store = try HistoryStore(url: try HistoryStore.defaultURL())
            DispatchQueue.main.async { [weak self] in
                self?.store = store
                onOpened()
            }
        } catch {
            let message = String(describing: error).lowercased()
            DispatchQueue.main.async { [weak self] in
                self?.store = nil
                onFailed(message)
            }
        }
    }

    /// Records one sample, gating only on the store reference being open —
    /// the machine already gates recording on trust, metric completeness,
    /// and history availability, so this guard is close to dead code by
    /// construction. Fire-and-forget: queued and returned immediately,
    /// since a write failure here means the store is corrupt (see the
    /// type's fail-hard rationale above).
    func insert(_ sample: Sample) {
        guard let store else { return }
        queue.async { try! store.insert(sample) }
    }

    /// Queries the session and week windows for the history panel, handing
    /// both arrays to `completion` on main (synchronously, on the calling
    /// thread, if the store is not open). The session query is scoped to
    /// the CURRENT session twice over: a nil `sessionAnchor` means no
    /// trusted session in the current state, so a trailing-window query
    /// would misleadingly replot samples as the current session, which is
    /// not known to exist; and a present anchor also scopes the rows by
    /// session identity (`PanelModel.sessionStart(resetAnchor:)`), since the
    /// anchor — and the time window derived from it — jitters by up to a
    /// minute between polls, enough for a window-only query to sweep in the
    /// previous session's tail. A FROZEN session (`UsageMachine`'s
    /// `trustedSnapshot`) keeps its anchor, now past — so between windows
    /// this still queries and renders the expired window, consistent with
    /// freezing the last real state.
    func chartSamples(
        sessionWindow: TimeWindow, sessionAnchor: Int?, weekWindow: TimeWindow,
        completion: @escaping (_ sessionSamples: [Sample], _ weekSamples: [Sample]) -> Void
    ) {
        guard let store else {
            completion([], [])
            return
        }
        queue.async {
            let sessionSamples: [Sample]
            if let sessionAnchor {
                sessionSamples = try! store.chartSamples(
                    window: sessionWindow, bucket: 1,
                    sessionStart: PanelModel.sessionStart(resetAnchor: sessionAnchor))
            } else {
                sessionSamples = []
            }
            let weekSamples = try! store.chartSamples(
                window: weekWindow, bucket: HistoryMath.weekBucket, sessionStart: nil)
            DispatchQueue.main.async { completion(sessionSamples, weekSamples) }
        }
    }

    /// Deletes all recorded samples. Callable only once `open` has reported
    /// success — the menu only offers "Clear History…" when
    /// `UsageState.history == .available` — and traps otherwise: unlike
    /// `insert`, this path has no history-unset state to tolerate silently.
    func clear() {
        let store = store!
        queue.async { try! store.clear() }
    }

    /// Recovery path for an unopenable database (`UsageState.history ==
    /// .unavailable`): deletes the database file (and its `-wal` sidecar,
    /// if one is present) and re-attempts the open through the same
    /// routine `open` uses, so a corrupt or otherwise unopenable store is
    /// not a dead end.
    func resetAndReopen(onOpened: @escaping () -> Void, onFailed: @escaping (String) -> Void) {
        queue.async { [weak self] in
            let url = try! HistoryStore.defaultURL()
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-wal"))
            self?.openOnQueue(onOpened: onOpened, onFailed: onFailed)
        }
    }

    /// Closes the store for app termination, synchronously so the WAL
    /// checkpoint finishes before the process exits: `NSApp.terminate` ends
    /// the process via `exit()`, so `deinit` never runs and this must be
    /// called explicitly instead.
    func close() {
        guard let store else { return }
        self.store = nil
        queue.sync { store.close() }
    }
}
