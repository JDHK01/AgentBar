import AgentBarCore
import Foundation
import XCTest

final class ParserTests: XCTestCase {
    func testHighRiskMatcher() {
        XCTAssertEqual(HookApprovalManager.matchedHighRiskRule(in: "rm -rf .build && swift build"), "rm -rf")
        XCTAssertEqual(HookApprovalManager.matchedHighRiskRule(in: "git push --force origin main"), "git push --force")
        XCTAssertNil(HookApprovalManager.matchedHighRiskRule(in: "swift test"))
    }

    func testCodexMultiShardDeduplicationPreservesLatestStateAndCumulativeTokens() async throws {
        let fm = FileManager.default
        let tempHome = fm.temporaryDirectory.appendingPathComponent("agentbar-test-codex-\(UUID().uuidString)")
        let dayDir = tempHome.appendingPathComponent(".codex/sessions/2026/11/19")
        try fm.createDirectory(at: dayDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempHome) }

        let sharedID = "01a1f304-3559-7223-8f2a-f5fca907db41"
        let oldShardURL = dayDir.appendingPathComponent("rollout-2026-11-19T16-55-01-\(sharedID).jsonl")
        let newShardURL = dayDir.appendingPathComponent("rollout-2026-11-19T16-55-54-\(sharedID)_01a1f305-0289-79d0-8872-b9ec515f2fe4.jsonl")

        let now = Date()
        let oldDate = now.addingTimeInterval(-600)
        let newDate = now.addingTimeInterval(-30)
        let iso = ISO8601DateFormatter()

        let oldContent = """
        {"timestamp":"\(iso.string(from: oldDate))","type":"session_meta","payload":{"id":"\(sharedID)","cwd":"/tmp/proj","originator":"Codex Desktop","source":"vscode"}}
        {"timestamp":"\(iso.string(from: oldDate.addingTimeInterval(2)))","type":"event_msg","payload":{"type":"task_started"}}
        {"timestamp":"\(iso.string(from: oldDate.addingTimeInterval(3)))","type":"response_item","payload":{"type":"message","role":"user","content":"修复重复卡片显示问题"}}
        {"timestamp":"\(iso.string(from: oldDate.addingTimeInterval(15)))","type":"response_item","payload":{"type":"message","role":"assistant","content":"旧分片回复"}}
        {"timestamp":"\(iso.string(from: oldDate.addingTimeInterval(16)))","type":"event_msg","payload":{"type":"task_complete","duration_ms":1200}}
        {"timestamp":"\(iso.string(from: oldDate.addingTimeInterval(16)))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":57143,"cached_input_tokens":30907,"cache_write_input_tokens":0,"output_tokens":639,"reasoning_output_tokens":0,"total_tokens":57782}}}}
        """

        let newContent = """
        {"timestamp":"\(iso.string(from: newDate))","type":"session_meta","payload":{"id":"\(sharedID)","cwd":"/tmp/proj","originator":"Codex Desktop","source":"vscode"}}
        {"timestamp":"\(iso.string(from: newDate.addingTimeInterval(1)))","type":"event_msg","payload":{"type":"task_started"}}
        {"timestamp":"\(iso.string(from: newDate.addingTimeInterval(5)))","type":"response_item","payload":{"type":"function_call","call_id":"call_1","name":"exec_command","arguments":"{\\"cmd\\":\\"swift test\\"}"}}
        {"timestamp":"\(iso.string(from: newDate.addingTimeInterval(10)))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":655414,"cached_input_tokens":587574,"cache_write_input_tokens":0,"output_tokens":5681,"reasoning_output_tokens":0,"total_tokens":661095}}}}
        """

        try Data(oldContent.utf8).write(to: oldShardURL)
        try fm.setAttributes([.modificationDate: oldDate], ofItemAtPath: oldShardURL.path)
        try Data(newContent.utf8).write(to: newShardURL)
        try fm.setAttributes([.modificationDate: newDate], ofItemAtPath: newShardURL.path)

        let loaded = await CodexAdapter.loadLocalSessions(homeDirectory: tempHome.path, lookbackHours: 24)
        XCTAssertEqual(loaded.count, 1)

        let merged = try XCTUnwrap(loaded.first)
        XCTAssertEqual(merged.id, "local:codex:\(sharedID)")
        XCTAssertEqual(merged.title, "修复重复卡片显示问题")
        XCTAssertEqual(merged.status, .runningTool)
        XCTAssertEqual(merged.usage.totalTokens, 661_095)
        XCTAssertEqual(merged.turnCount, 2)

        // Idempotent second deduplication pass must not double-count turns or tokens.
        let idempotent = SessionDeduplicator.deduplicate([merged, merged])
        XCTAssertEqual(idempotent.count, 1)
        XCTAssertEqual(idempotent[0].usage.totalTokens, 661_095)
        XCTAssertEqual(idempotent[0].turnCount, 2)
    }

    func testClaudeSubagentFilteringAndDistinctIDs() async throws {
        let fm = FileManager.default
        let tempHome = fm.temporaryDirectory.appendingPathComponent("agentbar-test-claude-\(UUID().uuidString)")
        let projDir = tempHome.appendingPathComponent(".claude/projects/-tmp-demo")
        let parentID = "aaf3c0c8-c408-49a7-b1f8-a72548d312a0"
        let subDir = projDir.appendingPathComponent("\(parentID)/subagents")
        try fm.createDirectory(at: subDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempHome) }

        let now = Date()
        let iso = ISO8601DateFormatter()
        let parentURL = projDir.appendingPathComponent("\(parentID).jsonl")
        let subURL = subDir.appendingPathComponent("agent-a68596dca9c3560a7.jsonl")

        let parentJSONL = """
        {"type":"user","sessionId":"\(parentID)","isSidechain":false,"cwd":"/tmp/demo","timestamp":"\(iso.string(from: now.addingTimeInterval(-120)))","message":{"role":"user","content":"主会话任务"}}
        {"type":"assistant","sessionId":"\(parentID)","isSidechain":false,"cwd":"/tmp/demo","timestamp":"\(iso.string(from: now.addingTimeInterval(-90)))","message":{"id":"m1","model":"claude-sonnet-4-5","stop_reason":"end_turn","usage":{"input_tokens":1000,"output_tokens":200,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"content":[{"type":"text","text":"主会话已完成"}]}}
        """

        let subJSONL = """
        {"type":"user","sessionId":"\(parentID)","agentId":"a68596dca9c3560a7","isSidechain":true,"cwd":"/tmp/demo","timestamp":"\(iso.string(from: now.addingTimeInterval(-60)))","message":{"role":"user","content":"子代理检索任务"}}
        {"type":"assistant","sessionId":"\(parentID)","agentId":"a68596dca9c3560a7","isSidechain":true,"cwd":"/tmp/demo","timestamp":"\(iso.string(from: now.addingTimeInterval(-30)))","message":{"id":"m2","model":"claude-haiku-4-5","stop_reason":"end_turn","usage":{"input_tokens":500,"output_tokens":100,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"content":[{"type":"text","text":"子代理已完成"}]}}
        """

        try Data(parentJSONL.utf8).write(to: parentURL)
        try Data(subJSONL.utf8).write(to: subURL)

        let withoutSubagents = await ClaudeCodeAdapter.loadLocalSessions(
            homeDirectory: tempHome.path,
            lookbackHours: 24,
            includeSubagents: false
        )
        XCTAssertEqual(withoutSubagents.count, 1)
        XCTAssertEqual(withoutSubagents.first?.id, "local:claude:\(parentID)")

        let withSubagents = await ClaudeCodeAdapter.loadLocalSessions(
            homeDirectory: tempHome.path,
            lookbackHours: 24,
            includeSubagents: true
        )
        XCTAssertEqual(withSubagents.count, 2)
        let ids = Set(withSubagents.map(\.id))
        XCTAssertEqual(ids, [
            "local:claude:\(parentID)",
            "local:claude:\(parentID):a68596dca9c3560a7"
        ])
        // Both keep parent rawSessionID so `claude --resume` remains valid.
        XCTAssertTrue(withSubagents.allSatisfy { $0.rawSessionID == parentID })
    }

    func testSSHProbeAndGroupingAnalyticsDeduplicateDuplicateIDs() {
        let now = Date()
        let tsOld = Int(now.addingTimeInterval(-300).timeIntervalSince1970)
        let tsNew = Int(now.addingTimeInterval(-20).timeIntervalSince1970)
        let sharedID = "01a1f1d9-833d-75b3-8ba5-91a164e6cd19"

        let probeStdout = """
        @@HOME /home/dev
        @@BEGIN codex \(tsNew) /home/dev/.codex/sessions/rollout-new-\(sharedID)_shard2.jsonl
        {"timestamp":"2026-11-19T09:05:00Z","type":"session_meta","payload":{"id":"\(sharedID)","cwd":"/home/dev/app","originator":"codex_cli_rs"}}
        {"timestamp":"2026-11-19T09:05:05Z","type":"response_item","payload":{"type":"message","role":"assistant","content":"最新远程输出"}}
        {"timestamp":"2026-11-19T09:05:06Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":20000,"cached_input_tokens":5000,"cache_write_input_tokens":0,"output_tokens":1000,"reasoning_output_tokens":0,"total_tokens":21000}}}}
        @@END
        @@BEGIN codex \(tsOld) /home/dev/.codex/sessions/rollout-old-\(sharedID).jsonl
        {"timestamp":"2026-11-19T08:55:00Z","type":"session_meta","payload":{"id":"\(sharedID)","cwd":"/home/dev/app","originator":"codex_cli_rs"}}
        {"timestamp":"2026-11-19T08:55:01Z","type":"response_item","payload":{"type":"message","role":"user","content":"远程训练排查"}}
        {"timestamp":"2026-11-19T08:55:10Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":8000,"cached_input_tokens":1000,"cache_write_input_tokens":0,"output_tokens":300,"reasoning_output_tokens":0,"total_tokens":8300}}}}
        @@END
        """

        let host = HostID.ssh(alias: "gpu-box")
        let parsed = SSHProbeService.parseProbeOutput(stdout: probeStdout, host: host, lookbackHours: 168)
        XCTAssertEqual(parsed.sessions.count, 1)
        XCTAssertEqual(parsed.sessions[0].title, "远程训练排查")
        XCTAssertEqual(parsed.sessions[0].overview, "最新远程输出")
        XCTAssertEqual(parsed.sessions[0].usage.totalTokens, 21_000)

        // Even if duplicate AgentSession entries are fed into grouping or analytics, they are deduplicated.
        let duplicatedInput = [parsed.sessions[0], parsed.sessions[0]]
        let groups = SessionGroupingBuilder.buildHostGroups(
            sessions: duplicatedInput,
            hostStates: [host: HostConnectionState(host: host, isOnline: true)],
            homeByHost: [host: "/home/dev"]
        )
        XCTAssertEqual(groups.first?.totalSessionCount, 1)

        let analytics = SubscriptionAndStatsService.buildAnalytics(sessions: duplicatedInput, demoMode: true)
        XCTAssertEqual(analytics.allSessionCount, 1)
        XCTAssertEqual(analytics.allUsage.totalTokens, 21_000)
        XCTAssertEqual(analytics.todayUsage.totalTokens, 21_000)
    }

    func testLargeTruncatedCodexRolloutPreservesRunningAndCompletedStatus() async throws {
        let fm = FileManager.default
        let tempHome = fm.temporaryDirectory.appendingPathComponent("agentbar-test-codex-large-\(UUID().uuidString)")
        let codexDir = tempHome.appendingPathComponent(".codex")
        let dayDir = codexDir.appendingPathComponent("sessions/2026/11/20")
        try fm.createDirectory(at: dayDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempHome) }

        let sessionID = "01a1f828-0000-7000-8000-000000000001"
        let rolloutURL = dayDir.appendingPathComponent("rollout-2026-11-20T16-52-31-\(sessionID).jsonl")
        let indexURL = codexDir.appendingPathComponent("session_index.jsonl")
        let globalStateURL = codexDir.appendingPathComponent(".codex-global-state.json")

        let indexLine = """
        {"id":"\(sessionID)","thread_name":"大型工程重构长任务"}
        """
        try Data(indexLine.utf8).write(to: indexURL)

        let globalStateJSON = """
        {"electron-thread-read-state-v1":{"unreadByIdentity":{"user":{"local":[]}}}}
        """
        try Data(globalStateJSON.utf8).write(to: globalStateURL)

        let now = Date()
        let startTS = now.addingTimeInterval(-3600)
        let recentTS = now.addingTimeInterval(-5)
        let iso = ISO8601DateFormatter()

        var lines: [String] = [
            #"{"timestamp":"\#(iso.string(from: startTS))","type":"session_meta","payload":{"id":"\#(sessionID)","session_id":"\#(sessionID)","cwd":"/tmp/refactor-proj","originator":"Codex Desktop","source":"vscode","model_provider":"openai"}}"#,
            #"{"timestamp":"\#(iso.string(from: startTS.addingTimeInterval(1)))","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1","model_context_window":996147}}"#
        ]

        let fillerChunk = String(repeating: "x", count: 28_000) + #" \"type\":\"task_complete\" "#
        for idx in 0..<100 {
            let callID = "call_fill_\(idx)"
            let stepTS = iso.string(from: startTS.addingTimeInterval(Double(idx + 2)))
            lines.append(#"{"timestamp":"\#(stepTS)","type":"response_item","payload":{"type":"function_call","status":"completed","name":"exec_command","arguments":"{\"cmd\":\"echo test\"}","call_id":"\#(callID)"}}"#)
            lines.append(#"{"timestamp":"\#(stepTS)","type":"response_item","payload":{"type":"function_call_output","call_id":"\#(callID)","output":"\#(fillerChunk)"}}"#)
        }

        lines.append(#"{"timestamp":"\#(iso.string(from: recentTS.addingTimeInterval(-2)))","type":"compacted","payload":{"window_number":4,"resume_metadata":{"previous_turn_settings":{"model":"gpt-5.4"}}}}"#)
        lines.append(#"{"timestamp":"\#(iso.string(from: recentTS.addingTimeInterval(-1)))","type":"response_item","payload":{"type":"function_call","status":"completed","name":"exec_command","arguments":"{\"cmd\":\"swift test\"}","call_id":"call_tail"}}"#)
        lines.append(#"{"timestamp":"\#(iso.string(from: recentTS))","type":"response_item","payload":{"type":"function_call_output","call_id":"call_tail","output":"Process exited with code 0"}}"#)
        lines.append(#"{"timestamp":"\#(iso.string(from: recentTS))","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":36763978,"cached_input_tokens":34992247,"cache_write_input_tokens":0,"output_tokens":279532,"reasoning_output_tokens":0,"total_tokens":37043510},"last_token_usage":{"input_tokens":163811,"cached_input_tokens":159016,"output_tokens":101,"total_tokens":163912},"model_context_window":996147}}}"#)

        let activePayload = Data((lines.joined(separator: "\n") + "\n").utf8)
        XCTAssertGreaterThan(activePayload.count, 2_600_000)
        try activePayload.write(to: rolloutURL)
        try fm.setAttributes([.modificationDate: recentTS], ofItemAtPath: rolloutURL.path)

        let activeLoaded = await CodexAdapter.loadLocalSessions(homeDirectory: tempHome.path, lookbackHours: 24)
        let activeSession = try XCTUnwrap(activeLoaded.first)
        XCTAssertEqual(activeSession.status, .generating)
        XCTAssertEqual(activeSession.model, "gpt-5.4")
        XCTAssertEqual(activeSession.usage.totalTokens, 37_043_510)

        var finishedLines = lines
        finishedLines.append(#"{"timestamp":"\#(iso.string(from: now))","type":"response_item","payload":{"type":"message","role":"assistant","content":"重构已完成并通过全部测试。"}}"#)
        finishedLines.append(#"{"timestamp":"\#(iso.string(from: now))","type":"event_msg","payload":{"type":"task_complete","duration_ms":5000}}"#)
        try Data((finishedLines.joined(separator: "\n") + "\n").utf8).write(to: rolloutURL)
        try fm.setAttributes([.modificationDate: now], ofItemAtPath: rolloutURL.path)
        try fm.setAttributes([.modificationDate: now], ofItemAtPath: globalStateURL.path)

        let finishedLoaded = await CodexAdapter.loadLocalSessions(homeDirectory: tempHome.path, lookbackHours: 24)
        let finishedSession = try XCTUnwrap(finishedLoaded.first)
        XCTAssertEqual(finishedSession.status, .waitingForInput)
    }

    func testTruncatedSSHCodexSnippetInfersGeneratingWithoutTaskStarted() {
        let now = Date()
        let tsRecent = Int(now.addingTimeInterval(-8).timeIntervalSince1970)
        let iso = ISO8601DateFormatter()
        let sessionID = "01a1f828-0000-7000-8000-000000000002"

        let probeStdout = """
        @@HOME /home/dev
        @@BEGIN codex \(tsRecent) /home/dev/.codex/sessions/rollout-2026-11-20-\(sessionID).jsonl
        {"timestamp":"\(iso.string(from: now.addingTimeInterval(-1200)))","type":"session_meta","payload":{"id":"\(sessionID)","cwd":"/home/dev/repo","originator":"codex_cli_rs"}}
        {"timestamp":"\(iso.string(from: now.addingTimeInterval(-1199)))","type":"event_msg","payload":{"type":"task_started"}}
        {"timestamp":"\(iso.string(from: now.addingTimeInterval(-1198)))","type":"response_item","payload":{"type":"message","role":"user","content":"执行全量压测与重构"}}
        {"timestamp":"\(iso.string(from: now.addingTimeInterval(-1100)))","type":"event_msg","payload":{"type":"task_complete","duration_ms":1000}}
        {"timestamp":"\(iso.string(from: now.addingTimeInterval(-10)))","type":"response_item","payload":{"type":"reasoning"}}
        {"timestamp":"\(iso.string(from: now.addingTimeInterval(-8)))","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\\"cmd\\":\\"pytest\\"}","call_id":"c_ssh"}}
        {"timestamp":"\(iso.string(from: now.addingTimeInterval(-8)))","type":"response_item","payload":{"type":"function_call_output","call_id":"c_ssh","output":"passed"}}
        @@END
        """

        let parsed = SSHProbeService.parseProbeOutput(
            stdout: probeStdout,
            host: .ssh(alias: "gpu-box"),
            lookbackHours: 24
        )
        XCTAssertEqual(parsed.sessions.count, 1)
        XCTAssertEqual(parsed.sessions[0].status, .generating)
    }
}
