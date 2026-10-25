import Foundation
import Testing
@testable import AgentDeckCore

struct LiveExportTests {
    let now = Date(timeIntervalSince1970: 1_792_918_982.793)  // 2026-10-25T09:03:02.793Z

    func snapshot(
        _ provider: Provider, _ id: String, pid: Int32? = nil,
        event: String = "UserPromptSubmit", model: String? = nil
    ) -> SessionSnapshot {
        SessionSnapshot(
            provider: provider, sessionId: id, projectPath: "/tmp/p", state: .working,
            event: event, updatedAt: now, agentPid: pid, model: model
        )
    }

    func feed(
        _ rows: [SessionSnapshot],
        claudeLive: [String: ClaudeSessionRegistry.Entry] = [:],
        codexNames: [String: String] = [:],
        claudeModels: [String: String] = [:],
        kinds: [String: String] = [:],
        waiting: [String: String] = [:],
        parentOf: (SessionSnapshot) -> String? = { _ in nil },
        process: (SessionSnapshot) -> LiveExport.ProcessFacts = { _ in
            .init(running: false, startedAt: nil, shared: false)
        }
    ) -> LiveFeed {
        LiveExport.makeFeed(
            rows: rows, waitingReasons: waiting, claudeLive: claudeLive,
            codexNames: codexNames, claudeModels: claudeModels,
            claudeSessionKinds: kinds, parentOf: parentOf, process: process,
            appPid: 4242, now: now
        )
    }

    @Test func encodeUsesIsoMillisAndNulls() throws {
        let data = try LiveExport.encode(feed([snapshot(.claude, "c1")]))
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"generatedAt\":\"2026-10-25T09:03:02.793Z\""))
        #expect(json.contains("\"agentPid\":null"))
        #expect(json.contains("\"parentSessionId\":null"))
        #expect(json.contains("\"processStartedAt\":null"))
        #expect(json.contains("\"schemaVersion\":1"))
        #expect(json.contains("\"appPid\":4242"))
    }

    @Test func namePrecedencePerProvider() {
        let entry = ClaudeSessionRegistry.Entry(
            pid: 80, sessionId: "c1", status: "busy", name: "okcloud-56"
        )
        let result = feed(
            [snapshot(.claude, "c1"), snapshot(.codex, "x1"), snapshot(.claude, "c2")],
            claudeLive: ["c1": entry],
            // a Codex name for a Claude id must not be used, and vice versa
            codexNames: ["x1": "renamed-codex", "c2": "wrong"]
        )
        #expect(result.sessions.map(\.name) == ["okcloud-56", "renamed-codex", nil])
    }

    @Test func derivedFieldsFollowTheirSources() {
        let rows = [
            snapshot(.claude, "c1", event: "RegistryDiscovery", model: "payload-model"),
            snapshot(.codex, "x1", model: "gpt-x"),
        ]
        let result = feed(
            rows, claudeModels: ["c1": "claude-opus-5-5"], kinds: ["c1": "bg"],
            waiting: ["claude-c1": "permission prompt"]
        )
        let claude = result.sessions[0], codex = result.sessions[1]
        #expect(claude.model == "claude-opus-5-5")
        #expect(claude.discovered && claude.background)
        #expect(claude.waitingReason == "permission prompt")
        #expect(codex.model == "gpt-x")
        #expect(!codex.discovered && !codex.background && codex.waitingReason == nil)
    }

    // MARK: - Parent session

    let registry: [Int32: ClaudeSessionRegistry.Entry] = [
        80: .init(pid: 80, sessionId: "c1", status: "busy"),
    ]

    @Test func parentFoundThroughShellAncestors() {
        let parents: [Int32: Int32] = [100: 90, 90: 80, 80: 70, 70: 1]
        let found = LiveExport.parentClaudeSession(
            agentPid: 100, parentPid: { parents[$0] }, isClaude: { $0 == 80 },
            registry: registry
        )
        #expect(found == "c1")
    }

    @Test func parentSkipsClaudeAncestorWithoutRegistryEntry() {
        let parents: [Int32: Int32] = [100: 95, 95: 80, 80: 1]
        let found = LiveExport.parentClaudeSession(
            agentPid: 100, parentPid: { parents[$0] }, isClaude: { $0 == 95 || $0 == 80 },
            registry: registry
        )
        #expect(found == "c1")
    }

    @Test func parentStopsAtLaunchd() {
        // 80 is in the registry but sits above launchd's reparented child
        let parents: [Int32: Int32] = [100: 1, 1: 80]
        let found = LiveExport.parentClaudeSession(
            agentPid: 100, parentPid: { parents[$0] }, isClaude: { _ in true },
            registry: registry
        )
        #expect(found == nil)
    }

    @Test func parentDepthLimit() {
        // claude 15 levels up: beyond the default limit of 12
        var parents: [Int32: Int32] = [:]
        for pid in Int32(201)...Int32(215) { parents[pid] = pid - 1 }
        parents[200] = 80
        let isClaude: (Int32) -> Bool = { $0 == 80 }
        #expect(LiveExport.parentClaudeSession(
            agentPid: 215, parentPid: { parents[$0] }, isClaude: isClaude,
            registry: registry
        ) == nil)
        #expect(LiveExport.parentClaudeSession(
            agentPid: 215, parentPid: { parents[$0] }, isClaude: isClaude,
            registry: registry, maxDepth: 20
        ) == "c1")
    }

    @Test func claudeRowsHaveNoParent() {
        var asked: [String] = []
        let result = feed(
            [snapshot(.claude, "c2", pid: 10), snapshot(.codex, "x1", pid: 11)],
            parentOf: { asked.append($0.sessionId); return "c1" }
        )
        #expect(asked == ["x1"])
        #expect(result.sessions.map(\.parentSessionId) == [nil, "c1"])
    }

    @Test func processFactsCopiedPerRow() {
        let started = Date(timeIntervalSince1970: 1_792_900_000.5)
        let result = feed(
            [snapshot(.claude, "c1", pid: 10), snapshot(.codex, "x1", pid: 11)],
            process: { row in
                row.provider == .claude
                    ? .init(running: true, startedAt: started, shared: false)
                    : .init(running: false, startedAt: nil, shared: true)
            }
        )
        let claude = result.sessions[0], codex = result.sessions[1]
        #expect(claude.running && claude.processStartedAt == started && !claude.sharedProcess)
        #expect(!codex.running && codex.processStartedAt == nil && codex.sharedProcess)
        #expect(claude.agentPid == 10 && codex.agentPid == 11)
    }

    @Test func writeIsAtomicAndReadable() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-export-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        // the parent directory doesn't exist yet: write must create it
        let url = dir.appendingPathComponent("nested/live.json")
        let original = feed(
            [snapshot(.codex, "x1", pid: 11)],
            parentOf: { _ in "c1" },
            process: { _ in .init(running: true, startedAt: self.now, shared: false) }
        )
        try LiveExport.write(original, to: url)
        try LiveExport.write(original, to: url)  // replacing an existing file
        let decoded = try LiveExport.decode(Data(contentsOf: url))
        #expect(decoded == original)
        let leftovers = try FileManager.default
            .contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(leftovers == ["live.json"])
    }
}
