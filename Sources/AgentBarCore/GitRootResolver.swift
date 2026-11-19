import Foundation

public actor GitRootResolver {
    public static let shared = GitRootResolver()
    private var cache: [String: String] = [:]

    public init() {}

    public func resolveGroupDirectory(for rawPath: String?, mergeToGitRoot: Bool = true) -> String? {
        guard let rawPath, !rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let standardized = (rawPath as NSString).standardizingPath
        guard mergeToGitRoot else { return standardized }
        if let hit = cache[standardized] {
            return hit
        }
        let fm = FileManager.default
        var current = URL(fileURLWithPath: standardized).resolvingSymlinksInPath()
        var steps = 0
        while current.path != "/" && steps < 16 {
            let gitPath = current.appendingPathComponent(".git").path
            if fm.fileExists(atPath: gitPath) {
                cache[standardized] = current.path
                return current.path
            }
            current.deleteLastPathComponent()
            steps += 1
        }
        cache[standardized] = standardized
        return standardized
    }
}

public enum SessionGroupingBuilder {
    public static func buildHostGroups(
        sessions: [AgentSession],
        hostStates: [HostID: HostConnectionState],
        homeByHost: [HostID: String] = [:]
    ) -> [HostSessionGroup] {
        var byHost: [HostID: [AgentSession]] = [:]
        for session in sessions {
            byHost[session.host, default: []].append(session)
        }
        for host in hostStates.keys where byHost[host] == nil {
            byHost[host] = []
        }
        let sortedHosts = byHost.keys.sorted { lhs, rhs in
            switch (lhs, rhs) {
            case (.local, .local): return false
            case (.local, _): return true
            case (_, .local): return false
            case (.ssh(let a), .ssh(let b)):
                let aOnline = hostStates[lhs]?.isOnline ?? true
                let bOnline = hostStates[rhs]?.isOnline ?? true
                if aOnline != bOnline { return aOnline && !bOnline }
                return a.localizedStandardCompare(b) == .orderedAscending
            }
        }

        return sortedHosts.compactMap { host in
            let hostSessions = byHost[host] ?? []
            let conn = hostStates[host] ?? HostConnectionState(host: host, isOnline: true)
            if hostSessions.isEmpty && host == .local {
                return HostSessionGroup(host: host, connection: conn, directories: [])
            }
            var byDir: [String?: [AgentSession]] = [:]
            for var session in hostSessions {
                if !conn.isOnline {
                    session.status = .offline
                }
                let key = session.kind.isChatOnly ? nil : (session.groupDirectory ?? session.cwd)
                byDir[key, default: []].append(session)
            }

            let home = homeByHost[host] ?? (host.isLocal ? NSHomeDirectory() : "/home")
            let dirGroups: [DirectorySessionGroup] = byDir.map { dir, list in
                let sortedSessions = list.sorted { a, b in
                    if a.status != b.status {
                        return a.status < b.status
                    }
                    return a.lastActivityAt > b.lastActivityAt
                }
                if let dir, !dir.isEmpty {
                    let name = URL(fileURLWithPath: dir).lastPathComponent
                    let abbr = FormattingHelpers.abbreviateHome(dir, home: home)
                    return DirectorySessionGroup(
                        host: host,
                        directory: dir,
                        displayName: name.isEmpty ? dir : name,
                        abbreviatedPath: abbr,
                        sessions: sortedSessions
                    )
                } else {
                    return DirectorySessionGroup(
                        host: host,
                        directory: nil,
                        displayName: "对话应用",
                        abbreviatedPath: "无工作目录",
                        sessions: sortedSessions
                    )
                }
            }.sorted { lhs, rhs in
                // Put chat apps at the bottom of the host group
                if (lhs.directory == nil) != (rhs.directory == nil) {
                    return lhs.directory != nil
                }
                if lhs.mostUrgentStatus != rhs.mostUrgentStatus {
                    return lhs.mostUrgentStatus < rhs.mostUrgentStatus
                }
                return lhs.lastActivityAt > rhs.lastActivityAt
            }

            return HostSessionGroup(host: host, connection: conn, directories: dirGroups)
        }
    }

    public static func computeMenuBarCounts(sessions: [AgentSession]) -> MenuBarCounts {
        var counts = MenuBarCounts()
        for s in sessions {
            if s.kind.isChatOnly { continue }
            switch s.status {
            case .failed:
                if !s.isSeen { counts.failed += 1 }
            case .awaitingApproval:
                counts.awaitingApproval += 1
            case .completed:
                if !s.isSeen { counts.completedUnseen += 1 }
            case .generating, .runningTool:
                counts.activeGenerating += 1
            default:
                break
            }
        }
        return counts
    }
}
