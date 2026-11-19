import AppKit
import CoreGraphics
import Darwin
import Foundation

public enum ProcessAndChatScanner {
    public static func scanLocalAgentProcesses() -> [ProcessStats] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-eo", "pid=,pcpu=,rss=,tty=,comm="]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        var results: [ProcessStats] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(maxSplits: 4, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
            guard parts.count >= 5,
                  let pid = Int32(parts[0]) else {
                continue
            }
            let cpu = Double(parts[1]) ?? 0.0
            let rssKB = UInt64(parts[2]) ?? 0
            let tty = String(parts[3])
            let comm = String(parts[4])
            let lower = comm.lowercased()
            guard lower.contains("claude")
                || lower.contains("codex")
                || lower.contains("cursor")
                || lower.contains("trae")
                || lower.contains("deepseek")
                || lower.contains("doubao")
                || lower.contains("dsh") else {
                continue
            }
            let footprint = physicalFootprint(pid: pid) ?? (rssKB * 1024)
            let cwd = processWorkingDirectory(pid: pid)
            results.append(ProcessStats(
                pid: pid,
                memoryBytes: footprint,
                cpuPercent: cpu,
                tty: (tty == "??" || tty == "?") ? nil : tty,
                cwd: cwd,
                command: comm
            ))
        }
        return results
    }

    public static func physicalFootprint(pid: Int32) -> UInt64? {
        var info = rusage_info_v4()
        let res = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
            }
        }
        guard res == 0 else { return nil }
        return info.ri_phys_footprint
    }

    public static func processWorkingDirectory(pid: Int32) -> String? {
        var vnodeInfo = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.stride)
        let ret = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vnodeInfo, size)
        guard ret == size else { return nil }
        return withUnsafePointer(to: &vnodeInfo.pvi_cdir.vip_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { cStr in
                let path = String(cString: cStr)
                return path.isEmpty ? nil : path
            }
        }
    }

    public static func attachProcesses(to sessions: inout [AgentSession], processes: [ProcessStats]) {
        for idx in sessions.indices where sessions[idx].host.isLocal {
            let kind = sessions[idx].kind
            let targetCwd = sessions[idx].cwd
            let matched = processes.filter { proc in
                let cmd = proc.command.lowercased()
                switch kind {
                case .claudeCode:
                    return cmd.hasSuffix("/claude") || cmd == "claude"
                case .claudeDesktop:
                    return cmd.contains("claude.app")
                case .codexCLI:
                    return (cmd.hasSuffix("/codex") || cmd == "codex") && !cmd.contains("chatgpt.app/contents/macos/chatgpt")
                case .codexDesktop:
                    return cmd.contains("chatgpt.app") || cmd.contains("codex")
                case .deepseekHarness:
                    return cmd.contains("deepseek harness.app") || cmd.contains("dsh")
                case .cursor:
                    return cmd.contains("cursor.app/contents/macos/cursor")
                case .trae:
                    return cmd.contains("trae")
                case .doubao:
                    return cmd.contains("doubao")
                case .deepseekChat:
                    return cmd.contains("deepseek.app")
                case .generic:
                    return false
                }
            }
            if let exactCwdMatch = matched.first(where: { proc in
                guard let pcwd = proc.cwd, let scwd = targetCwd else { return false }
                return pcwd == scwd || pcwd.hasPrefix(scwd + "/") || scwd.hasPrefix(pcwd + "/")
            }) {
                sessions[idx].process = exactCwdMatch
            } else if let best = matched.max(by: { $0.memoryBytes < $1.memoryBytes }) {
                sessions[idx].process = best
            }
        }
    }

    @MainActor
    public static func scanRunningChatApps(processes: [ProcessStats]) -> [AgentSession] {
        let running = NSWorkspace.shared.runningApplications
        let windowTitles = currentWindowTitlesByPID()
        var chatSessions: [AgentSession] = []

        for app in running {
            guard let bid = app.bundleIdentifier?.lowercased() else { continue }
            let kind: AgentKind?
            if bid.contains("doubao") {
                kind = .doubao
            } else if bid == "com.deepseek.chat" {
                kind = .deepseekChat
            } else {
                kind = nil
            }
            guard let kind else { continue }
            let pid = app.processIdentifier
            let winTitle = windowTitles[pid]?.first { !$0.isEmpty }
            let procStat = processes.first { $0.pid == pid }
            let title = winTitle ?? "\(kind.displayName)"
            let stateDesc = app.isActive ? "前台窗口运行中" : "后台运行中"
            let overview = winTitle != nil ? "窗口标题 · \(stateDesc)" : "\(stateDesc) · 仅进程级检测"

            chatSessions.append(AgentSession(
                id: "local:chat:\(bid):\(pid)",
                rawSessionID: "\(pid)",
                kind: kind,
                host: .local,
                title: title,
                overview: overview,
                status: .runningProcessOnly,
                process: procStat,
                startedAt: app.launchDate ?? Date(),
                lastActivityAt: Date(),
                isSeen: true
            ))
        }
        return chatSessions
    }

    private static func currentWindowTitlesByPID() -> [pid_t: [String]] {
        guard let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return [:]
        }
        var map: [pid_t: [String]] = [:]
        for entry in infoList {
            guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  let name = entry[kCGWindowName as String] as? String else {
                continue
            }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                map[pid, default: []].append(trimmed)
            }
        }
        return map
    }
}
