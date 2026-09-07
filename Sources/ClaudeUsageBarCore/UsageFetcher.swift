import Foundation

/// Runs the Python parser as a subprocess and decodes its JSON.
///
/// A GUI app launched from Finder inherits a minimal PATH that does not
/// include ~/.local/bin, so both the interpreter and the `claude` binary are
/// resolved by absolute path rather than trusted to PATH lookup.
package final class UsageFetcher {

    private let queue = DispatchQueue(label: "com.claudeusagebar.fetch", qos: .utility)
    private let timeout: TimeInterval = 45

    // Stock /usr/bin/python3 is preferred: the parser is 3.9-compatible, so the
    // app needs no Homebrew install to work.
    private static let pythonCandidates = [
        "/usr/bin/python3",
        "/opt/homebrew/bin/python3",
        "/usr/local/bin/python3",
    ]

    private static let claudeCandidates = [
        "~/.local/bin/claude",
        "~/.claude/local/claude",
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
        "/usr/bin/claude",
    ]

    /// Overridable in defaults for non-standard installs:
    ///   defaults write com.claudeusagebar.app claudeBin /path/to/claude
    private func override(_ key: String) -> String? {
        guard let v = UserDefaults.standard.string(forKey: key), !v.isEmpty else { return nil }
        return v
    }

    private func firstExecutable(_ paths: [String]) -> String? {
        let fm = FileManager.default
        for p in paths {
            let expanded = (p as NSString).expandingTildeInPath
            if fm.isExecutableFile(atPath: expanded) { return expanded }
        }
        return nil
    }

    /// Last resort: ask a non-login shell to resolve the tool. Non-login
    /// (`-c`, not `-lc`) so a background poller does not source the user's
    /// login dotfiles on every fetch; the candidate lists above and `PATH`
    /// set on the child process already cover the standard install
    /// locations, so this only fires for genuinely unusual setups.
    private func resolveViaShell(_ tool: String, cwd: URL?) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", "command -v \(tool)"]
        p.currentDirectoryURL = cwd
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    private func parserScriptPath() -> String? {
        if let o = override("parserPath") { return o }
        // Bundled into Contents/Resources by build.py.
        if let url = Bundle.main.url(forResource: "claude_usage", withExtension: "py") {
            return url.path
        }
        // Running straight out of the source tree (swift run).
        let dev = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // ClaudeUsageBarCore
            .deletingLastPathComponent()  // Sources
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("parser/claude_usage.py")
        return FileManager.default.isReadableFile(atPath: dev.path) ? dev.path : nil
    }

    /// Fetch a snapshot off the main thread; `completion` is called on main.
    func fetch(completion: @escaping (UsageSnapshot) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            let snapshot = self.fetchSync()
            DispatchQueue.main.async { completion(snapshot) }
        }
    }

    private func fetchSync() -> UsageSnapshot {
        // Both spawned processes below pin this as their cwd. Left unset, a
        // subprocess inherits the app's cwd -- `/` when launched from
        // Finder -- and Claude Code scans its cwd for workspace context,
        // which from `/` can reach TCC-protected locations (network
        // volumes, etc.). The app-support dir is benign, but this runs
        // on EVERY poll, so a `try!` here would
        // crash-loop the whole app on a one-off failure (a regular file at
        // the path, EPERM, ENOSPC): a missing cwd instead degrades to
        // inheriting the app's own cwd, same as an unset `currentDirectoryURL`.
        let cwd = try? HistoryStore.appSupportDirectory()

        guard
            let python = override("pythonBin").flatMap({ firstExecutable([$0]) })
                ?? firstExecutable(Self.pythonCandidates)
                ?? resolveViaShell("python3", cwd: cwd)
        else { return .failure("No python3 found (looked in /usr/bin, Homebrew, PATH).") }

        guard let script = parserScriptPath() else {
            return .failure("Bundled parser claude_usage.py is missing.")
        }

        guard
            let claude = override("claudeBin").flatMap({ firstExecutable([$0]) })
                ?? firstExecutable(Self.claudeCandidates)
                ?? resolveViaShell("claude", cwd: cwd)
        else {
            return .failure(
                "Could not find the claude CLI. Set it with:\n"
                    + "defaults write com.claudeusagebar.app claudeBin /path/to/claude")
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: python)
        proc.arguments = [script, "--claude-bin", claude, "--timeout", "30"]
        proc.currentDirectoryURL = cwd
        // Give the child a usable PATH even though ours is minimal.
        var env = ProcessInfo.processInfo.environment
        let claudeDir = (claude as NSString).deletingLastPathComponent
        env["PATH"] = [
            claudeDir, "/usr/bin", "/bin", "/usr/sbin", "/sbin",
            "/opt/homebrew/bin", "/usr/local/bin",
        ].joined(separator: ":")
        proc.environment = env

        let stdout = Pipe(), stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr

        do { try proc.run() } catch {
            return .failure("Could not launch parser: \(error.localizedDescription)")
        }

        // Watchdog, so a hung `claude` cannot wedge the app forever. Scheduled
        // on the global queue rather than `queue`: this call runs on `queue`
        // itself (see `fetch(completion:)`), which is about to block in
        // `waitUntilExit()` below, so a work item queued there would never
        // get a chance to run.
        let deadline = DispatchWorkItem { if proc.isRunning { proc.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)

        // Drain stdout and stderr concurrently, not one after the other: if
        // the child fills the other pipe's 64KB buffer while blocked writing
        // to it, reading them serially deadlocks (parent blocked reading the
        // first pipe, child blocked writing the second).
        var errData = Data()
        let stderrGroup = DispatchGroup()
        stderrGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            errData = stderr.fileHandleForReading.readDataToEndOfFile()
            stderrGroup.leave()
        }
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        stderrGroup.wait()

        proc.waitUntilExit()
        deadline.cancel()

        guard !outData.isEmpty else {
            let err = String(decoding: errData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(err.isEmpty ? "Parser produced no output." : err)
        }

        return Self.decodeSnapshot(outData)
    }

    /// Decodes parser stdout into a snapshot. A static function (rather than
    /// inline in `fetchSync`) so tests exercise this exact production path.
    package static func decodeSnapshot(_ data: Data) -> UsageSnapshot {
        do {
            return try JSONDecoder().decode(UsageSnapshot.self, from: data)
        } catch {
            return .failure("could not decode parser output: \(error.localizedDescription)")
        }
    }
}
