import Darwin
import Foundation

public struct SSHHostConfig: Codable, Hashable, Identifiable, Sendable {
    public var id: String { alias }
    public var alias: String
    public var hostname: String?
    public var user: String?
    public var port: Int?
    public var isEnabled: Bool
    public var approvalEnabled: Bool

    public init(
        alias: String,
        hostname: String? = nil,
        user: String? = nil,
        port: Int? = nil,
        isEnabled: Bool = true,
        approvalEnabled: Bool = true
    ) {
        self.alias = alias
        self.hostname = hostname
        self.user = user
        self.port = port
        self.isEnabled = isEnabled
        self.approvalEnabled = approvalEnabled
    }

    public var connectionSubtitle: String? {
        guard let hostname, !hostname.isEmpty else { return nil }
        let target = (user != nil && !user!.isEmpty) ? "\(user!)@\(hostname)" : hostname
        if let port, port != 22 {
            return "\(target):\(port)"
        }
        return target
    }
}

public struct SSHProbeResult: Sendable {
    public var connection: HostConnectionState
    public var remoteHome: String?
    public var sessions: [AgentSession]
    public var pendingApprovals: [PendingApproval]
}

public enum SSHProbeService {
    public static var sharedControlDirectoryPath: String {
        let dir = "/tmp/agentbar-ssh-\(getuid())"
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir) {
            try? fm.createDirectory(
                atPath: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        return dir
    }

    public static var sharedControlPathPattern: String {
        (sharedControlDirectoryPath as NSString).appendingPathComponent("cm-%C")
    }

    public static func discoverSSHConfigEntries(homeDirectory: String = NSHomeDirectory()) -> [SSHHostConfig] {
        let sshDir = (homeDirectory as NSString).appendingPathComponent(".ssh")
        let rootConfig = (sshDir as NSString).appendingPathComponent("config")
        var visitedFiles: Set<String> = []
        var rawStanzas: [(aliases: [String], hostname: String?, user: String?, port: Int?)] = []

        parseSSHConfigFile(
            path: rootConfig,
            sshDirectory: sshDir,
            homeDirectory: homeDirectory,
            visited: &visitedFiles,
            into: &rawStanzas
        )

        var results: [SSHHostConfig] = []
        var seenAliases: Set<String> = []
        for stanza in rawStanzas {
            for alias in stanza.aliases {
                if isIgnoredGitOrWildcardHost(alias: alias, hostname: stanza.hostname, user: stanza.user) {
                    continue
                }
                if seenAliases.insert(alias).inserted {
                    results.append(SSHHostConfig(
                        alias: alias,
                        hostname: stanza.hostname,
                        user: stanza.user,
                        port: stanza.port,
                        isEnabled: true,
                        approvalEnabled: true
                    ))
                }
            }
        }
        return results
    }

    public static func discoverSSHConfigHosts(homeDirectory: String = NSHomeDirectory()) -> [String] {
        discoverSSHConfigEntries(homeDirectory: homeDirectory).map(\.alias)
    }

    public static func isIgnoredGitOrWildcardHost(alias: String, hostname: String? = nil, user: String? = nil) -> Bool {
        if alias.isEmpty || alias.contains("*") || alias.contains("?") || alias.hasPrefix("!") {
            return true
        }
        let lowerAlias = alias.lowercased()
        let lowerHost = (hostname ?? "").lowercased()
        let lowerUser = (user ?? "").lowercased()
        let gitDomains = [
            "github.com", "github-", "github.",
            "gitlab.com", "gitlab-", "gitlab.",
            "bitbucket.org", "gitee.com", "codeup.aliyun.com",
            "ssh.dev.azure.com", "vs-ssh.visualstudio.com",
            "hf.co", "huggingface.co"
        ]
        for pat in gitDomains {
            if lowerAlias.contains(pat) || lowerHost.contains(pat) {
                return true
            }
        }
        if lowerUser == "git" && (lowerAlias.contains("git") || lowerHost.contains("git")) {
            return true
        }
        return false
    }

    private static func parseSSHConfigFile(
        path: String,
        sshDirectory: String,
        homeDirectory: String,
        visited: inout Set<String>,
        into stanzas: inout [(aliases: [String], hostname: String?, user: String?, port: Int?)]
    ) {
        let standardized = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard visited.insert(standardized).inserted,
              let content = try? String(contentsOfFile: standardized, encoding: .utf8) else {
            return
        }

        var currentAliases: [String] = []
        var currentHostname: String?
        var currentUser: String?
        var currentPort: Int?

        func flushCurrent() {
            if !currentAliases.isEmpty {
                stanzas.append((currentAliases, currentHostname, currentUser, currentPort))
            }
            currentAliases = []
            currentHostname = nil
            currentUser = nil
            currentPort = nil
        }

        for rawLine in content.split(whereSeparator: \.isNewline) {
            let lineWithoutComment: Substring
            if let hashIdx = rawLine.firstIndex(of: "#") {
                lineWithoutComment = rawLine[..<hashIdx]
            } else {
                lineWithoutComment = rawLine
            }
            let trimmed = lineWithoutComment.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            let tokens = splitSSHConfigTokens(trimmed)
            guard tokens.count >= 2 else { continue }
            let keyword = tokens[0].lowercased()
            let args = Array(tokens.dropFirst())

            switch keyword {
            case "include":
                flushCurrent()
                for pattern in args {
                    for matchedFile in expandIncludePattern(pattern, sshDirectory: sshDirectory, homeDirectory: homeDirectory) {
                        parseSSHConfigFile(
                            path: matchedFile,
                            sshDirectory: sshDirectory,
                            homeDirectory: homeDirectory,
                            visited: &visited,
                            into: &stanzas
                        )
                    }
                }
            case "host":
                flushCurrent()
                currentAliases = args
            case "match":
                flushCurrent()
            case "hostname":
                if currentHostname == nil { currentHostname = args.first }
            case "user":
                if currentUser == nil { currentUser = args.first }
            case "port":
                if currentPort == nil, let first = args.first, let p = Int(first) {
                    currentPort = p
                }
            default:
                break
            }
        }
        flushCurrent()
    }

    private static func splitSSHConfigTokens(_ line: String) -> [String] {
        let normalized = line.replacingOccurrences(of: "=", with: " ")
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        for ch in normalized {
            if ch == "\"" {
                inQuotes.toggle()
            } else if ch.isWhitespace && !inQuotes {
                if !current.isEmpty {
                    tokens.append(current)
                    current.removeAll(keepingCapacity: true)
                }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    private static func expandIncludePattern(
        _ rawPattern: String,
        sshDirectory: String,
        homeDirectory: String
    ) -> [String] {
        let expanded: String
        if rawPattern.hasPrefix("~/") {
            expanded = (homeDirectory as NSString).appendingPathComponent(String(rawPattern.dropFirst(2)))
        } else if rawPattern.hasPrefix("/") {
            expanded = rawPattern
        } else {
            expanded = (sshDirectory as NSString).appendingPathComponent(rawPattern)
        }

        var globResult = glob_t()
        defer { globfree(&globResult) }
        if glob(expanded, GLOB_TILDE | GLOB_BRACE, nil, &globResult) == 0, globResult.gl_matchc > 0 {
            var paths: [String] = []
            for idx in 0..<Int(globResult.gl_matchc) {
                if let cStr = globResult.gl_pathv[idx] {
                    paths.append(String(cString: cStr))
                }
            }
            return paths.sorted()
        }
        if FileManager.default.fileExists(atPath: expanded) {
            return [expanded]
        }
        return []
    }

    public static let posixProbeScript: String = #"""
printf "@@HOME %s\n" "$HOME"
now_ts=$(date +%s 2>/dev/null || echo 0)

list_recent_files() {
  root="$1"
  pat="$2"
  limit="$3"
  [ -d "$root" ] || return 0
  found=$(find "$root" -name "$pat" -type f -mtime -14 2>/dev/null | head -n "$limit")
  if [ -z "$found" ]; then
    found=$(find "$root" -name "$pat" -type f 2>/dev/null | head -n "$limit")
  fi
  printf "%s\n" "$found"
}

if [ -d "$HOME/.claude/projects" ]; then
  list_recent_files "$HOME/.claude/projects" '*.jsonl' 18 | while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    mt=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo "$now_ts")
    printf "@@BEGIN claude %s %s\n" "$mt" "$f"
    tail -c 400000 "$f" 2>/dev/null
    printf "\n@@END\n"
  done
fi

if [ -f "$HOME/.codex/session_index.jsonl" ]; then
  printf "@@BEGIN codex_index 0 %s/.codex/session_index.jsonl\n" "$HOME"
  tail -n 200 "$HOME/.codex/session_index.jsonl" 2>/dev/null
  printf "\n@@END\n"
fi

if [ -d "$HOME/.codex/sessions" ]; then
  list_recent_files "$HOME/.codex/sessions" 'rollout-*.jsonl' 18 | while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    mt=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo "$now_ts")
    printf "@@BEGIN codex %s %s\n" "$mt" "$f"
    head -n 1 "$f" 2>/dev/null
    tail -c 400000 "$f" 2>/dev/null
    printf "\n@@END\n"
  done
fi

if [ -d "$HOME/.dsh/storages/session_projcache/sessions" ]; then
  list_recent_files "$HOME/.dsh/storages/session_projcache/sessions" '*.json' 18 | while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    mt=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo "$now_ts")
    printf "@@BEGIN dsh %s %s\n" "$mt" "$f"
    cat "$f" 2>/dev/null
    printf "\n@@END\n"
  done
fi

printf "@@BEGIN procs 0 ps\n"
ps -eo pid=,pcpu=,rss=,tty=,args= 2>/dev/null | grep -E '(^|[ /])(claude|codex|dsh|cursor-server|trae-server)( |$)' | grep -v 'grep' | head -n 25 | while IFS= read -r line; do
  pid=$(printf "%s" "$line" | awk '{print $1}')
  cwd=""
  if [ -n "$pid" ] && [ -d "/proc/$pid/cwd" ]; then
    cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null || true)
  fi
  printf "%s\t@@CWD=%s\n" "$line" "$cwd"
done
printf "@@END\n"

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
        lookbackHours: Double = 168,
        seenSessionIDs: Set<String> = []
    ) async -> SSHProbeResult {
        let hostID = HostID.ssh(alias: alias)
        HookApprovalManager.ensureDirectories()
        let controlPath = sharedControlPathPattern
        let start = Date()

        let runResult = await runProcess(
            executable: "/usr/bin/ssh",
            arguments: [
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=6",
                "-o", "ControlMaster=auto",
                "-o", "ControlPath=\(controlPath)",
                "-o", "ControlPersist=10m",
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
            lookbackHours: lookbackHours,
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
        let controlPath = sharedControlPathPattern
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
        lookbackHours: Double,
        seenSessionIDs: Set<String>
    ) -> (remoteHome: String?, sessions: [AgentSession], pendingApprovals: [PendingApproval]) {
        var remoteHome: String?
        var codexTitles: [String: String] = [:]
        var blocks: [(kind: String, mtime: Date, path: String, body: String)] = []
        let cutoff = Date().addingTimeInterval(-max(24, lookbackHours) * 3600)

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
        var remoteProcesses: [ProcessStats] = []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for b in blocks {
            switch b.kind {
            case "claude":
                guard b.mtime >= cutoff else { continue }
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
                guard b.mtime >= cutoff else { continue }
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
                guard b.mtime >= cutoff else { continue }
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
            case "procs":
                remoteProcesses = parseRemoteProcessBlock(b.body)
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

        if !remoteProcesses.isEmpty {
            attachAndSynthesizeRemoteProcesses(remoteProcesses, into: &sessions, host: host)
        }
        sessions.sort { $0.lastActivityAt > $1.lastActivityAt }
        return (remoteHome, sessions, approvals)
    }

    private static func parseRemoteProcessBlock(_ text: String) -> [ProcessStats] {
        var out: [ProcessStats] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let parts = rawLine.components(separatedBy: "\t@@CWD=")
            let psPart = parts.first?.trimmingCharacters(in: .whitespaces) ?? ""
            let cwdPart = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            let cols = psPart.split(maxSplits: 4, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
            guard cols.count >= 5,
                  let pid = Int32(cols[0]) else {
                continue
            }
            let cpu = Double(cols[1]) ?? 0
            let rssKB = UInt64(cols[2]) ?? 0
            let tty = cols[3] == "?" || cols[3] == "??" ? nil : String(cols[3])
            let cmd = String(cols[4])
            out.append(ProcessStats(
                pid: pid,
                memoryBytes: rssKB * 1024,
                cpuPercent: cpu,
                tty: tty,
                cwd: cwdPart.isEmpty ? nil : cwdPart,
                command: cmd
            ))
        }
        return out
    }

    private static func attachAndSynthesizeRemoteProcesses(
        _ procs: [ProcessStats],
        into sessions: inout [AgentSession],
        host: HostID
    ) {
        var unmatchedCursorDirs: Set<String> = []
        for proc in procs {
            let lowerCmd = proc.command.lowercased()
            if let idx = sessions.firstIndex(where: { s in
                guard s.process == nil else { return false }
                if let pcwd = proc.cwd, let scwd = s.cwd, pcwd == scwd {
                    return true
                }
                if lowerCmd.contains("claude") && s.kind == .claudeCode { return proc.cwd == nil }
                if lowerCmd.contains("codex") && (s.kind == .codexCLI || s.kind == .codexDesktop) { return proc.cwd == nil }
                if lowerCmd.contains("dsh") && s.kind == .deepseekHarness { return proc.cwd == nil }
                return false
            }) {
                sessions[idx].process = proc
            } else if lowerCmd.contains("cursor-server") || lowerCmd.contains("trae-server") {
                let isTrae = lowerCmd.contains("trae-server")
                let dir = proc.cwd
                let dedupKey = "\(isTrae ? "trae" : "cursor"):\(dir ?? "server")"
                guard unmatchedCursorDirs.insert(dedupKey).inserted else { continue }
                sessions.append(AgentSession(
                    id: "\(host.storageKey):remote-ide:\(dedupKey)",
                    rawSessionID: "pid-\(proc.pid)",
                    kind: isTrae ? .trae : .cursor,
                    host: host,
                    title: isTrae ? "Trae Remote-SSH 服务运行中" : "Cursor Remote-SSH 服务运行中",
                    overview: "PID \(proc.pid) · 内存 \(FormattingHelpers.memoryString(proc.memoryBytes))",
                    status: .runningProcessOnly,
                    cwd: dir,
                    groupDirectory: dir,
                    process: proc,
                    startedAt: Date(),
                    lastActivityAt: Date(),
                    isSeen: true
                ))
            }
        }
    }

    private static func summarizeSSHError(_ stderr: String) -> String {
        let lower = stderr.lowercased()
        if lower.contains("permission denied") || lower.contains("gssapi") || lower.contains("kex_exchange") {
            return "需登录认证"
        }
        if lower.contains("timed out") || lower.contains("timeout") { return "连接超时" }
        if lower.contains("could not resolve") { return "域名无法解析" }
        if lower.contains("connection refused") { return "连接被拒绝" }
        if lower.contains("host key verification failed") { return "HostKey 待确认" }
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
                var env = ProcessInfo.processInfo.environment
                let home = NSHomeDirectory()
                let extraPaths = [
                    "/opt/homebrew/bin",
                    "/usr/local/bin",
                    "\(home)/.local/bin",
                    "/usr/bin",
                    "/bin",
                    "/usr/sbin",
                    "/sbin"
                ]
                let currentPath = env["PATH"] ?? ""
                env["PATH"] = (extraPaths + [currentPath]).filter { !$0.isEmpty }.joined(separator: ":")
                proc.environment = env
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
