import Foundation

/// One row of the live feed: a session as AgentDeck sees it AFTER merging
/// hooks, Claude's registry and discovery — the list a viewer can't rebuild
/// from transcripts alone, because transcripts don't say whether their
/// process is still running.
public struct LiveSession: Codable, Equatable, Sendable {
    public var key: String
    public var provider: Provider
    public var sessionId: String
    public var state: SessionState
    public var event: String
    public var updatedAt: Date
    public var projectPath: String
    public var agentPid: Int32?
    public var name: String?
    public var model: String?
    public var waitingReason: String?
    /// Surfaced from Claude's registry, never seen by a hook.
    public var discovered: Bool
    /// A daemonized Claude background session (no window of its own).
    public var background: Bool
    /// Codex only: the Claude session whose process tree launched it.
    public var parentSessionId: String?
    /// The process is demonstrably still there. A row alone is not that
    /// evidence — a pid-less snapshot is kept a day after its process exits.
    public var running: Bool
    /// When `agentPid` started. Pid + start time is a process identity, so a
    /// consumer acting on the pid later (closing a session) can tell a
    /// recycled pid from the original.
    public var processStartedAt: Date?
    /// `agentPid` is a Codex app-server shared by many threads: it never
    /// sends SessionEnd and must never be signalled on one thread's behalf.
    public var sharedProcess: Bool

    public init(
        key: String, provider: Provider, sessionId: String, state: SessionState,
        event: String, updatedAt: Date, projectPath: String, agentPid: Int32?,
        name: String?, model: String?, waitingReason: String?, discovered: Bool,
        background: Bool, parentSessionId: String?, running: Bool,
        processStartedAt: Date?, sharedProcess: Bool
    ) {
        self.key = key
        self.provider = provider
        self.sessionId = sessionId
        self.state = state
        self.event = event
        self.updatedAt = updatedAt
        self.projectPath = projectPath
        self.agentPid = agentPid
        self.name = name
        self.model = model
        self.waitingReason = waitingReason
        self.discovered = discovered
        self.background = background
        self.parentSessionId = parentSessionId
        self.running = running
        self.processStartedAt = processStartedAt
        self.sharedProcess = sharedProcess
    }

    private enum CodingKeys: String, CodingKey {
        case key, provider, sessionId, state, event, updatedAt, projectPath
        case agentPid, name, model, waitingReason, discovered, background
        case parentSessionId, running, processStartedAt, sharedProcess
    }

    // Written by hand so absent values are emitted as explicit nulls. The
    // synthesized encoder drops nil optionals, and a JavaScript consumer
    // then can't tell "AgentDeck has no pid" from "this field doesn't exist
    // in the version that wrote the file".
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(key, forKey: .key)
        try c.encode(provider, forKey: .provider)
        try c.encode(sessionId, forKey: .sessionId)
        try c.encode(state, forKey: .state)
        try c.encode(event, forKey: .event)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(projectPath, forKey: .projectPath)
        try c.encode(agentPid, forKey: .agentPid)
        try c.encode(name, forKey: .name)
        try c.encode(model, forKey: .model)
        try c.encode(waitingReason, forKey: .waitingReason)
        try c.encode(discovered, forKey: .discovered)
        try c.encode(background, forKey: .background)
        try c.encode(parentSessionId, forKey: .parentSessionId)
        try c.encode(running, forKey: .running)
        try c.encode(processStartedAt, forKey: .processStartedAt)
        try c.encode(sharedProcess, forKey: .sharedProcess)
    }
}

/// The whole file. `generatedAt` doubles as a heartbeat: the app rewrites
/// it on every 15-second sweep even when nothing changed, so a reader can
/// tell a quiet machine from an AgentDeck that has stopped running.
public struct LiveFeed: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var generatedAt: Date
    public var appPid: Int32
    public var sessions: [LiveSession]

    public init(
        schemaVersion: Int = LiveFeed.currentSchemaVersion,
        generatedAt: Date, appPid: Int32, sessions: [LiveSession]
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.appPid = appPid
        self.sessions = sessions
    }
}

/// Publishes AgentDeck's merged session list for external viewers (the 3D
/// office). Everything here is pure or takes its process lookups as
/// closures, so the rules are testable without live agents; the app
/// supplies the real `ProcessTree`/`Liveness` probes.
public enum LiveExport {
    public static var defaultURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentDeck/live.json")
    }

    /// Per-row facts about the session's process, gathered by the caller.
    public struct ProcessFacts: Equatable, Sendable {
        public var running: Bool
        public var startedAt: Date?
        public var shared: Bool

        public init(running: Bool, startedAt: Date?, shared: Bool) {
            self.running = running
            self.startedAt = startedAt
            self.shared = shared
        }
    }

    /// Builds the feed from the rows the popover shows plus the side tables
    /// the model keeps. Names follow each provider's own source of truth —
    /// Claude's registry, Codex's `/rename` index — and nothing else, so a
    /// terminal title never leaks into another app's UI.
    public static func makeFeed(
        rows: [SessionSnapshot],
        waitingReasons: [String: String],
        claudeLive: [String: ClaudeSessionRegistry.Entry],
        codexNames: [String: String],
        claudeModels: [String: String],
        claudeSessionKinds: [String: String],
        parentOf: (SessionSnapshot) -> String?,
        process: (SessionSnapshot) -> ProcessFacts,
        appPid: Int32,
        now: Date
    ) -> LiveFeed {
        let sessions = rows.map { row -> LiveSession in
            let name: String?
            switch row.provider {
            case .claude: name = claudeLive[row.sessionId]?.name
            case .codex: name = codexNames[row.sessionId]
            }
            let facts = process(row)
            return LiveSession(
                key: row.key,
                provider: row.provider,
                sessionId: row.sessionId,
                state: row.state,
                event: row.event,
                updatedAt: row.updatedAt,
                projectPath: row.projectPath,
                agentPid: row.agentPid,
                name: name?.isEmpty == true ? nil : name,
                model: claudeModels[row.sessionId] ?? row.model,
                waitingReason: waitingReasons[row.key],
                discovered: row.event == "RegistryDiscovery",
                background: claudeSessionKinds[row.sessionId] == "bg",
                // only Codex is ever launched BY another session; a Claude
                // row's ancestors are the terminal and shell
                parentSessionId: row.provider == .codex ? parentOf(row) : nil,
                running: facts.running,
                processStartedAt: facts.startedAt,
                sharedProcess: facts.shared
            )
        }
        return LiveFeed(generatedAt: now, appPid: appPid, sessions: sessions)
    }

    /// The Claude session whose process launched `agentPid`, found by
    /// walking ancestors. A Codex run from Claude's Bash tool sits under one
    /// or more shells, so the immediate parent is rarely Claude itself. A
    /// Claude-looking ancestor with no registry entry (a wrapper, a stale
    /// file) is passed over rather than ending the walk. launchd (pid 1)
    /// ends it: anything reparented there was orphaned or daemonized, and
    /// has no session parent to report.
    public static func parentClaudeSession(
        agentPid: Int32,
        parentPid: (Int32) -> Int32?,
        isClaude: (Int32) -> Bool,
        registry: [Int32: ClaudeSessionRegistry.Entry],
        maxDepth: Int = 12
    ) -> String? {
        var current = parentPid(agentPid)
        var depth = 0
        while let pid = current, depth < maxDepth {
            guard pid > 1 else { return nil }
            if isClaude(pid), let id = registry[pid]?.sessionId { return id }
            guard let next = parentPid(pid), next != pid else { return nil }
            current = next
            depth += 1
        }
        return nil
    }

    /// Millisecond ISO 8601 in UTC, keys sorted, nulls explicit: the shape
    /// the Node consumer parses with `Date.parse` and diffs cheaply.
    public static func encode(_ feed: LiveFeed) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(SnapshotStore.isoFractional.string(from: date))
        }
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(feed)
    }

    public static func decode(_ data: Data) throws -> LiveFeed {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            guard let date = SnapshotStore.isoFractional.date(from: s) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: dec.codingPath, debugDescription: "unparseable date \(s)"
                ))
            }
            return date
        }
        return try decoder.decode(LiveFeed.self, from: data)
    }

    /// Temp file + rename, so a reader polling the file never sees a
    /// half-written document. Owner-only (0600): the feed lists project
    /// paths and what each session is waiting on.
    /// `Data.write(.atomic)` would recreate the file 0644 on every write.
    public static func write(_ feed: LiveFeed, to url: URL) throws {
        let data = try encode(feed)
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(getpid()).tmp")
        try? fm.removeItem(at: tmp)
        guard fm.createFile(atPath: tmp.path, contents: data,
                            attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: tmp.path])
        }
        guard rename(tmp.path, url.path) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            try? fm.removeItem(at: tmp)
            throw POSIXError(code)
        }
    }
}
