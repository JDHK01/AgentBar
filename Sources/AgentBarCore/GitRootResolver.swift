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
    public static func isSpecificProjectDirectory(
        _ rawDir: String?,
        home: String,
        isLocal: Bool
    ) -> Bool {
        guard let rawDir else { return false }
        let standardized = (rawDir as NSString).standardizingPath
        if standardized.isEmpty || standardized == "/" || standardized == "/root" {
            return false
        }
        let cleanHome = (home as NSString).standardizingPath
        if standardized == cleanHome {
            return false
        }
        let lower = standardized.lowercased()
        if lower.contains("/documents/codex/") || lower.hasSuffix("/documents/codex") {
            return false
        }
        if lower.hasSuffix("/deepseek-harness/default-workspace") {
            return false
        }
        if lower == "/tmp" || lower == "/private/tmp" || lower == "/var/tmp" || lower.hasPrefix("/private/var/folders/") {
            return false
        }

        let genericContainers: Set<String> = [
            "\(cleanHome)/Desktop",
            "\(cleanHome)/Downloads",
            "\(cleanHome)/Documents",
            "\(cleanHome)/Documents/code",
            "\(cleanHome)/code",
            "\(cleanHome)/projects",
            "\(cleanHome)/work",
            "\(cleanHome)/workspace"
        ]
        if genericContainers.contains(standardized) {
            if isLocal {
                let gitExists = FileManager.default.fileExists(atPath: (standardized as NSString).appendingPathComponent(".git"))
                if !gitExists { return false }
            } else {
                return false
            }
        }
        return true
    }

    public static func buildHostGroups(
        sessions: [AgentSession],
        hostStates: [HostID: HostConnectionState],
        homeByHost: [HostID: String] = [:],
        hostSort: HostSortOrder = .localFirst,
        projectSort: ProjectSortOrder = .priorityAndRecent,
        pinnedGroupIDs: Set<String> = [],
        customHostOrder: [String] = []
    ) -> [HostSessionGroup] {
        var byHost: [HostID: [AgentSession]] = [:]
        for session in sessions {
            byHost[session.host, default: []].append(session)
        }
        for host in hostStates.keys where byHost[host] == nil {
            byHost[host] = []
        }

        let unsortedHostGroups: [HostSessionGroup] = byHost.keys.compactMap { host in
            let hostSessions = byHost[host] ?? []
            let conn = hostStates[host] ?? HostConnectionState(host: host, isOnline: true)
            if hostSessions.isEmpty && host == .local {
                return HostSessionGroup(host: host, connection: conn, directories: [], looseSessions: [])
            }
            let home = homeByHost[host] ?? (host.isLocal ? NSHomeDirectory() : "/home")
            var byDir: [String: [AgentSession]] = [:]
            var loose: [AgentSession] = []
            for var session in hostSessions {
                if !conn.isOnline {
                    session.status = .offline
                }
                let candidateDir = session.kind.isChatOnly ? nil : (session.groupDirectory ?? session.cwd)
                if let dir = candidateDir,
                   isSpecificProjectDirectory(dir, home: home, isLocal: host.isLocal) {
                    byDir[dir, default: []].append(session)
                } else {
                    loose.append(session)
                }
            }

            let sortedLoose = loose.sorted { a, b in
                if a.status != b.status {
                    return a.status < b.status
                }
                return a.lastActivityAt > b.lastActivityAt
            }

            let dirGroups: [DirectorySessionGroup] = byDir.map { dir, list in
                let sortedSessions = list.sorted { a, b in
                    if a.status != b.status {
                        return a.status < b.status
                    }
                    return a.lastActivityAt > b.lastActivityAt
                }
                let name = URL(fileURLWithPath: dir).lastPathComponent
                let abbr = FormattingHelpers.abbreviateHome(dir, home: home)
                return DirectorySessionGroup(
                    host: host,
                    directory: dir,
                    displayName: name.isEmpty ? dir : name,
                    abbreviatedPath: abbr,
                    sessions: sortedSessions
                )
            }.sorted { lhs, rhs in
                let lPinned = pinnedGroupIDs.contains(lhs.id)
                let rPinned = pinnedGroupIDs.contains(rhs.id)
                if lPinned != rPinned {
                    return lPinned
                }
                switch projectSort {
                case .priorityAndRecent:
                    if lhs.mostUrgentStatus != rhs.mostUrgentStatus {
                        return lhs.mostUrgentStatus < rhs.mostUrgentStatus
                    }
                    return lhs.lastActivityAt > rhs.lastActivityAt
                case .recentActivity:
                    if lhs.lastActivityAt != rhs.lastActivityAt {
                        return lhs.lastActivityAt > rhs.lastActivityAt
                    }
                    return lhs.mostUrgentStatus < rhs.mostUrgentStatus
                case .tokenUsage:
                    if lhs.totalTokens != rhs.totalTokens {
                        return lhs.totalTokens > rhs.totalTokens
                    }
                    return lhs.lastActivityAt > rhs.lastActivityAt
                case .sessionCount:
                    if lhs.sessions.count != rhs.sessions.count {
                        return lhs.sessions.count > rhs.sessions.count
                    }
                    return lhs.lastActivityAt > rhs.lastActivityAt
                case .alphabetical:
                    let cmp = lhs.displayName.localizedStandardCompare(rhs.displayName)
                    if cmp != .orderedSame {
                        return cmp == .orderedAscending
                    }
                    return lhs.lastActivityAt > rhs.lastActivityAt
                }
            }

            return HostSessionGroup(host: host, connection: conn, directories: dirGroups, looseSessions: sortedLoose)
        }

        let orderIndex = Dictionary(uniqueKeysWithValues: customHostOrder.enumerated().map { ($1, $0) })
        return unsortedHostGroups.sorted { lhs, rhs in
            let lPinned = pinnedGroupIDs.contains(lhs.id)
            let rPinned = pinnedGroupIDs.contains(rhs.id)
            if lPinned != rPinned {
                return lPinned
            }

            switch hostSort {
            case .localFirst:
                if lhs.host.isLocal != rhs.host.isLocal {
                    return lhs.host.isLocal
                }
                if lhs.connection.isOnline != rhs.connection.isOnline {
                    return lhs.connection.isOnline
                }
                return lhs.host.displayTitle.localizedStandardCompare(rhs.host.displayTitle) == .orderedAscending

            case .urgentFirst:
                if lhs.connection.isOnline != rhs.connection.isOnline {
                    return lhs.connection.isOnline
                }
                if lhs.mostUrgentStatus != rhs.mostUrgentStatus {
                    return lhs.mostUrgentStatus < rhs.mostUrgentStatus
                }
                if lhs.lastActivityAt != rhs.lastActivityAt {
                    return lhs.lastActivityAt > rhs.lastActivityAt
                }
                if lhs.host.isLocal != rhs.host.isLocal {
                    return lhs.host.isLocal
                }
                return lhs.host.displayTitle.localizedStandardCompare(rhs.host.displayTitle) == .orderedAscending

            case .sessionCount:
                if lhs.connection.isOnline != rhs.connection.isOnline {
                    return lhs.connection.isOnline
                }
                if lhs.totalSessionCount != rhs.totalSessionCount {
                    return lhs.totalSessionCount > rhs.totalSessionCount
                }
                if lhs.host.isLocal != rhs.host.isLocal {
                    return lhs.host.isLocal
                }
                return lhs.host.displayTitle.localizedStandardCompare(rhs.host.displayTitle) == .orderedAscending

            case .customOrder:
                let li = orderIndex[lhs.id] ?? Int.max
                let ri = orderIndex[rhs.id] ?? Int.max
                if li != ri {
                    return li < ri
                }
                if lhs.host.isLocal != rhs.host.isLocal {
                    return lhs.host.isLocal
                }
                return lhs.host.displayTitle.localizedStandardCompare(rhs.host.displayTitle) == .orderedAscending
            }
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
