import Foundation

public struct CodexReadState: Sendable {
    public var hasReadState: Bool
    public var unreadThreadIDs: Set<String>
    public var userActivityAtByThreadID: [String: TimeInterval]
    public var stateFileUpdatedAt: Date?

    public init(
        hasReadState: Bool = false,
        unreadThreadIDs: Set<String> = [],
        userActivityAtByThreadID: [String: TimeInterval] = [:],
        stateFileUpdatedAt: Date? = nil
    ) {
        self.hasReadState = hasReadState
        self.unreadThreadIDs = unreadThreadIDs
        self.userActivityAtByThreadID = userActivityAtByThreadID
        self.stateFileUpdatedAt = stateFileUpdatedAt
    }
}

public enum CodexAdapter {
    public static func loadReadState(homeDirectory: String = NSHomeDirectory()) -> CodexReadState {
        let path = (homeDirectory as NSString).appendingPathComponent(".codex/.codex-global-state.json")
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return CodexReadState()
        }
        let mtime = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate

        var hasReadState = false
        var unreadIDs: Set<String> = []
        if let readState = root["electron-thread-read-state-v1"] as? [String: Any],
           let unreadByIdentity = readState["unreadByIdentity"] as? [String: Any] {
            hasReadState = true
            for (_, hostDictAny) in unreadByIdentity {
                guard let hostDict = hostDictAny as? [String: Any] else { continue }
                for (_, arrAny) in hostDict {
                    guard let arr = arrAny as? [String] else { continue }
                    unreadIDs.formUnion(arr)
                }
            }
        }

        var activityByThread: [String: TimeInterval] = [:]
        for (key, val) in root where key.hasPrefix("electron-owner-atoms:") {
            guard let atoms = val as? [String: Any],
                  let activityMap = atoms["thread-user-activity-times-v1"] as? [String: Any] else {
                continue
            }
            for (tupleJSON, rawTS) in activityMap {
                let numVal: Double?
                if let d = rawTS as? Double {
                    numVal = d
                } else if let i = rawTS as? Int {
                    numVal = Double(i)
                } else if let n = rawTS as? NSNumber {
                    numVal = n.doubleValue
                } else {
                    numVal = nil
                }
                guard let raw = numVal, raw > 0 else { continue }
                let sec = raw > 10_000_000_000 ? (raw / 1000.0) : raw
                if let keyData = tupleJSON.data(using: .utf8),
                   let tuple = try? JSONSerialization.jsonObject(with: keyData) as? [Any],
                   tuple.count >= 2,
                   let threadID = tuple[1] as? String,
                   !threadID.isEmpty {
                    activityByThread[threadID] = max(activityByThread[threadID] ?? 0, sec)
                }
            }
        }

        return CodexReadState(
            hasReadState: hasReadState,
            unreadThreadIDs: unreadIDs,
            userActivityAtByThreadID: activityByThread,
            stateFileUpdatedAt: mtime
        )
    }

    public static func loadThreadIndex(homeDirectory: String = NSHomeDirectory()) -> [String: String] {
        let path = (homeDirectory as NSString).appendingPathComponent(".codex/session_index.jsonl")
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        var map: [String: String] = [:]
        for line in content.split(whereSeparator: \.isNewline) {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = obj["id"] as? String,
                  let name = obj["thread_name"] as? String,
                  !name.isEmpty else {
                continue
            }
            map[id] = cleanThreadTitle(name)
        }
        return map
    }

    public static func cleanThreadTitle(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix("*") || s.hasPrefix("#") {
            s.removeFirst()
            s = s.trimmingCharacters(in: .whitespaces)
        }
        if s.hasSuffix("**") {
            s = String(s.dropLast(2)).trimmingCharacters(in: .whitespaces)
        }
        return s.isEmpty ? raw : s
    }

    public static func detectDefaultProvider(homeDirectory: String = NSHomeDirectory()) -> String {
        let path = (homeDirectory as NSString).appendingPathComponent(".codex/config.toml")
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return "OpenAI"
        }
        for line in content.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("model_provider") && trimmed.contains("=") {
                let rhs = trimmed.split(separator: "=", maxSplits: 1).last?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if let rhs, !rhs.isEmpty {
                    return FormattingHelpers.providerDisplay(from: rhs) ?? rhs
                }
            }
        }
        return "OpenAI"
    }

    public static func loadLocalSessions(
        homeDirectory: String = NSHomeDirectory(),
        lookbackHours: Double = 72,
        includeSubagents: Bool = false,
        seenAtByID: [String: TimeInterval] = [:]
    ) async -> [AgentSession] {
        let sessionsRoot = (homeDirectory as NSString).appendingPathComponent(".codex/sessions")
        let indexMap = loadThreadIndex(homeDirectory: homeDirectory)
        let readState = loadReadState(homeDirectory: homeDirectory)
        let defaultProvider = detectDefaultProvider(homeDirectory: homeDirectory)
        let cutoff = Date().addingTimeInterval(-lookbackHours * 3600)
        let candidates = ClaudeCodeAdapter.collectRecentJSONLFiles(rootPath: sessionsRoot, cutoff: cutoff)

        let maxUniqueSessions = 35
        let maxCandidateScan = 250
        var parsedSessions: [AgentSession] = []
        var acceptedIDs: Set<String> = []

        for item in candidates.prefix(maxCandidateScan) {
            guard let content = readTailUTF8(url: item.url, maxBytes: 2_500_000) else { continue }
            if var session = parseRollout(
                jsonl: content,
                filePath: item.url.path,
                fileModificationDate: item.mtime,
                host: .local,
                threadTitles: indexMap,
                defaultProvider: defaultProvider,
                includeSubagents: includeSubagents,
                readState: readState,
                seenAtByID: seenAtByID
            ) {
                if !acceptedIDs.contains(session.id) {
                    guard acceptedIDs.count < maxUniqueSessions else { continue }
                    acceptedIDs.insert(session.id)
                }
                session.groupDirectory = await GitRootResolver.shared.resolveGroupDirectory(for: session.cwd)
                parsedSessions.append(session)
            }
        }
        return SessionDeduplicator.deduplicate(parsedSessions)
    }

    private static func readTailUTF8(url: URL, maxBytes: Int) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        if data.count <= maxBytes {
            return String(data: data, encoding: .utf8)
        }
        let newline: UInt8 = 0x0A
        let firstNewline = data.firstIndex(of: newline) ?? data.endIndex
        let firstLine = String(decoding: data[data.startIndex..<firstNewline], as: UTF8.self)
        let afterFirstLine = firstNewline < data.endIndex ? data.index(after: firstNewline) : data.endIndex

        let rawTailStart = max(afterFirstLine, data.count - maxBytes)
        let tailLineStart: Int
        if let nlInTail = data[rawTailStart..<data.endIndex].firstIndex(of: newline) {
            tailLineStart = data.index(after: nlInTail)
        } else {
            tailLineStart = data.endIndex
        }

        var segments: [String] = [firstLine]
        if afterFirstLine < tailLineStart,
           let lifecycleLine = latestLifecycleEventLine(in: data, range: afterFirstLine..<tailLineStart) {
            segments.append(lifecycleLine)
        }
        if tailLineStart < data.endIndex {
            segments.append(String(decoding: data[tailLineStart..<data.endIndex], as: UTF8.self))
        }
        return segments.joined(separator: "\n")
    }

    private static let lifecycleNeedles: [Data] = [
        Data("\"task_started\"".utf8),
        Data("\"task_complete\"".utf8),
        Data("\"turn_aborted\"".utf8),
        Data("\"type\":\"error\"".utf8)
    ]

    private static let lifecycleEventTypes: Set<String> = [
        "task_started",
        "task_complete",
        "turn_aborted",
        "error"
    ]

    private static func latestLifecycleEventLine(in data: Data, range: Range<Int>) -> String? {
        let newline: UInt8 = 0x0A
        var bestStart = -1
        var bestLine: String?

        for needle in lifecycleNeedles {
            var searchUpper = range.upperBound
            var attempts = 0
            while searchUpper > range.lowerBound && attempts < 12 {
                attempts += 1
                guard let hit = data.range(of: needle, options: .backwards, in: range.lowerBound..<searchUpper) else {
                    break
                }
                let lineStart: Int
                if let prevNL = data[range.lowerBound..<hit.lowerBound].lastIndex(of: newline) {
                    lineStart = prevNL + 1
                } else {
                    lineStart = range.lowerBound
                }
                if lineStart <= bestStart {
                    break
                }
                let lineEnd = data[hit.upperBound..<range.upperBound].firstIndex(of: newline) ?? range.upperBound
                let lineData = data[lineStart..<lineEnd]
                if let obj = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any],
                   (obj["type"] as? String) == "event_msg",
                   let payload = obj["payload"] as? [String: Any],
                   let ptype = payload["type"] as? String,
                   lifecycleEventTypes.contains(ptype) {
                    bestStart = lineStart
                    bestLine = String(decoding: lineData, as: UTF8.self)
                    break
                }
                searchUpper = lineStart > range.lowerBound ? (lineStart - 1) : range.lowerBound
            }
        }
        return bestLine
    }

    public static func parseRollout(
        jsonl: String,
        filePath: String?,
        fileModificationDate: Date,
        host: HostID,
        threadTitles: [String: String] = [:],
        defaultProvider: String = "OpenAI",
        includeSubagents: Bool = false,
        readState: CodexReadState = CodexReadState(),
        seenAtByID: [String: TimeInterval] = [:]
    ) -> AgentSession? {
        var rawID = URL(fileURLWithPath: filePath ?? "codex").deletingPathExtension().lastPathComponent
        if let uuidRange = rawID.range(
            of: #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#,
            options: .regularExpression
        ) {
            rawID = String(rawID[uuidRange])
        }
        var kind: AgentKind = .codexCLI
        var launchEnv: SessionLaunchEnvironment = .terminalCLI
        var cwd: String?
        var provider = defaultProvider
        var model: String?
        var reasoningEffort: String?
        var usage = TokenUsage()
        var contextUsed: Int?
        var contextWindow: Int?
        var firstUserMessage: String?
        var lastAssistantMessage: String?
        var openTools: [String: ToolCallRecord] = [:]
        var openToolOrder: [String] = []
        var completedTools: [ToolCallRecord] = []
        var totalTools = 0
        var failedTools = 0
        var turnOpen = false
        var turnCount = 0
        var compactCount = 0
        var lastDurationMs: Double?
        var lastTurnOutputTokens: Int?
        var errorBanner: String?
        var startedAt: Date?
        var lastActivityAt = fileModificationDate

        func markInTurnActivity() {
            if !turnOpen {
                turnOpen = true
                errorBanner = nil
            }
        }

        for lineSub in jsonl.split(whereSeparator: \.isNewline) {
            guard let data = lineSub.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            let ts = ClaudeCodeAdapter.parseISODate(obj["timestamp"] as? String)
            if let ts {
                if startedAt == nil { startedAt = ts }
                if ts > lastActivityAt { lastActivityAt = ts }
            }
            let type = (obj["type"] as? String) ?? ""
            let payload = obj["payload"] as? [String: Any]

            switch type {
            case "session_meta":
                guard let payload else { continue }
                if !includeSubagents, let sourceObj = payload["source"] as? [String: Any], sourceObj["subagent"] != nil {
                    return nil
                }
                if let id = payload["id"] as? String, !id.isEmpty {
                    rawID = id
                }
                if let sid = payload["session_id"] as? String, !sid.isEmpty {
                    rawID = sid
                }
                if let dir = payload["cwd"] as? String, !dir.isEmpty {
                    cwd = dir
                }
                if let mp = payload["model_provider"] as? String, !mp.isEmpty {
                    provider = FormattingHelpers.providerDisplay(from: mp) ?? mp
                }
                if let cw = payload["context_window"] as? Int, cw > 0 {
                    contextWindow = cw
                }
                let originator = (payload["originator"] as? String) ?? ""
                let sourceStr = (payload["source"] as? String) ?? ""
                if originator.localizedCaseInsensitiveContains("desktop") {
                    kind = .codexDesktop
                    launchEnv = host.isLocal ? .codexApp : .vscodeExtension
                } else if originator.localizedCaseInsensitiveContains("cursor") {
                    kind = .codexDesktop
                    launchEnv = .cursorExtension
                } else if originator.localizedCaseInsensitiveContains("vscode") || sourceStr == "vscode" {
                    kind = .codexDesktop
                    launchEnv = .vscodeExtension
                } else {
                    kind = .codexCLI
                    launchEnv = .terminalCLI
                }

            case "turn_context":
                markInTurnActivity()
                guard let payload else { continue }
                if let dir = payload["cwd"] as? String, !dir.isEmpty {
                    cwd = dir
                }
                if let m = payload["model"] as? String, !m.isEmpty {
                    model = m
                }
                if let eff = payload["effort"] as? String, !eff.isEmpty {
                    reasoningEffort = eff
                }

            case "compacted":
                markInTurnActivity()
                compactCount += 1
                if model == nil,
                   let resumeMeta = payload?["resume_metadata"] as? [String: Any],
                   let prevSettings = resumeMeta["previous_turn_settings"] as? [String: Any],
                   let m = prevSettings["model"] as? String,
                   !m.isEmpty {
                    model = m
                }

            case "event_msg":
                guard let payload else { continue }
                let ptype = (payload["type"] as? String) ?? ""
                switch ptype {
                case "thread_settings_applied":
                    if let settings = payload["thread_settings"] as? [String: Any] {
                        if let m = settings["model"] as? String, !m.isEmpty { model = m }
                        if let mp = settings["model_provider_id"] as? String, !mp.isEmpty {
                            provider = FormattingHelpers.providerDisplay(from: mp) ?? mp
                        }
                        if let eff = settings["reasoning_effort"] as? String, !eff.isEmpty {
                            reasoningEffort = eff
                        }
                        if let dir = settings["cwd"] as? String, !dir.isEmpty {
                            cwd = dir
                        }
                    }
                case "task_started":
                    turnOpen = true
                    turnCount += 1
                    errorBanner = nil
                    if let cw = payload["model_context_window"] as? Int, cw > 0 {
                        contextWindow = cw
                    }
                case "task_complete":
                    turnOpen = false
                    openTools.removeAll()
                    openToolOrder.removeAll()
                    if let dur = payload["duration_ms"] as? Double, dur > 0 {
                        lastDurationMs = dur
                    } else if let durInt = payload["duration_ms"] as? Int, durInt > 0 {
                        lastDurationMs = Double(durInt)
                    }
                    if let msg = payload["last_agent_message"] as? String,
                       !msg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        lastAssistantMessage = msg.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                case "token_count":
                    if let info = payload["info"] as? [String: Any] {
                        if let cw = info["model_context_window"] as? Int, cw > 0 {
                            contextWindow = cw
                        }
                        if let total = info["total_token_usage"] as? [String: Any] {
                            let rawInput = (total["input_tokens"] as? Int) ?? 0
                            let cached = (total["cached_input_tokens"] as? Int) ?? 0
                            let cacheWrite = (total["cache_write_input_tokens"] as? Int) ?? 0
                            let output = (total["output_tokens"] as? Int) ?? 0
                            let reasoning = (total["reasoning_output_tokens"] as? Int) ?? 0
                            usage = TokenUsage(
                                input: max(0, rawInput - cached),
                                output: output,
                                cacheRead: cached,
                                cacheWrite: cacheWrite,
                                reasoning: reasoning
                            )
                        }
                        if let last = info["last_token_usage"] as? [String: Any] {
                            let lastIn = (last["input_tokens"] as? Int) ?? 0
                            if lastIn > 0 {
                                contextUsed = lastIn
                            }
                            lastTurnOutputTokens = (last["output_tokens"] as? Int)
                        }
                    }
                case "context_compacted":
                    markInTurnActivity()
                    compactCount += 1
                case "error", "turn_aborted":
                    turnOpen = false
                    openTools.removeAll()
                    openToolOrder.removeAll()
                    if let message = payload["message"] as? String, !message.isEmpty {
                        errorBanner = ClaudeCodeAdapter.firstSingleLine(message, maxLength: 140)
                    }
                default:
                    break
                }

            case "response_item":
                guard let payload else { continue }
                let rtype = (payload["type"] as? String) ?? ""
                switch rtype {
                case "reasoning":
                    markInTurnActivity()
                case "function_call", "custom_tool_call":
                    markInTurnActivity()
                    let callID = (payload["call_id"] as? String) ?? UUID().uuidString
                    let name = (payload["name"] as? String) ?? "tool"
                    let args = payload["arguments"] ?? payload["input"]
                    let summary = ClaudeCodeAdapter.summarizeToolInput(name: name, input: args)
                    let record = ToolCallRecord(
                        id: callID,
                        name: name,
                        summary: summary,
                        startedAt: ts ?? lastActivityAt
                    )
                    openTools[callID] = record
                    openToolOrder.append(callID)
                    totalTools += 1
                case "function_call_output", "custom_tool_call_output":
                    markInTurnActivity()
                    let callID = (payload["call_id"] as? String) ?? ""
                    let outStr = (payload["output"] as? String) ?? ""
                    let isErr = outStr.contains("Process exited with code 1")
                        || outStr.contains("Exit code: 1")
                        || outStr.contains("error:")
                    if isErr { failedTools += 1 }
                    if var record = openTools.removeValue(forKey: callID) {
                        openToolOrder.removeAll { $0 == callID }
                        record.finishedAt = ts ?? lastActivityAt
                        record.isError = isErr
                        completedTools.append(record)
                    }
                case "message":
                    let role = (payload["role"] as? String) ?? ""
                    let text = extractCodexMessageText(content: payload["content"])
                    if role == "user", !text.isEmpty {
                        let cleaned = cleanCodexUserText(text)
                        if !cleaned.isEmpty && firstUserMessage == nil {
                            firstUserMessage = cleaned
                        }
                    } else if role == "assistant", !text.isEmpty {
                        lastAssistantMessage = text
                    }
                default:
                    break
                }
            default:
                break
            }
        }

        let hasRealActivity = turnOpen
            || !openTools.isEmpty
            || totalTools > 0
            || lastAssistantMessage != nil
            || usage.totalTokens > 0

        let title = threadTitles[rawID]
            ?? firstUserMessage.map { ClaudeCodeAdapter.firstSingleLine($0, maxLength: 44) }
            ?? (hasRealActivity ? cwd.map { "\(URL(fileURLWithPath: $0).lastPathComponent) 会话" } : nil)
            ?? (hasRealActivity ? "Codex 会话" : nil)

        guard let title, !title.isEmpty else {
            return nil
        }

        var tokPerSec: Double?
        if let durMs = lastDurationMs, durMs > 200, let outTok = lastTurnOutputTokens, outTok > 0 {
            tokPerSec = Double(outTok) / (durMs / 1000.0)
        }

        let currentTool = openToolOrder.last.flatMap { openTools[$0] }
        var recent = completedTools
        if let currentTool { recent.append(currentTool) }
        let recentTail = Array(recent.suffix(5).reversed())

        let sessionID = "\(host.storageKey):codex:\(rawID)"
        let age = Date().timeIntervalSince(lastActivityAt)
        let seenInAgentBar = SeenSessionLookup.isSeen(
            sessionID: sessionID,
            lastActivityAt: lastActivityAt,
            seenAtByID: seenAtByID
        )
        let isCodexAppLocal = host.isLocal && (kind == .codexDesktop || launchEnv == .codexApp)
        let seenByActivityTime = isCodexAppLocal
            && (readState.userActivityAtByThreadID[rawID].map { $0 + 2.0 >= lastActivityAt.timeIntervalSince1970 } ?? false)
        let stateFileSettled: Bool = {
            if age >= 3.0 { return true }
            guard let stateMtime = readState.stateFileUpdatedAt else { return false }
            return stateMtime.timeIntervalSince(lastActivityAt) >= -1.5
        }()
        let seenByNativeUnread = isCodexAppLocal
            && readState.hasReadState
            && stateFileSettled
            && !readState.unreadThreadIDs.contains(rawID)
        let isSeen = seenInAgentBar || seenByActivityTime || seenByNativeUnread

        let status: SessionStatus
        if errorBanner != nil && age < 7200 {
            status = .failed
        } else if currentTool != nil && age < 900 {
            status = .runningTool
        } else if turnOpen && age < 600 {
            status = .generating
        } else if !isSeen && age < 1800 && lastAssistantMessage != nil {
            status = .completed
        } else {
            status = .waitingForInput
        }

        let overview: String
        if let err = errorBanner {
            overview = err
        } else if let tool = currentTool {
            overview = "\(tool.name)：\(tool.summary)"
        } else if let msg = lastAssistantMessage {
            overview = ClaudeCodeAdapter.firstSingleLine(msg, maxLength: 80)
        } else if let prompt = firstUserMessage {
            overview = ClaudeCodeAdapter.firstSingleLine(prompt, maxLength: 80)
        } else {
            overview = "等待你的下一条消息"
        }

        return AgentSession(
            id: sessionID,
            rawSessionID: rawID,
            kind: kind,
            host: host,
            title: title,
            overview: overview,
            status: status,
            cwd: cwd,
            groupDirectory: cwd,
            provider: provider,
            model: model,
            reasoningEffort: reasoningEffort,
            usage: usage,
            contextUsedTokens: contextUsed,
            contextWindow: contextWindow ?? PricingCatalog.defaultContextWindow(for: model),
            currentTool: currentTool,
            recentTools: recentTail,
            totalToolCalls: totalTools,
            successfulToolCalls: max(0, totalTools - failedTools),
            turnCount: max(1, turnCount),
            compactCount: compactCount,
            outputTokensPerSecond: tokPerSec,
            lastOutputMarkdown: lastAssistantMessage,
            errorBanner: errorBanner,
            sourceFilePath: filePath,
            launchEnvironment: launchEnv,
            startedAt: startedAt ?? fileModificationDate,
            lastActivityAt: lastActivityAt,
            isSeen: isSeen
        )
    }

    private static func extractCodexMessageText(content: Any?) -> String {
        if let str = content as? String {
            return str.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let arr = content as? [[String: Any]] else { return "" }
        var parts: [String] = []
        for item in arr {
            let t = (item["type"] as? String) ?? ""
            if (t == "input_text" || t == "output_text" || t == "text"),
               let s = item["text"] as? String {
                parts.append(s)
            }
        }
        return parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanCodexUserText(_ raw: String) -> String {
        var s = raw
        if let endEnv = s.range(of: "</environment_context>") {
            s = String(s[endEnv.upperBound...])
        }
        if let reqRange = s.range(of: "## My request:") {
            s = String(s[reqRange.upperBound...])
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("<") && s.contains("</") && s.count < 80 {
            return ""
        }
        return s
    }
}
