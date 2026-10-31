import Foundation
import SQLite3
import XCTest

@testable import PIiOSCore

final class OfflineSessionCacheSQLiteTests: XCTestCase {
    private var directory: URL!
    private var databaseURL: URL { directory.appendingPathComponent("cache.sqlite") }
    private let hostA = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let hostB = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testRoundTripsAllFiveTablesAndMetadata() throws {
        let payload = JSONValue.object([
            "id": .string("apr_1"),
            "kind": .string("tool"),
            "summary": .string("safe summary"),
        ])
        let snapshot = OfflineSessionCacheSnapshot(
            sessions: [
                OfflineSessionCacheSession(
                    hostID: hostA,
                    id: "ses_1",
                    title: "Session",
                    projectID: "prj_1",
                    mode: "agent",
                    permissionMode: "ask",
                    modelID: "deepseek-flash",
                    providerID: "deepseek",
                    epoch: "ep_1",
                    sequence: 42,
                    updatedAt: base.addingTimeInterval(5)
                ),
            ],
            entries: [
                OfflineSessionCacheEntry(
                    id: "itm_1",
                    sessionId: "ses_1",
                    hostID: hostA,
                    text: "hello",
                    createdAt: base.addingTimeInterval(1),
                    kind: "message",
                    role: "assistant",
                    toolName: nil,
                    status: "completed",
                    epoch: "ep_1",
                    sequence: 40
                ),
            ],
            cursors: [
                OfflineSessionCursor(
                    hostID: hostA,
                    sessionId: "ses_1",
                    epoch: "ep_1",
                    sequence: 42,
                    updatedAt: base.addingTimeInterval(2)
                ),
            ],
            approvals: [
                OfflineSessionApproval(
                    id: "apr_1",
                    sessionId: "ses_1",
                    hostID: hostA,
                    payload: payload,
                    revision: 7,
                    status: "pending",
                    decision: nil,
                    createdAt: base.addingTimeInterval(3)
                ),
            ],
            drafts: [
                OfflineSessionDraft(
                    hostID: hostA,
                    sessionId: "ses_1",
                    text: "unsent",
                    idempotencyKey: "turn_stable",
                    updatedAt: base.addingTimeInterval(4)
                ),
            ]
        )

        let database = try OfflineSessionCacheSQLite(url: databaseURL)
        try database.save(snapshot)

        XCTAssertEqual(try database.loadSnapshot(), snapshot)
        XCTAssertEqual(
            try database.loadSnapshot().cachedSessionMetadata(hostID: hostA, sessionID: "ses_1")?.modelID,
            "deepseek-flash"
        )
        XCTAssertEqual(try tableNames(), ["approvals", "cursors", "drafts", "items", "sessions"])
        XCTAssertEqual(
            try databaseURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup,
            true
        )
    }

    func testHostCompositeKeysKeepSameIDsSeparateAndRemoveOnlyTargetHost() throws {
        let snapshot = OfflineSessionCacheSnapshot(
            sessions: [
                session("ses_1", host: hostA, title: "A"),
                session("ses_1", host: hostB, title: "B"),
            ],
            entries: [
                entry("itm_1", session: "ses_1", host: hostA, text: "A"),
                entry("itm_1", session: "ses_1", host: hostB, text: "B"),
            ],
            cursors: [
                OfflineSessionCursor(hostID: hostA, sessionId: "ses_1", epoch: "a", sequence: 1, updatedAt: base),
                OfflineSessionCursor(hostID: hostB, sessionId: "ses_1", epoch: "b", sequence: 2, updatedAt: base),
            ],
            approvals: [
                approval("apr_1", host: hostA),
                approval("apr_1", host: hostB),
            ],
            drafts: [
                draft("ses_1", host: hostA, text: "A"),
                draft("ses_1", host: hostB, text: "B"),
            ]
        )

        let database = try OfflineSessionCacheSQLite(url: databaseURL)
        try database.save(snapshot)
        var loaded = try database.loadSnapshot()
        XCTAssertEqual(loaded.sessions.count, 2)
        XCTAssertEqual(loaded.entries.count, 2)
        XCTAssertEqual(loaded.cursors.count, 2)
        XCTAssertEqual(loaded.approvals.count, 2)
        XCTAssertEqual(loaded.drafts.count, 2)

        try database.removeHost(hostA)
        loaded = try database.loadSnapshot()
        XCTAssertEqual(loaded.sessions.map(\.hostID), [hostB])
        XCTAssertEqual(loaded.entries.map(\.hostID), [hostB])
        XCTAssertEqual(loaded.cursors.map(\.hostID), [hostB])
        XCTAssertEqual(loaded.approvals.map(\.hostID), [hostB])
        XCTAssertEqual(loaded.drafts.map(\.hostID), [hostB])
    }

    func testCorruptDatabaseIsRejectedAndNotOverwritten() throws {
        let original = Data("not a sqlite database".utf8)
        try original.write(to: databaseURL)

        XCTAssertThrowsError(try OfflineSessionCacheSQLite(url: databaseURL))
        XCTAssertEqual(try Data(contentsOf: databaseURL), original)
    }

    func testLegacyJSONMigrationIsOneWayIdempotentAndPreservesAllTables() throws {
        let legacyURL = directory.appendingPathComponent("session-cache-v1.json")
        let snapshot = OfflineSessionCacheSnapshot(
            sessions: [session("ses_1", host: hostA, title: "Migrated")],
            entries: [entry("itm_1", session: "ses_1", host: hostA, text: "old")],
            cursors: [
                OfflineSessionCursor(
                    hostID: hostA,
                    sessionId: "ses_1",
                    epoch: "ep_old",
                    sequence: 9,
                    updatedAt: base
                ),
            ],
            approvals: [approval("apr_1", host: hostA)],
            drafts: [draft("ses_1", host: hostA, text: "unsent")]
        )
        try OfflineSessionCacheFile.save(
            OfflineSessionCacheDocument(snapshot: snapshot),
            to: legacyURL
        )

        let migrated = try OfflineSessionCacheSQLite.migrateLegacyJSON(
            from: legacyURL,
            to: databaseURL
        )
        XCTAssertEqual(migrated, snapshot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
        XCTAssertEqual(try OfflineSessionCacheSQLite(url: databaseURL).loadSnapshot(), snapshot)

        // Repeating migration after success reads the database and does not fail
        // just because the legacy file is gone.
        XCTAssertEqual(
            try OfflineSessionCacheSQLite.migrateLegacyJSON(
                from: legacyURL,
                to: databaseURL
            ),
            snapshot
        )
    }

    func testCorruptLegacyJSONLeavesNoHalfDatabase() throws {
        let legacyURL = directory.appendingPathComponent("session-cache-v1.json")
        let original = Data("not-json".utf8)
        try original.write(to: legacyURL)

        XCTAssertThrowsError(
            try OfflineSessionCacheSQLite.migrateLegacyJSON(
                from: legacyURL,
                to: databaseURL
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path))
        XCTAssertEqual(try Data(contentsOf: legacyURL), original)
    }

    private func session(
        _ id: String,
        host: UUID,
        title: String
    ) -> OfflineSessionCacheSession {
        OfflineSessionCacheSession(
            hostID: host,
            id: id,
            title: title,
            projectID: nil,
            mode: "agent",
            permissionMode: "ask",
            modelID: nil,
            providerID: nil,
            epoch: nil,
            sequence: nil,
            updatedAt: base
        )
    }

    private func entry(
        _ id: String,
        session: String,
        host: UUID,
        text: String
    ) -> OfflineSessionCacheEntry {
        OfflineSessionCacheEntry(
            id: id,
            sessionId: session,
            hostID: host,
            text: text,
            createdAt: base
        )
    }

    private func approval(_ id: String, host: UUID) -> OfflineSessionApproval {
        OfflineSessionApproval(
            id: id,
            sessionId: "ses_1",
            hostID: host,
            payload: .object(["id": .string(id)]),
            revision: 1,
            status: "pending",
            decision: nil,
            createdAt: base
        )
    }

    private func draft(_ session: String, host: UUID, text: String) -> OfflineSessionDraft {
        OfflineSessionDraft(
            hostID: host,
            sessionId: session,
            text: text,
            idempotencyKey: "key_\(text)",
            updatedAt: base
        )
    }

    private func tableNames() throws -> [String] {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(
                handle,
                "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
                -1,
                &statement,
                nil
            ),
            SQLITE_OK
        )
        defer { sqlite3_finalize(statement) }
        var names: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0) {
                names.append(String(cString: text))
            }
        }
        return names
    }
}
