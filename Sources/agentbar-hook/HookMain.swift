import AgentBarCore
import Foundation

@main
struct AgentBarHookMain {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        let subcommand = args.first ?? "claude-event"
        let stdinData = FileHandle.standardInput.readDataToEndOfFile()
        let json = (try? JSONSerialization.jsonObject(with: stdinData)) as? [String: Any] ?? [:]

        switch subcommand {
        case "claude-permission":
            handleClaudePermission(json: json)
        case "self-test":
            Task {
                await runSelfTest(probeSSH: args.contains("--probe-ssh"))
                Foundation.exit(0)
            }
            RunLoop.main.run()
        default:
            let eventName = args.dropFirst().first ?? (json["hook_event_name"] as? String) ?? "event"
            recordEvent(tool: "claude-code", eventName: eventName, json: json)
        }
    }

    private static func runSelfTest(probeSSH: Bool = false) async {
        let jsonl = """
        {"type":"user","cwd":"/Users/test/repo","sessionId":"s-1","timestamp":"2026-11-19T04:00:00.000Z","message":{"role":"user","content":"帮我修 bug"}}
        {"type":"ai-title","aiTitle":"修复加载器崩溃","sessionId":"s-1"}
        {"type":"assistant","cwd":"/Users/test/repo","sessionId":"s-1","timestamp":"2026-11-19T04:00:05.000Z","message":{"id":"msg_1","model":"claude-opus-5-5","stop_reason":"tool_use","usage":{"input_tokens":1000,"output_tokens":50,"cache_read_input_tokens":4000,"cache_creation_input_tokens":200},"content":[{"type":"text","text":"我先看一下代码。"}]}}
        {"type":"assistant","cwd":"/Users/test/repo","sessionId":"s-1","timestamp":"2026-11-19T04:00:06.000Z","message":{"id":"msg_1","model":"claude-opus-5-5","stop_reason":"tool_use","usage":{"input_tokens":1000,"output_tokens":120,"cache_read_input_tokens":4000,"cache_creation_input_tokens":200},"content":[{"type":"tool_use","id":"tu_1","name":"Bash","input":{"command":"swift test"}}]}}
        {"type":"user","cwd":"/Users/test/repo","sessionId":"s-1","timestamp":"2026-11-19T04:00:10.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu_1","is_error":false}]}}
        {"type":"assistant","cwd":"/Users/test/repo","sessionId":"s-1","timestamp":"2026-11-19T04:00:14.000Z","message":{"id":"msg_2","model":"claude-opus-5-5","stop_reason":"end_turn","usage":{"input_tokens":1200,"output_tokens":200,"cache_read_input_tokens":5000,"cache_creation_input_tokens":0},"content":[{"type":"text","text":"### 修复完成\\n全部测试通过。"}]}}
        """
        guard let claude = ClaudeCodeAdapter.parseTranscript(
            jsonl: jsonl,
            fallbackSessionID: "s-1",
            filePath: "/tmp/s-1.jsonl",
            fileModificationDate: Date(),
            host: .local
        ) else {
            fputs("FAIL: claude parse nil\n", stderr)
            Foundation.exit(1)
        }
        precondition(claude.title == "修复加载器崩溃")
        precondition(claude.usage.input == 2200 && claude.usage.output == 320 && claude.usage.cacheRead == 9000)
        precondition(HookApprovalManager.matchedHighRiskRule(in: "rm -rf .build") == "rm -rf")

        // Regression tests for Issue #1: Codex multi-shard deduplication & Claude subagent IDs
        let sharedCodexID = "01a1f304-3559-7223-8f2a-f5fca907db41"
        let now = Date()
        let oldShard = CodexAdapter.parseRollout(
            jsonl: """
            {"timestamp":"2026-11-19T08:55:02Z","type":"session_meta","payload":{"id":"\(sharedCodexID)","cwd":"/tmp/proj","originator":"Codex Desktop","source":"vscode"}}
            {"timestamp":"2026-11-19T08:55:03Z","type":"event_msg","payload":{"type":"task_started"}}
            {"timestamp":"2026-11-19T08:55:04Z","type":"response_item","payload":{"type":"message","role":"user","content":"修复重复卡片与统计翻倍"}}
            {"timestamp":"2026-11-19T08:55:50Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":57143,"cached_input_tokens":30907,"cache_write_input_tokens":0,"output_tokens":639,"reasoning_output_tokens":0,"total_tokens":57782}}}}
            """,
            filePath: "/tmp/rollout-old-\(sharedCodexID).jsonl",
            fileModificationDate: now.addingTimeInterval(-600),
            host: .local
        )!
        let newShard = CodexAdapter.parseRollout(
            jsonl: """
            {"timestamp":"2026-11-19T08:55:54Z","type":"session_meta","payload":{"id":"\(sharedCodexID)","cwd":"/tmp/proj","originator":"Codex Desktop","source":"vscode"}}
            {"timestamp":"2026-11-19T08:55:55Z","type":"event_msg","payload":{"type":"task_started"}}
            {"timestamp":"2026-11-19T09:05:36Z","type":"response_item","payload":{"type":"message","role":"assistant","content":"已完成去重修复"}}
            {"timestamp":"2026-11-19T09:05:36Z","type":"event_msg","payload":{"type":"task_complete","duration_ms":1000}}
            {"timestamp":"2026-11-19T09:05:36Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":655414,"cached_input_tokens":587574,"cache_write_input_tokens":0,"output_tokens":5681,"reasoning_output_tokens":0,"total_tokens":661095}}}}
            """,
            filePath: "/tmp/rollout-new-\(sharedCodexID)_shard2.jsonl",
            fileModificationDate: now.addingTimeInterval(-20),
            host: .local
        )!
        let mergedCodex = SessionDeduplicator.deduplicate([oldShard, newShard])
        precondition(mergedCodex.count == 1)
        precondition(mergedCodex[0].title == "修复重复卡片与统计翻倍")
        precondition(mergedCodex[0].overview == "已完成去重修复")
        precondition(mergedCodex[0].usage.totalTokens == 661_095)
        precondition(mergedCodex[0].turnCount == 2)
        precondition(SessionDeduplicator.deduplicate([mergedCodex[0], mergedCodex[0]])[0].turnCount == 2)

        let subJSONL = """
        {"type":"user","sessionId":"s-1","agentId":"a68596","isSidechain":true,"cwd":"/Users/test/repo","timestamp":"2026-11-19T04:10:00Z","message":{"role":"user","content":"子代理任务"}}
        """
        precondition(ClaudeCodeAdapter.parseTranscript(
            jsonl: subJSONL,
            fallbackSessionID: "agent-a68596",
            filePath: "/Users/test/.claude/projects/p/s-1/subagents/agent-a68596.jsonl",
            fileModificationDate: now,
            host: .local,
            includeSubagents: false
        ) == nil)
        let parsedSub = ClaudeCodeAdapter.parseTranscript(
            jsonl: subJSONL,
            fallbackSessionID: "agent-a68596",
            filePath: "/Users/test/.claude/projects/p/s-1/subagents/agent-a68596.jsonl",
            fileModificationDate: now,
            host: .local,
            includeSubagents: true
        )!
        precondition(parsedSub.id == "local:claude:s-1:a68596" && parsedSub.rawSessionID == "s-1")

        let realClaude = await ClaudeCodeAdapter.loadLocalSessions(lookbackHours: 168)
        let realCodex = await CodexAdapter.loadLocalSessions(lookbackHours: 168)
        let realDSH = await DeepSeekHarnessAdapter.loadLocalSessions(lookbackHours: 168)
        let realCursor = await CursorTraeAdapter.loadLocalSessions(lookbackHours: 168)
        let combinedReal = realClaude + realCodex + realDSH + realCursor
        precondition(Set(combinedReal.map(\.id)).count == combinedReal.count, "Duplicate session IDs detected!")
        let sshEntries = SSHProbeService.discoverSSHConfigEntries()
        print("PASS self-test | local sessions -> claude=\(realClaude.count), codex=\(realCodex.count), dsh=\(realDSH.count), cursor=\(realCursor.count), ssh_hosts=\(sshEntries.count)")
        if probeSSH {
            await withTaskGroup(of: (Int, SSHProbeResult).self) { group in
                for (idx, cfg) in sshEntries.enumerated() {
                    group.addTask {
                        let res = await SSHProbeService.probeHost(alias: cfg.alias, lookbackHours: 168)
                        return (idx, res)
                    }
                }
                for await (idx, res) in group {
                    let claudeCount = res.sessions.filter { $0.kind == .claudeCode }.count
                    let runningCount = res.sessions.filter { StatusCategoryFilter.running.matches($0) }.count
                    print("SSH host #\(idx): online=\(res.connection.isOnline), latency=\(res.connection.latencyMs ?? -1)ms, sessions=\(res.sessions.count) (claude=\(claudeCount), running=\(runningCount)), err=\(res.connection.errorMessage ?? "none")")
                }
            }
        }
    }

    private static func handleClaudePermission(json: [String: Any]) {
        HookApprovalManager.ensureDirectories()
        let requestID = UUID().uuidString
        let sessionID = json["session_id"] as? String
        let cwd = json["cwd"] as? String
        let toolName = (json["tool_name"] as? String) ?? "Tool"
        let toolInput = json["tool_input"]
        let summary = ClaudeCodeAdapter.summarizeToolInput(name: toolName, input: toolInput)

        let pending = PendingApproval(
            requestID: requestID,
            sessionID: sessionID,
            host: .local,
            toolName: toolName,
            commandOrSummary: summary,
            cwd: cwd,
            requestedAt: Date(),
            canRespondViaHook: true,
            highRiskMatchedRule: HookApprovalManager.matchedHighRiskRule(in: summary)
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let pendingURL = HookApprovalManager.pendingDirectory.appendingPathComponent("\(requestID).json")
        let decisionURL = HookApprovalManager.decisionsDirectory.appendingPathComponent("\(requestID).json")
        defer {
            try? FileManager.default.removeItem(at: pendingURL)
            try? FileManager.default.removeItem(at: decisionURL)
        }

        guard let data = try? encoder.encode(pending),
              (try? data.write(to: pendingURL, options: .atomic)) != nil else {
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let deadline = Date().addingTimeInterval(120)

        while Date() < deadline {
            if let decisionData = try? Data(contentsOf: decisionURL),
               let decision = try? decoder.decode(ApprovalDecisionPayload.self, from: decisionData) {
                switch decision.action {
                case .allow:
                    let response: [String: Any] = [
                        "hookSpecificOutput": [
                            "hookEventName": "PermissionRequest",
                            "decision": [
                                "behavior": "allow"
                            ]
                        ]
                    ]
                    writeJSONStdout(response)
                case .deny:
                    let response: [String: Any] = [
                        "hookSpecificOutput": [
                            "hookEventName": "PermissionRequest",
                            "decision": [
                                "behavior": "deny",
                                "message": decision.reason ?? "由 AgentBar 拒绝执行"
                            ]
                        ]
                    ]
                    writeJSONStdout(response)
                case .passthrough:
                    // Print nothing -> Claude Code falls back to terminal prompt
                    break
                }
                return
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    private static func recordEvent(tool: String, eventName: String, json: [String: Any]) {
        HookApprovalManager.ensureDirectories()
        let record: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: Date()),
            "tool": tool,
            "event": eventName,
            "session": (json["session_id"] as? String) ?? "",
            "cwd": (json["cwd"] as? String) ?? ""
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: record),
              var line = String(data: data, encoding: .utf8) else {
            return
        }
        line.append("\n")
        let url = HookApprovalManager.eventsFileURL
        if FileManager.default.fileExists(atPath: url.path),
           let h = try? FileHandle(forWritingTo: url) {
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: Data(line.utf8))
            try? h.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    private static func writeJSONStdout(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
