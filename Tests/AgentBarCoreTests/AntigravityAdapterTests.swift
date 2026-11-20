import Foundation
import SQLite3
import XCTest
@testable import AgentBarCore

final class AntigravityAdapterTests: XCTestCase {
    func testLoadsRecentSummaryFromWAL() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = home.appendingPathComponent(".gemini/antigravity")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let database = directory.appendingPathComponent("conversation_summaries.db")
        var handle: OpaquePointer?
        let result = sqlite3_open(database.path, &handle)
        defer { sqlite3_close(handle) }
        XCTAssertEqual(result, SQLITE_OK)
        let db = try XCTUnwrap(handle)
        let sql = """
            PRAGMA journal_mode = WAL;
            CREATE TABLE conversation_summaries (
                conversation_id TEXT PRIMARY KEY, title TEXT, preview TEXT,
                workspace_uris TEXT, last_modified_time DATETIME
            );
            INSERT INTO conversation_summaries VALUES
                ('recent', 'Recent chat', 'A preview', '["file:///tmp/My%20Project"]', datetime('now')),
                ('old', 'Old chat', '', '', datetime('now', '-7 days'));
            """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)

        let sessions = await AntigravityAdapter.loadLocalSessions(
            homeDirectory: home.path,
            lookbackHours: 24,
            seenSessionIDs: ["local:antigravity:recent"]
        )
        XCTAssertEqual(sessions.count, 1)
        let session = try XCTUnwrap(sessions.first)
        XCTAssertEqual(session.kind, .antigravity)
        XCTAssertEqual(session.id, "local:antigravity:recent")
        XCTAssertEqual(session.title, "Recent chat")
        XCTAssertEqual(session.overview, "A preview")
        XCTAssertEqual(session.cwd, "/tmp/My Project")
        XCTAssertTrue(session.isSeen)

        let cards = SubscriptionAndStatsService.detectLocalSubscriptions(
            homeDirectory: home.path,
            sessions: sessions
        )
        let card = try XCTUnwrap(cards.first { $0.kind == .antigravity })
        XCTAssertEqual(card.providerTitle, "Google · Antigravity")
        XCTAssertEqual(card.subtitle, "1 个近期会话 · 暂无额度数据")
        XCTAssertTrue(card.quotas.isEmpty)
    }
}
