import AgentDeckCore
import Darwin
import Foundation

/// Runs the bundled whatsmyagentdoing server (the 3D office) as a child
/// process and keeps it running. The office reads AgentDeck's live feed, so
/// it is started in `--managed` mode: never the "already running" shortcut
/// (any other copy on the port would be mistaken for ours), and it answers
/// `/api/ping` with the instance id we hand it — the only proof that the
/// server on a port is the one this app launched.
@MainActor
final class OfficeServer: ObservableObject {
    enum Status: Equatable {
        case starting
        case running(URL)
        case failed(String)
    }

    @Published private(set) var status: Status = .starting

    private static let firstPort = 4600
    private static let maxConsecutiveFailures = 5
    /// A child that stayed up this long counts as healthy: the failure count
    /// and backoff start over if it dies later.
    private static let healthyUptime: TimeInterval = 30
    private static let startupTimeout: TimeInterval = 20

    private var process: Process?
    /// Bumped per launch; callbacks from an older child are ignored, so a
    /// late exit of a replaced process can't trigger a second restart.
    private var generation = 0
    private var consecutiveFailures = 0
    private var stopped = true
    private var launchedAt: Date?
    private var restartWork: DispatchWorkItem?
    private var startupTimer: DispatchWorkItem?
    private var stdoutBuffer = ""
    private var stderrTail = ""

    // MARK: - Locating the pieces

    /// Node from the usual install locations, then whatever a login shell
    /// finds — a GUI app's PATH is only /usr/bin:/bin:/usr/sbin:/sbin, so
    /// nvm/asdf installs are visible only through the user's shell profile.
    /// `AGENTDECK_NODE`, when set, is the ONLY candidate: an override that
    /// silently fell back to another node would hide a broken setting.
    nonisolated static func resolveNode() -> URL? {
        let fm = FileManager.default
        if let override = ProcessInfo.processInfo.environment["AGENTDECK_NODE"] {
            return fm.isExecutableFile(atPath: override) ? URL(fileURLWithPath: override) : nil
        }
        for path in ["/opt/homebrew/bin/node", "/usr/local/bin/node"]
        where fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        let result = BoundedSubprocess.run(
            "/bin/zsh", arguments: ["-lc", "command -v node"], timeout: 5
        )
        guard !result.timedOut, result.status == 0 else { return nil }
        let found = String(decoding: result.output, as: UTF8.self)
            .split(separator: "\n").map(String.init)
            .last { $0.hasPrefix("/") }
        guard let found, fm.isExecutableFile(atPath: found) else { return nil }
        return URL(fileURLWithPath: found)
    }

    /// Major version of the node at `url`, or nil if it won't say.
    nonisolated static func nodeMajorVersion(_ url: URL) -> Int? {
        let result = BoundedSubprocess.run(url.path, arguments: ["--version"], timeout: 5)
        guard !result.timedOut, result.status == 0 else { return nil }
        let text = String(decoding: result.output, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("v") else { return nil }
        return Int(text.dropFirst().prefix { $0.isNumber })
    }

    /// `AGENTDECK_OFFICE_DIR` (for running against a checkout) or the copy
    /// packaged into the app's Resources.
    nonisolated static func officeDirectory() -> URL? {
        let candidate: URL?
        if let override = ProcessInfo.processInfo.environment["AGENTDECK_OFFICE_DIR"] {
            candidate = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            candidate = Bundle.main.resourceURL?.appendingPathComponent("office", isDirectory: true)
        }
        guard let candidate,
              FileManager.default.fileExists(
                  atPath: candidate.appendingPathComponent("bin/cli.js").path)
        else { return nil }
        return candidate
    }

    // MARK: - Lifecycle

    func start() {
        guard stopped else { return }
        stopped = false
        consecutiveFailures = 0
        launch()
    }

    /// SIGTERM only; the server shuts down cleanly on it.
    func stop() {
        stopped = true
        generation += 1
        restartWork?.cancel()
        startupTimer?.cancel()
        if let process, process.isRunning { process.terminate() }
        process = nil
    }

    /// The Retry button: a fresh start with the failure count cleared.
    func restart() {
        stop()
        status = .starting
        start()
    }

    private func launch() {
        generation += 1
        let gen = generation
        status = .starting
        stdoutBuffer = ""
        stderrTail = ""
        // Node lookup may run a login shell; keep it off the main thread.
        Task.detached {
            let node = OfficeServer.resolveNode()
            let major = node.flatMap(OfficeServer.nodeMajorVersion)
            let office = OfficeServer.officeDirectory()
            await MainActor.run { [weak self] in
                guard let self, gen == self.generation, !self.stopped else { return }
                guard let node, let major, major >= 18 else {
                    // retrying won't conjure a node; fail at once
                    self.giveUp("Node.js 18+ not found. Install it (brew install node) "
                                + "or set AGENTDECK_NODE to its path.")
                    return
                }
                guard let office else {
                    self.giveUp("The office files aren't in this build "
                                + "(Contents/Resources/office/bin/cli.js is missing).")
                    return
                }
                self.spawn(node: node, office: office, generation: gen)
            }
        }
    }

    private func spawn(node: URL, office: URL, generation gen: Int) {
        let instance = UUID().uuidString
        let process = Process()
        process.executableURL = node
        process.arguments = [
            office.appendingPathComponent("bin/cli.js").path,
            "--managed", instance,
            "--port", String(Self.firstPort),
            "--agentdeck", LiveExport.defaultURL.path,
        ]
        process.currentDirectoryURL = office
        var env = ProcessInfo.processInfo.environment
        // the bundled copy must never try to update itself from upstream
        env["WMAD_NO_UPDATE_CHECK"] = "1"
        process.environment = env
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        // Handlers run on a background queue; DispatchQueue.main keeps the
        // chunks in arrival order, which separate Tasks would not guarantee.
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.consumeStdout(data, generation: gen, instance: instance) }
            }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.consumeStderr(data, generation: gen) }
            }
        }
        process.terminationHandler = { [weak self] p in
            let code = p.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.childExited(code: code, generation: gen) }
            }
        }
        do {
            try process.run()
        } catch {
            failed("couldn't start node: \(error.localizedDescription)", generation: gen)
            return
        }
        self.process = process
        launchedAt = Date()
        SessionsModel.appLog("office: started pid \(process.processIdentifier) instance \(instance)")
        let timer = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, gen == self.generation, self.status == .starting else { return }
                self.failed("the office server didn't report a port within "
                            + "\(Int(Self.startupTimeout))s", generation: gen)
            }
        }
        startupTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.startupTimeout, execute: timer)
    }

    private func consumeStdout(_ data: Data, generation gen: Int, instance: String) {
        guard gen == generation else { return }
        stdoutBuffer += String(decoding: data, as: UTF8.self)
        while let newline = stdoutBuffer.firstIndex(of: "\n") {
            let line = String(stdoutBuffer[..<newline])
            stdoutBuffer.removeSubrange(...newline)
            guard status == .starting, let port = Self.port(fromStartupLine: line) else { continue }
            verify(port: port, instance: instance, generation: gen)
        }
        // a server that never prints a newline mustn't grow this forever
        if stdoutBuffer.count > 8192 { stdoutBuffer = String(stdoutBuffer.suffix(1024)) }
    }

    /// The one line we trust for the port: the server's own
    /// "… → http://localhost:<port>" banner. Its update hints and other
    /// output are ignored.
    nonisolated static func port(fromStartupLine line: String) -> Int? {
        guard let match = line.firstMatch(of: /→ http:\/\/localhost:(\d+)/),
              let port = Int(match.1), (1...65535).contains(port) else { return nil }
        return port
    }

    private func consumeStderr(_ data: Data, generation gen: Int) {
        guard gen == generation else { return }
        stderrTail = String((stderrTail + String(decoding: data, as: UTF8.self)).suffix(2000))
    }

    /// Port printed is not enough: confirm the server there is the one we
    /// launched (its instance id) and that our child is still alive.
    private func verify(port: Int, instance: String, generation gen: Int) {
        guard let pingURL = URL(string: "http://127.0.0.1:\(port)/api/ping") else { return }
        Task { [weak self] in
            var matched = false
            for attempt in 0..<5 {
                if attempt > 0 { try? await Task.sleep(nanoseconds: 300_000_000) }
                var request = URLRequest(url: pingURL)
                request.timeoutInterval = 2
                guard let (data, _) = try? await URLSession.shared.data(for: request),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }
                matched = object["instance"] as? String == instance
                break
            }
            guard let self, gen == self.generation, !self.stopped else { return }
            guard matched, self.process?.isRunning == true else {
                self.failed("the server on port \(port) isn't the one AgentDeck started",
                            generation: gen)
                return
            }
            self.startupTimer?.cancel()
            guard let url = URL(string: "http://localhost:\(port)") else { return }
            SessionsModel.appLog("office: running at \(url.absoluteString)")
            self.status = .running(url)
        }
    }

    private func childExited(code: Int32, generation gen: Int) {
        guard gen == generation, !stopped else { return }
        let reason = Self.summary(stderr: stderrTail)
            ?? "the office server exited (status \(code))"
        failed(reason, generation: gen)
    }

    /// One failed launch or crash: count it, then retry after 1s, 2s, 4s …
    /// capped at 60s, until five in a row have failed.
    private func failed(_ reason: String, generation gen: Int) {
        guard gen == generation, !stopped else { return }
        startupTimer?.cancel()
        if let launchedAt, Date().timeIntervalSince(launchedAt) >= Self.healthyUptime {
            consecutiveFailures = 0
        }
        consecutiveFailures += 1
        SessionsModel.appLog("office: failure \(consecutiveFailures): \(reason)")
        // invalidate this child's callbacks before signalling it
        generation += 1
        if let process, process.isRunning { process.terminate() }
        process = nil
        launchedAt = nil
        guard consecutiveFailures < Self.maxConsecutiveFailures else {
            giveUp(reason)
            return
        }
        status = .starting
        let delay = min(60, pow(2, Double(consecutiveFailures - 1)))
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.stopped else { return }
                self.launch()
            }
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func giveUp(_ reason: String) {
        SessionsModel.appLog("office: giving up: \(reason)")
        status = .failed(reason)
    }

    /// The last few meaningful stderr lines — usually the exception message
    /// — rather than a whole stack trace.
    nonisolated static func summary(stderr: String) -> String? {
        let lines = stderr.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("at ") }
        guard !lines.isEmpty else { return nil }
        return lines.suffix(3).joined(separator: " — ")
    }
}
