import Foundation

public struct SSHHostConfig: Codable, Hashable, Identifiable, Sendable {
    public var id: String { alias }
    public var alias: String
    public var isEnabled: Bool
    public var approvalEnabled: Bool

    public init(alias: String, isEnabled: Bool = false, approvalEnabled: Bool = true) {
        self.alias = alias
        self.isEnabled = isEnabled
        self.approvalEnabled = approvalEnabled
    }
}

public struct SSHProbeResult: Sendable {
    public var connection: HostConnectionState
    public var remoteHome: String?
    public var sessions: [AgentSession]
    public var pendingApprovals: [PendingApproval]
}

public enum SSHProbeService {
    public static func discoverSSHConfigHosts(homeDirectory: String = NSHomeDirectory()) -> [String] {
        let configPath = (homeDirectory as NSString).appendingPathComponent(".ssh/config")
        guard let content = try? String(contentsOfFile: configPath, encoding: .utf8) else {
            return []
        }
        var aliases: [String] = []
        var seen: Set<String> = []
        for line in content.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") || trimmed.isEmpty { continue }
            let parts = trimmed.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2, parts[0].lowercased() == "host" else { continue }
            for rawHost in parts.dropFirst() {
                let h = String(rawHost)
                if h.contains("*") || h.contains("?") || h.hasPrefix("!") { continue }
                if seen.insert(h).inserted {
                    aliases.append(h)
                }
            }
        }
        return aliases
    }

    public static let posixProbeScript: String = #"""
printf "@@HOME %s\n" "$HOME"
now_ts=$(date +%s 2>/dev/null || echo 0)

emit_git_root() {
  d="$1"
  if [ -n "$d" ] && [ -d "$d" ]; then
    gr=$(git -C "$d" rev-parse --show-toplevel 2>/dev/null || echo "$d")
    printf "@@GITROOT %s\t%s\n" "$d" "$gr"
  fi
}

if [ -d "$HOME/.claude/projects" ]; then
  find "$HOME/.claude/projects" -name '*.jsonl' -type f -mtime -3 2>/dev/null | head -n 15 | while IFS= read -r f; do
    mt=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo "$now_ts")
    printf "@@BEGIN claude %s %s\n" "$mt" "$f"
    tail -c 400000 "$f" 2>/dev/null
    printf "\n@@END\n"
  done
fi

if [ -f "$HOME/.codex/session_index.jsonl" ]; then
  printf "@@BEGIN codex_index 0 %s/.codex/session_index.jsonl\n" "$HOME"
  tail -n 120 "$HOME/.codex/session_index.jsonl" 2>/dev/null
  printf "\n@@END\n"
fi

if [ -d "$HOME/.codex/sessions" ]; then
  find "$HOME/.codex/sessions" -name 'rollout-*.jsonl' -type f -mtime -3 2>/dev/null | head -n 15 | while IFS= read -r f; do
    mt=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo "$now_ts")
    printf "@@BEGIN codex %s %s\n" "$mt" "$f"
    head -n 1 "$f" 2>/dev/null
    tail -c 400000 "$f" 2>/dev/null
    printf "\n@@END\n"
  done
fi

if [ -d "$HOME/.dsh/storages/session_projcache/sessions" ]; then
  find "$HOME/.dsh/storages/session_projcache/sessions" -name '*.json' -type f -mtime -4 2>/dev/null | head -n 15 | while IFS= read -r f; do
    mt=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo "$now_ts")
    printf "@@BEGIN dsh %s %s\n" "$mt" "$f"
    cat "$f" 2>/dev/null
    printf "\n@@END\n"
  done
fi

if [ -d "$HOME/.agentbar/pending" ]; then
  for f in "$HOME/.agentbar/pending"/*.json; do
    [ -f "$f" ] || continue
    printf "@@BEGIN pending 0 %s\n" "$f"
    cat "$f" 2>/dev/null
    printf "\n@@END\n"
  done
fi
"""#

    public static func probeHost(
        alias: String,
        seenSessionIDs: Set<String> = []
    ) async -> SSHProbeResult {
        let hostID = HostID.ssh(alias: alias)
        HookApprovalManager.ensureDirectories()
        let controlPath = HookApprovalManager.agentBarRuntimeDirectory
            .appendingPathComponent("cm-%C").path
        let start = Date()

        let runResult = await runProcess(
            executable: "/usr/bin/ssh",
            arguments: [
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=7",
                "-o", "ControlMaster=auto",
                "-o", "ControlPath=\(controlPath)",
                "-o", "ControlPersist=5m",
                alias,
                "sh -s"
            ],
            stdinData: Data(posixProbeScript.utf8),
            timeoutSeconds: 12
        )

        let latencyMs = Int(Date().timeIntervalSince(start) * 1000.0)
        guard runResult.exitCode == 0 else {
            let errText = summarizeSSHError(runResult.stderr)
            return SSHProbeResult(
                connection: HostConnectionState(
                    host: hostID,
                    isOnline: false,
                    latencyMs: nil,
                    errorMessage: errText,
                    updatedAt: Date()
                ),
                remoteHome: nil,
                sessions: [],
                pendingApprovals: []
            )
        }

        let parsed = parseProbeOutput(
            stdout: runResult.stdout,
            host: hostID,
            seenSessionIDs: seenSessionIDs
        )
        return SSHProbeResult(
            connection: HostConnectionState(
                host: hostID,
                isOnline: true,
                latencyMs: latencyMs,
                errorMessage: nil,
                updatedAt: Date()
            ),
            remoteHome: parsed.remoteHome,
            sessions: parsed.sessions,
            pendingApprovals: parsed.pendingApprovals
        )
    }

    public static func sendRemoteDecision(alias: String, requestID: String, jsonData: Data) async throws {
        let safeID = requestID.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        let controlPath = HookApprovalManager.agentBarRuntimeDirectory
            .appendingPathComponent("cm-%C").path
        let remoteCmd = "mkdir -p ~/.agentbar/decisions && cat > ~/.agentbar/decisions/\(safeID).json && rm -f ~/.agentbar/pending/\(safeID).json"
        let res = await runProcess(
            executable: "/usr/bin/ssh",
            arguments: [
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=6",
                "-o", "ControlMaster=auto",
                "-o", "ControlPath=\(controlPath)",
                "-o", "ControlPersist=5m",
                alias,
                remoteCmd
            ],
            stdinData: jsonData,
            timeoutSeconds: 10
        )
        if res.exitCode != 0 {
            throw NSError(
                domain: "SSHProbeService",
                code: Int(res.exitCode),
                userInfo: [NSLocalizedDescriptionKey: summarizeSSHError(res.stderr)]
            )
        }
    }

    private static func parseProbeOutput(
        stdout: String,
        host: HostID,
        seenSessionIDs: Set<String>
    ) -> (remoteHome: String?, sessions: [AgentSession], pendingApprovals: [PendingApproval]) {
        var remoteHome: String?
        var codexTitles: [String: String] = [:]
        var blocks: [(kind: String, mtime: Date, path: String, body: String)] = []

        var currentHeader: (kind: String, mtime: Date, path: String)?
        var currentLines: [Substring] = []

        for line in stdout.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            if line.hasPrefix("@@HOME ") {
                remoteHome = String(line.dropFirst("@@HOME ".count)).trimmingCharacters(in: .whitespaces)
                continue
            }
            if line.hasPrefix("@@BEGIN ") {
                let rest = line.dropFirst("@@BEGIN ".count)
                let parts = rest.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
                if parts.count == 3 {
                    let kind = String(parts[0])
                    let ts = Double(parts[1]) ?? Date().timeIntervalSince1970
                    let path = String(parts[2])
                    currentHeader = (kind, Date(timeIntervalSince1970: ts), path)
                    currentLines.removeAll(keepingCapacity: true)
                }
                continue
            }
            if line == "@@END" {
                if let header = currentHeader {
                    blocks.append((header.kind, header.mtime, header.path, currentLines.joined(separator: "\n")))
                }
                currentHeader = nil
                currentLines.removeAll(keepingCapacity: true)
                continue
            }
            if currentHeader != nil {
                currentLines.append(line)
            }
        }

        for b in blocks where b.kind == "codex_index" {
            for line in b.body.split(whereSeparator: \.isNewline) {
                if let data = line.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let id = obj["id"] as? String,
                   let name = obj["thread_name"] as? String {
                    codexTitles[id] = CodexAdapter.cleanThreadTitle(name)
                }
            }
        }

        var sessions: [AgentSession] = []
        var approvals: [PendingApproval] = []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for b in blocks {
            switch b.kind {
            case "claude":
                let fid = URL(fileURLWithPath: b.path).deletingPathExtension().lastPathComponent
                if let s = ClaudeCodeAdapter.parseTranscript(
                    jsonl: b.body,
                    fallbackSessionID: fid,
                    filePath: b.path,
                    fileModificationDate: b.mtime,
                    host: host,
                    seenSessionIDs: seenSessionIDs
                ) {
                    sessions.append(s)
                }
            case "codex":
                if let s = CodexAdapter.parseRollout(
                    jsonl: b.body,
                    filePath: b.path,
                    fileModificationDate: b.mtime,
                    host: host,
                    threadTitles: codexTitles,
                    seenSessionIDs: seenSessionIDs
                ) {
                    sessions.append(s)
                }
            case "dsh":
                let fid = URL(fileURLWithPath: b.path).deletingPathExtension().lastPathComponent
                if let data = b.body.data(using: .utf8),
                   let s = DeepSeekHarnessAdapter.parseProjection(
                       data: data,
                       fallbackID: fid,
                       filePath: b.path,
                       fileModificationDate: b.mtime,
                       host: host,
                       seenSessionIDs: seenSessionIDs
                   ) {
                    sessions.append(s)
                }
            case "pending":
                if let data = b.body.data(using: .utf8),
                   var pending = try? decoder.decode(PendingApproval.self, from: data) {
                    pending.host = host
                    if pending.highRiskMatchedRule == nil {
                        pending.highRiskMatchedRule = HookApprovalManager.matchedHighRiskRule(in: pending.commandOrSummary)
                    }
                    approvals.append(pending)
                }
            default:
                break
            }
        }
        return (remoteHome, sessions, approvals)
    }

    private static func summarizeSSHError(_ stderr: String) -> String {
        let lower = stderr.lowercased()
        if lower.contains("permission denied") { return "认证失败" }
        if lower.contains("timed out") || lower.contains("timeout") { return "连接超时" }
        if lower.contains("could not resolve") { return "域名无法解析" }
        if lower.contains("connection refused") { return "连接被拒绝" }
        let line = stderr.split(whereSeparator: \.isNewline).first.map(String.init) ?? "不可达"
        return String(line.prefix(36))
    }

    private static func runProcess(
        executable: String,
        arguments: [String],
        stdinData: Data?,
        timeoutSeconds: TimeInterval
    ) async -> (exitCode: Int32, stdout: String, stderr: String) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: executable)
                proc.arguments = arguments
                let outPipe = Pipe()
                let errPipe = Pipe()
                proc.standardOutput = outPipe
                proc.standardError = errPipe
                let inPipe = Pipe()
                if stdinData != nil {
                    proc.standardInput = inPipe
                }

                do {
                    try proc.run()
                } catch {
                    continuation.resume(returning: (-1, "", error.localizedDescription))
                    return
                }

                if let stdinData {
                    try? inPipe.fileHandleForWriting.write(contentsOf: stdinData)
                    try? inPipe.fileHandleForWriting.close()
                }

                let timer = DispatchSource.makeTimerSource()
                timer.schedule(deadline: .now() + timeoutSeconds)
                timer.setEventHandler {
                    if proc.isRunning { proc.terminate() }
                }
                timer.resume()

                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                timer.cancel()

                continuation.resume(returning: (
                    proc.terminationStatus,
                    String(data: outData, encoding: .utf8) ?? "",
                    String(data: errData, encoding: .utf8) ?? ""
                ))
            }
        }
    }
}
