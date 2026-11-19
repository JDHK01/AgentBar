import Foundation

public enum ClaudeCodeAdapter {
    private static let fractionalISOStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let basicISOStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: false)

    public static func parseISODate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        return (try? fractionalISOStyle.parse(raw)) ?? (try? basicISOStyle.parse(raw))
    }

    public static func detectLocalProvider(homeDirectory: String = NSHomeDirectory()) -> String {
        let path = (homeDirectory as NSString).appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let env = obj["env"] as? [String: Any] else {
            return "Anthropic"
        }
        if env["CLAUDE_CODE_USE_BEDROCK"] != nil {
            return "AWS Bedrock"
        }
        if env["CLAUDE_CODE_USE_VERTEX"] != nil {
            return "Vertex AI"
        }
        if let baseURL = env["ANTHROPIC_BASE_URL"] as? String,
           let host = URL(string: baseURL)?.host {
            return FormattingHelpers.providerDisplay(from: host) ?? host
        }
        return "Anthropic"
    }

    public static func loadLocalSessions(
        homeDirectory: String = NSHomeDirectory(),
        lookbackHours: Double = 72,
        seenSessionIDs: Set<String> = []
    ) async -> [AgentSession] {
        let rootPath = (homeDirectory as NSString).appendingPathComponent(".claude/projects")
        let provider = detectLocalProvider(homeDirectory: homeDirectory)
        let cutoff = Date().addingTimeInterval(-lookbackHours * 3600)
        let candidates = collectRecentJSONLFiles(rootPath: rootPath, cutoff: cutoff)

        var results: [AgentSession] = []
        for item in candidates.prefix(35) {
            guard let content = try? String(contentsOf: item.url, encoding: .utf8) else { continue }
            let rawID = item.url.deletingPathExtension().lastPathComponent
            if var session = parseTranscript(
                jsonl: content,
                fallbackSessionID: rawID,
                filePath: item.url.path,
                fileModificationDate: item.mtime,
                host: .local,
                defaultProvider: provider,
                seenSessionIDs: seenSessionIDs
            ) {
                session.groupDirectory = await GitRootResolver.shared.resolveGroupDirectory(for: session.cwd)
                results.append(session)
            }
        }
        return results
    }

    public static func collectRecentJSONLFiles(rootPath: String, cutoff: Date) -> [(url: URL, mtime: Date)] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: rootPath),
              let enumerator = fm.enumerator(
                  at: URL(fileURLWithPath: rootPath),
                  includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                  options: [.skipsHiddenFiles]
              ) else {
            return []
        }
        var candidates: [(url: URL, mtime: Date)] = []
        while let obj = enumerator.nextObject() {
            guard let url = obj as? URL, url.pathExtension == "jsonl" else { continue }
            let vals = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            guard vals?.isRegularFile == true else { continue }
            let mtime = vals?.contentModificationDate ?? .distantPast
            if mtime >= cutoff {
                candidates.append((url, mtime))
            }
        }
        candidates.sort { $0.mtime > $1.mtime }
        return candidates
    }

    public static func parseTranscript(
        jsonl: String,
        fallbackSessionID: String,
        filePath: String?,
        fileModificationDate: Date,
        host: HostID,
        defaultProvider: String = "Anthropic",
        seenSessionIDs: Set<String> = []
    ) -> AgentSession? {
        var rawSessionID = fallbackSessionID
        var aiTitle: String?
        var customTitle: String?
        var firstUserPrompt: String?
        var lastUserPrompt: String?
        var cwd: String?
        var model: String?
        var usageByMessageID: [String: TokenUsage] = [:]
        var anonymousUsage = TokenUsage()
        var lastPromptTokens: Int?
        var openTools: [String: ToolCallRecord] = [:]
        var openToolOrder: [String] = []
        var completedTools: [ToolCallRecord] = []
        var totalToolCalls = 0
        var failedToolCalls = 0
        var turnCount = 0
        var compactCount = 0
        var lastAssistantText: String?
        var lastStopReason: String?
        var lastEventKind = ""
        var errorBanner: String?
        var startedAt: Date?
        var lastActivityAt = fileModificationDate

        for lineSub in jsonl.split(whereSeparator: \.isNewline) {
            guard let data = lineSub.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            if let sid = obj["sessionId"] as? String, !sid.isEmpty {
                rawSessionID = sid
            }
            if let dir = obj["cwd"] as? String, !dir.isEmpty {
                cwd = dir
            }
            let eventDate = parseISODate(obj["timestamp"] as? String)
            if let eventDate {
                if startedAt == nil { startedAt = eventDate }
                if eventDate > lastActivityAt { lastActivityAt = eventDate }
            }

            let type = (obj["type"] as? String) ?? ""
            switch type {
            case "ai-title":
                if let t = obj["aiTitle"] as? String, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    aiTitle = t.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            case "custom-title":
                if let t = obj["customTitle"] as? String, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    customTitle = t.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            case "compact_boundary", "summary":
                compactCount += 1
            case "user":
                guard let msg = obj["message"] as? [String: Any] else { continue }
                if let text = msg["content"] as? String {
                    let cleaned = cleanUserPrompt(text)
                    if !cleaned.isEmpty {
                        if firstUserPrompt == nil { firstUserPrompt = cleaned }
                        lastUserPrompt = cleaned
                        turnCount += 1
                        lastEventKind = "user_prompt"
                        errorBanner = nil
                    }
                } else if let arr = msg["content"] as? [[String: Any]] {
                    var sawUserText = false
                    for item in arr {
                        let ctype = (item["type"] as? String) ?? ""
                        if ctype == "tool_result" {
                            let toolID = (item["tool_use_id"] as? String) ?? ""
                            let isErr = (item["is_error"] as? Bool) ?? false
                            if isErr { failedToolCalls += 1 }
                            if var tool = openTools.removeValue(forKey: toolID) {
                                openToolOrder.removeAll { $0 == toolID }
                                tool.finishedAt = eventDate ?? lastActivityAt
                                tool.isError = isErr
                                completedTools.append(tool)
                            }
                            lastEventKind = "tool_result"
                        } else if ctype == "text", let t = item["text"] as? String {
                            let cleaned = cleanUserPrompt(t)
                            if !cleaned.isEmpty {
                                if firstUserPrompt == nil { firstUserPrompt = cleaned }
                                lastUserPrompt = cleaned
                                sawUserText = true
                            }
                        }
                    }
                    if sawUserText {
                        turnCount += 1
                        lastEventKind = "user_prompt"
                        errorBanner = nil
                    }
                }
            case "assistant":
                guard let msg = obj["message"] as? [String: Any] else { continue }
                if let m = msg["model"] as? String, !m.isEmpty, m != "<synthetic>" {
                    model = m
                }
                if let sr = msg["stop_reason"] as? String {
                    lastStopReason = sr
                }
                if let usageObj = msg["usage"] as? [String: Any] {
                    let u = TokenUsage(
                        input: (usageObj["input_tokens"] as? Int) ?? 0,
                        output: (usageObj["output_tokens"] as? Int) ?? 0,
                        cacheRead: (usageObj["cache_read_input_tokens"] as? Int) ?? 0,
                        cacheWrite: (usageObj["cache_creation_input_tokens"] as? Int) ?? 0
                    )
                    lastPromptTokens = u.totalPromptTokens
                    if let msgID = msg["id"] as? String, !msgID.isEmpty {
                        let prev = usageByMessageID[msgID] ?? TokenUsage()
                        usageByMessageID[msgID] = TokenUsage(
                            input: max(prev.input, u.input),
                            output: max(prev.output, u.output),
                            cacheRead: max(prev.cacheRead, u.cacheRead),
                            cacheWrite: max(prev.cacheWrite, u.cacheWrite)
                        )
                    } else {
                        anonymousUsage.input += u.input
                        anonymousUsage.output += u.output
                        anonymousUsage.cacheRead += u.cacheRead
                        anonymousUsage.cacheWrite += u.cacheWrite
                    }
                }

                if let arr = msg["content"] as? [[String: Any]] {
                    var textChunks: [String] = []
                    for item in arr {
                        let ctype = (item["type"] as? String) ?? ""
                        if ctype == "text", let t = item["text"] as? String {
                            let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty {
                                textChunks.append(trimmed)
                            }
                        } else if ctype == "tool_use" {
                            let id = (item["id"] as? String) ?? UUID().uuidString
                            let name = (item["name"] as? String) ?? "Tool"
                            let summary = summarizeToolInput(name: name, input: item["input"])
                            if openTools[id] == nil {
                                let record = ToolCallRecord(
                                    id: id,
                                    name: name,
                                    summary: summary,
                                    startedAt: eventDate ?? lastActivityAt
                                )
                                openTools[id] = record
                                openToolOrder.append(id)
                                totalToolCalls += 1
                            }
                            lastEventKind = "tool_use"
                        }
                    }
                    if !textChunks.isEmpty {
                        let joined = textChunks.joined(separator: "\n\n")
                        lastAssistantText = joined
                        if openTools.isEmpty {
                            lastEventKind = "assistant_text"
                        }
                        if joined.contains("API Error:") || joined.contains("rate_limit_error") || joined.contains("429 Too Many Requests") {
                            errorBanner = firstSingleLine(joined, maxLength: 140)
                        }
                    }
                }
            default:
                break
            }
        }

        let finalTitle = customTitle
            ?? aiTitle
            ?? firstUserPrompt.map { firstSingleLine($0, maxLength: 44) }

        guard let finalTitle, !finalTitle.isEmpty else {
            return nil
        }

        var totalUsage = anonymousUsage
        for (_, u) in usageByMessageID {
            totalUsage.input += u.input
            totalUsage.output += u.output
            totalUsage.cacheRead += u.cacheRead
            totalUsage.cacheWrite += u.cacheWrite
        }

        let currentTool = openToolOrder.last.flatMap { openTools[$0] }
        var recent = completedTools
        if let currentTool {
            recent.append(currentTool)
        }
        let recentTail = Array(recent.suffix(5).reversed())

        let sessionID = "\(host.storageKey):claude:\(rawSessionID)"
        let isSeen = seenSessionIDs.contains(sessionID)
        let ageSeconds = Date().timeIntervalSince(lastActivityAt)

        let status: SessionStatus
        var statusInferred = false
        if errorBanner != nil && ageSeconds < 7200 {
            status = .failed
        } else if currentTool != nil && ageSeconds < 900 {
            if ageSeconds > 8 && ageSeconds < 300 {
                status = .runningTool
                statusInferred = true
            } else {
                status = .runningTool
            }
        } else if (lastEventKind == "user_prompt" || lastEventKind == "tool_result" || lastStopReason == nil) && ageSeconds < 180 {
            status = .generating
        } else if !isSeen && ageSeconds < 1800 && lastAssistantText != nil {
            status = .completed
        } else {
            status = .waitingForInput
        }

        let overview: String
        if let err = errorBanner {
            overview = err
        } else if let tool = currentTool {
            overview = "\(tool.name)：\(tool.summary)"
        } else if let text = lastAssistantText {
            overview = firstSingleLine(text, maxLength: 80)
        } else if let prompt = lastUserPrompt {
            overview = firstSingleLine(prompt, maxLength: 80)
        } else {
            overview = "等待你的下一条消息"
        }

        let contextWindow = PricingCatalog.defaultContextWindow(for: model)
        return AgentSession(
            id: sessionID,
            rawSessionID: rawSessionID,
            kind: .claudeCode,
            host: host,
            title: finalTitle,
            overview: overview,
            status: status,
            statusIsInferred: statusInferred,
            cwd: cwd,
            groupDirectory: cwd,
            provider: defaultProvider,
            model: model,
            usage: totalUsage,
            contextUsedTokens: lastPromptTokens,
            contextWindow: contextWindow,
            currentTool: currentTool,
            recentTools: recentTail,
            totalToolCalls: totalToolCalls,
            successfulToolCalls: max(0, totalToolCalls - failedToolCalls),
            turnCount: max(1, turnCount),
            compactCount: compactCount,
            lastOutputMarkdown: lastAssistantText,
            errorBanner: errorBanner,
            sourceFilePath: filePath,
            startedAt: startedAt ?? fileModificationDate,
            lastActivityAt: lastActivityAt,
            isSeen: isSeen
        )
    }

    private static func cleanUserPrompt(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("<local-command") || text.hasPrefix("<command-name>") {
            return ""
        }
        if let range = text.range(of: "</ide_opened_file>") {
            text = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    public static func summarizeToolInput(name: String, input: Any?) -> String {
        if let dict = input as? [String: Any] {
            for key in ["command", "cmd", "file_path", "path", "pattern", "query", "url", "description"] {
                if let val = dict[key] as? String, !val.isEmpty {
                    return firstSingleLine(val, maxLength: 72)
                }
            }
            if let data = try? JSONSerialization.data(withJSONObject: dict),
               let s = String(data: data, encoding: .utf8) {
                return firstSingleLine(s, maxLength: 72)
            }
        } else if let str = input as? String, !str.isEmpty {
            if let data = str.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return summarizeToolInput(name: name, input: dict)
            }
            if str.hasPrefix("*** Begin Patch") {
                let fileLine = str.split(whereSeparator: \.isNewline).first {
                    $0.hasPrefix("*** Update File:") || $0.hasPrefix("*** Add File:") || $0.hasPrefix("*** Delete File:")
                }
                if let fileLine {
                    let cleaned = fileLine
                        .replacingOccurrences(of: "*** Update File: ", with: "")
                        .replacingOccurrences(of: "*** Add File: ", with: "")
                        .replacingOccurrences(of: "*** Delete File: ", with: "")
                    return URL(fileURLWithPath: String(cleaned)).lastPathComponent
                }
            }
            return firstSingleLine(str, maxLength: 72)
        }
        return name
    }

    public static func firstSingleLine(_ text: String, maxLength: Int) -> String {
        let single = text
            .replacingOccurrences(of: "\r", with: " ")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("```") } ?? text.trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped = single
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "## ", with: "")
            .replacingOccurrences(of: "# ", with: "")
        if stripped.count <= maxLength {
            return stripped
        }
        return String(stripped.prefix(maxLength)) + "…"
    }
}
