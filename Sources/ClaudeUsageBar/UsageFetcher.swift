import Foundation

/// Runs the Python parser as a subprocess and decodes its JSON.
///
/// A GUI app launched from Finder inherits a minimal PATH that does not
/// include ~/.local/bin, so both the interpreter and the `claude` binary are
/// resolved by absolute path rather than trusted to PATH lookup.
final class UsageFetcher {

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

    /// Last resort: ask a login shell, which sources the user's profile and so
    /// knows about PATH additions this app cannot see.
    private func resolveViaLoginShell(_ tool: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v \(tool)"]
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
            .deletingLastPathComponent()   // ClaudeUsageBar
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // repo root
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
        guard let python = override("pythonBin").flatMap({ firstExecutable([$0]) })
            ?? firstExecutable(Self.pythonCandidates)
            ?? resolveViaLoginShell("python3")
        else { return .failure("No python3 found (looked in /usr/bin, Homebrew, PATH).") }

        guard let script = parserScriptPath() else {
            return .failure("Bundled parser claude_usage.py is missing.")
        }

        guard let claude = override("claudeBin").flatMap({ firstExecutable([$0]) })
            ?? firstExecutable(Self.claudeCandidates)
            ?? resolveViaLoginShell("claude")
        else {
            return .failure("Could not find the claude CLI. Set it with:\n"
                            + "defaults write com.claudeusagebar.app claudeBin /path/to/claude")
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: python)
        proc.arguments = [script, "--claude-bin", claude, "--timeout", "30"]
        // Give the child a usable PATH even though ours is minimal.
        var env = ProcessInfo.processInfo.environment
        let claudeDir = (claude as NSString).deletingLastPathComponent
        env["PATH"] = [claudeDir, "/usr/bin", "/bin", "/usr/sbin", "/sbin",
                       "/opt/homebrew/bin", "/usr/local/bin"].joined(separator: ":")
        proc.environment = env

        let stdout = Pipe(), stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr

        do { try proc.run() } catch {
            return .failure("Could not launch parser: \(error.localizedDescription)")
        }

        // Read before waiting: a full pipe buffer would otherwise deadlock.
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()

        // Watchdog, so a hung `claude` cannot wedge the app forever.
        let deadline = DispatchWorkItem { if proc.isRunning { proc.terminate() } }
        queue.asyncAfter(deadline: .now() + timeout, execute: deadline)
        proc.waitUntilExit()
        deadline.cancel()

        guard !outData.isEmpty else {
            let err = String(decoding: errData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(err.isEmpty ? "Parser produced no output." : err)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(UsageSnapshot.self, from: outData)
        } catch {
            return .failure("Could not decode parser output: \(error.localizedDescription)")
        }
    }
}
