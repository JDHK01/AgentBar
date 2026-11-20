import Foundation

public enum DeepSeekHarnessAdapter {
    public static func loadLocalSessions(
        homeDirectory: String = NSHomeDirectory(),
        lookbackHours: Double = 96,
        seenAtByID: [String: TimeInterval] = [:]
    ) async -> [AgentSession] {
        let dirPath = (homeDirectory as NSString).appendingPathComponent(".dsh/storages/session_projcache/sessions")
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: URL(fileURLWithPath: dirPath),
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        let cutoff = Date().addingTimeInterval(-lookbackHours * 3600)
        var results: [AgentSession] = []
        for url in items where url.pathExtension == "json" {
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            guard mtime >= cutoff,
                  let data = try? Data(contentsOf: url),
                  var session = parseProjection(
                      data: data,
                      fallbackID: url.deletingPathExtension().lastPathComponent,
                      filePath: url.path,
                      fileModificationDate: mtime,
                      host: .local,
                      seenAtByID: seenAtByID
                  ) else {
                continue
            }
            session.groupDirectory = await GitRootResolver.shared.resolveGroupDirectory(for: session.cwd)
            results.append(session)
        }
        return results
    }

    public static func parseProjection(
        data: Data,
        fallbackID: String,
        filePath: String?,
        fileModificationDate: Date,
        host: HostID,
        seenAtByID: [String: TimeInterval] = [:]
    ) -> AgentSession? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let record = root["record"] as? [String: Any],
              let rows = record["rows"] as? [String: Any] else {
            return nil
        }

        if let meta = (rows["sessionListMetadata"] as? [String: Any])?["val"] as? [String: Any],
           (meta["blank"] as? Bool) == true {
            return nil
        }
        if let sub = (rows["subagent"] as? [String: Any])?["val"] as? [String: Any],
           !sub.isEmpty, sub["parentSessionId"] != nil {
            return nil
        }

        let identity = record["identity"] as? [String: Any]
        let createdMs = identity?["createdAt"] as? Double
        let startedAt = createdMs.map { Date(timeIntervalSince1970: $0 / 1000.0) } ?? fileModificationDate

        let cwd = ((rows["workingDirectory"] as? [String: Any])?["val"] as? String)
            ?? (identity?["cwd"] as? String)

        let rawTitle = ((rows["title"] as? [String: Any])?["val"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let outlineVal = (rows["turnOutline"] as? [String: Any])?["val"] as? [String: Any]
        let turnsArr = (outlineVal?["turns"] as? [[String: Any]]) ?? []
        let draft = (outlineVal?["draft"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstPrompt = turnsArr.first?["prompt"] as? String
        let lastResponse = turnsArr.reversed().compactMap { ($0["response"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }

        let title = (rawTitle?.isEmpty == false ? rawTitle : nil)
            ?? firstPrompt.map { ClaudeCodeAdapter.firstSingleLine($0, maxLength: 44) }
        guard let title, !title.isEmpty else { return nil }

        var provider = "DeepSeek"
        var model: String?
        if let ms = (rows["modelSelection"] as? [String: Any])?["val"] as? [String: Any],
           let lastUsed = ms["lastUsed"] as? [String: Any] {
            if let p = lastUsed["provider"] as? String, !p.isEmpty {
                provider = FormattingHelpers.providerDisplay(from: p) ?? p
            }
            if let m = lastUsed["model"] as? String, !m.isEmpty {
                model = m
            }
        }

        var usage = TokenUsage()
        if let tu = (rows["tokenUsage"] as? [String: Any])?["val"] as? [String: Any],
           let totals = tu["totals"] as? [String: Any] {
            usage = TokenUsage(
                input: (totals["uncachedInputTokens"] as? Int) ?? 0,
                output: (totals["outputTokens"] as? Int) ?? 0,
                cacheRead: (totals["cacheReadTokens"] as? Int) ?? 0,
                cacheWrite: (totals["cacheWriteTokens"] as? Int) ?? 0
            )
        }

        var contextUsed: Int?
        var contextWindow: Int?
        if let cp = (rows["contextPressure"] as? [String: Any])?["val"] as? [String: Any] {
            contextUsed = (cp["pressureTokens"] as? Int) ?? (cp["surfaceTokens"] as? Int)
            contextWindow = cp["contextWindow"] as? Int
        }

        var turnsCount = max(1, turnsArr.count)
        var stepsCount = 0
        var tokPerSec: Double?
        var hasPendingToolCalls = false
        if let stats = (rows["sessionStats"] as? [String: Any])?["val"] as? [String: Any] {
            turnsCount = max(turnsCount, (stats["turns"] as? Int) ?? 1)
            stepsCount = (stats["steps"] as? Int) ?? 0
            if let decodeTokens = stats["decodeTokens"] as? Int,
               let decodeMs = stats["decodeMs"] as? Double,
               decodeMs > 200, decodeTokens > 0 {
                tokPerSec = Double(decodeTokens) / (decodeMs / 1000.0)
            }
            if let pending = stats["pendingCalls"] as? [String: Any], !pending.isEmpty {
                hasPendingToolCalls = true
            }
        }

        let approvalVal = (rows["approvalState"] as? [String: Any])?["val"] as? [String: Any]
        let turnOpen = (approvalVal?["turnOpen"] as? Bool) ?? false

        let sessionID = "\(host.storageKey):dsh:\(fallbackID)"
        let isSeen = SeenSessionLookup.isSeen(
            sessionID: sessionID,
            lastActivityAt: fileModificationDate,
            seenAtByID: seenAtByID
        )
        let age = Date().timeIntervalSince(fileModificationDate)

        let status: SessionStatus
        if hasPendingToolCalls && age < 600 {
            status = .runningTool
        } else if turnOpen && age < 300 {
            status = .generating
        } else if !isSeen && age < 1800 && (lastResponse != nil || draft != nil) {
            status = .completed
        } else {
            status = .waitingForInput
        }

        let outputMarkdown = (lastResponse?.isEmpty == false ? lastResponse : draft)
        let overview: String
        if let draft, !draft.isEmpty && turnOpen {
            overview = ClaudeCodeAdapter.firstSingleLine(draft, maxLength: 80)
        } else if let resp = lastResponse, !resp.isEmpty {
            overview = ClaudeCodeAdapter.firstSingleLine(resp, maxLength: 80)
        } else if let fp = firstPrompt, !fp.isEmpty {
            overview = ClaudeCodeAdapter.firstSingleLine(fp, maxLength: 80)
        } else {
            overview = "DeepSeek Harness 会话"
        }

        return AgentSession(
            id: sessionID,
            rawSessionID: fallbackID,
            kind: .deepseekHarness,
            host: host,
            title: title,
            overview: overview,
            status: status,
            cwd: cwd,
            groupDirectory: cwd,
            provider: provider,
            model: model,
            usage: usage,
            contextUsedTokens: contextUsed,
            contextWindow: contextWindow ?? PricingCatalog.defaultContextWindow(for: model),
            totalToolCalls: stepsCount,
            successfulToolCalls: stepsCount,
            turnCount: turnsCount,
            outputTokensPerSecond: tokPerSec,
            lastOutputMarkdown: outputMarkdown,
            sourceFilePath: filePath,
            startedAt: startedAt,
            lastActivityAt: fileModificationDate,
            isSeen: isSeen
        )
    }
}
