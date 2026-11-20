import Foundation
import SQLite3

public enum CursorTraeAdapter {
    public static func loadLocalSessions(
        homeDirectory: String = NSHomeDirectory(),
        lookbackHours: Double = 96,
        seenAtByID: [String: TimeInterval] = [:]
    ) async -> [AgentSession] {
        var all: [AgentSession] = []
        let cursorDB = (homeDirectory as NSString)
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        let cursorWorkspaceRoot = (homeDirectory as NSString)
            .appendingPathComponent("Library/Application Support/Cursor/User/workspaceStorage")
        all.append(contentsOf: await readStateDB(
            dbPath: cursorDB,
            workspaceStorageRoot: cursorWorkspaceRoot,
            kind: .cursor,
            lookbackHours: lookbackHours,
            seenAtByID: seenAtByID
        ))

        for folderName in ["Trae", "Trae CN"] {
            let traeDB = (homeDirectory as NSString)
                .appendingPathComponent("Library/Application Support/\(folderName)/User/globalStorage/state.vscdb")
            let traeWS = (homeDirectory as NSString)
                .appendingPathComponent("Library/Application Support/\(folderName)/User/workspaceStorage")
            all.append(contentsOf: await readStateDB(
                dbPath: traeDB,
                workspaceStorageRoot: traeWS,
                kind: .trae,
                lookbackHours: lookbackHours,
                seenAtByID: seenAtByID
            ))
        }
        return all
    }

    private static func readRecentWorkspaceFolder(root: String) -> String? {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(
            at: URL(fileURLWithPath: root),
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        let sorted = dirs.sorted {
            let d1 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let d2 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return d1 > d2
        }
        for dir in sorted.prefix(10) {
            let wsFile = dir.appendingPathComponent("workspace.json")
            guard let data = try? Data(contentsOf: wsFile),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let folderURI = obj["folder"] as? String,
                  let url = URL(string: folderURI),
                  url.isFileURL else {
                continue
            }
            return url.path
        }
        return nil
    }

    private static func readStateDB(
        dbPath: String,
        workspaceStorageRoot: String,
        kind: AgentKind,
        lookbackHours: Double,
        seenAtByID: [String: TimeInterval]
    ) async -> [AgentSession] {
        guard FileManager.default.fileExists(atPath: dbPath) else { return [] }
        let fallbackWorkspace = readRecentWorkspaceFolder(root: workspaceStorageRoot)
        let cutoff = Date().addingTimeInterval(-lookbackHours * 3600)

        var db: OpaquePointer?
        let uri = "file:\(dbPath)?immutable=1"
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(uri, &db, flags, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return []
        }
        defer { sqlite3_close(db) }

        let sql = "SELECT key, value FROM cursorDiskKV WHERE key LIKE 'composerData:%' LIMIT 60;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return []
        }
        defer { sqlite3_finalize(stmt) }

        var sessions: [AgentSession] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let keyPtr = sqlite3_column_text(stmt, 0),
                  let valPtr = sqlite3_column_text(stmt, 1) else {
                continue
            }
            let key = String(cString: keyPtr)
            if key.hasSuffix("empty-state-draft") { continue }
            let jsonStr = String(cString: valPtr)
            guard let data = jsonStr.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            let rawID = (obj["composerId"] as? String) ?? String(key.dropFirst("composerData:".count))
            let name = (obj["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let headers = (obj["fullConversationHeadersOnly"] as? [[String: Any]]) ?? []
            let textDraft = (obj["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if (name == nil || name?.isEmpty == true) && headers.isEmpty && (textDraft == nil || textDraft?.isEmpty == true) {
                continue
            }

            let createdMs = (obj["createdAt"] as? Double) ?? 0
            let updatedMs = (obj["lastUpdatedAt"] as? Double) ?? createdMs
            let updatedAt = updatedMs > 0
                ? Date(timeIntervalSince1970: updatedMs / 1000.0)
                : Date()
            if updatedAt < cutoff { continue }

            var modelName: String?
            if let mc = obj["modelConfig"] as? [String: Any] {
                modelName = mc["modelName"] as? String
            }
            let generatingBubbles = (obj["generatingBubbleIds"] as? [Any]) ?? []
            let rawStatus = (obj["status"] as? String) ?? "none"
            let sessionID = "local:\(kind.rawValue):\(rawID)"
            let isSeen = SeenSessionLookup.isSeen(
                sessionID: sessionID,
                lastActivityAt: updatedAt,
                seenAtByID: seenAtByID
            )

            let status: SessionStatus
            if !generatingBubbles.isEmpty || rawStatus == "generating" {
                status = .generating
            } else if !isSeen && Date().timeIntervalSince(updatedAt) < 1800 && !headers.isEmpty {
                status = .completed
            } else {
                status = .waitingForInput
            }

            let title = (name?.isEmpty == false ? name! : nil)
                ?? (textDraft?.isEmpty == false ? ClaudeCodeAdapter.firstSingleLine(textDraft!, maxLength: 40) : "\(kind.displayName) 会话")
            let subtitle = (obj["subtitle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let overview = (subtitle?.isEmpty == false ? subtitle! : "共 \(max(1, headers.count)) 条对话消息")
            let groupDir = await GitRootResolver.shared.resolveGroupDirectory(for: fallbackWorkspace)

            sessions.append(AgentSession(
                id: sessionID,
                rawSessionID: rawID,
                kind: kind,
                host: .local,
                title: title,
                overview: overview,
                status: status,
                cwd: fallbackWorkspace,
                groupDirectory: groupDir,
                provider: FormattingHelpers.providerDisplay(from: modelName),
                model: modelName,
                turnCount: max(1, headers.count / 2),
                sourceFilePath: dbPath,
                startedAt: createdMs > 0 ? Date(timeIntervalSince1970: createdMs / 1000.0) : updatedAt,
                lastActivityAt: updatedAt,
                isSeen: isSeen
            ))
        }
        return sessions
    }
}
