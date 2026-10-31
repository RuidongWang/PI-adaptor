import Foundation
import SQLite3

public enum OfflineSessionCacheSQLiteError: Error, LocalizedError {
    case decryptionFailed
    case migrationIncomplete

    public var errorDescription: String? {
        switch self {
        case .decryptionFailed:
            return "离线缓存敏感字段解密失败（Keychain 不可用或密钥失效），已阻止以空值覆盖原缓存"
        case .migrationIncomplete:
            return "旧版缓存迁移未完成"
        }
    }
}

/// C-4 的 SQLite 落盘实现。
///
/// 表的主键使用 `(host_id, ...)` 复合键。契约表格只写了逻辑主键 `id`，
/// 但同一份本地库必须同时保存多个 Host；若只按 `id` 建主键，A/B 两个
/// Host 的同名 session/item/approval 会互相覆盖，违反 AC-18.3。
public final class OfflineSessionCacheSQLite {
    public struct DatabaseError: Error, CustomStringConvertible, Equatable {
        public let message: String
        public var description: String { message }
    }

    private var database: OpaquePointer?
    private let lock = NSLock()

    public init(url: URL) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard result == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) }
                ?? "sqlite3_open_v2 failed (\(result))"
            if let handle { sqlite3_close(handle) }
            throw DatabaseError(message: message)
        }
        database = handle
        sqlite3_busy_timeout(handle, 5_000)
        do {
            try execute("PRAGMA journal_mode=DELETE")
            try execute("PRAGMA synchronous=FULL")
            try execute("PRAGMA secure_delete=ON")
            try migrate()
            Self.applyFileProtection(to: url)
        } catch {
            sqlite3_close(handle)
            database = nil
            throw error
        }
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    /// One-way, fail-closed migration from the pre-C-4 JSON cache.
    ///
    /// The legacy file is removed only after the SQLite transaction commits, is verified,
    /// and moved atomically into place. If migration is interrupted, recovery falls back to
    /// the preserved legacy JSON instead of obscuring it with an empty/corrupted database.
    public static func migrateLegacyJSON(
        from legacyURL: URL,
        to databaseURL: URL
    ) throws -> OfflineSessionCacheSnapshot {
        let legacyExists = FileManager.default.fileExists(atPath: legacyURL.path)
        let dbExists = FileManager.default.fileExists(atPath: databaseURL.path)

        if dbExists && !legacyExists {
            return try OfflineSessionCacheSQLite(url: databaseURL).loadSnapshot()
        }

        // If legacy JSON still exists alongside databaseURL, check if databaseURL was left
        // incomplete from a previous interrupted migration attempt.
        if dbExists && legacyExists {
            if let existing = try? OfflineSessionCacheSQLite(url: databaseURL).loadSnapshot(),
               (!existing.sessions.isEmpty || !existing.entries.isEmpty) {
                try? FileManager.default.removeItem(at: legacyURL)
                return existing
            }
            try? FileManager.default.removeItem(at: databaseURL)
        }

        guard let document = try OfflineSessionCacheFile.load(from: legacyURL) else {
            return OfflineSessionCacheSnapshot()
        }

        let tempURL = databaseURL.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).migration.tmp")
        try? FileManager.default.removeItem(at: tempURL)

        do {
            let database = try OfflineSessionCacheSQLite(url: tempURL)
            try database.save(document.snapshot)
            let verified = try database.loadSnapshot()
            guard verified.sessions.count == document.snapshot.sessions.count,
                  verified.entries.count == document.snapshot.entries.count
            else {
                throw OfflineSessionCacheSQLiteError.migrationIncomplete
            }
            if FileManager.default.fileExists(atPath: databaseURL.path) {
                _ = try FileManager.default.replaceItemAt(databaseURL, withItemAt: tempURL)
            } else {
                try FileManager.default.moveItem(at: tempURL, to: databaseURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
        try FileManager.default.removeItem(at: legacyURL)
        return document.snapshot
    }

    public func loadSnapshot() throws -> OfflineSessionCacheSnapshot {
        lock.lock()
        defer { lock.unlock() }
        try requireDatabase()
        return OfflineSessionCacheSnapshot(
            sessions: try loadSessions(),
            entries: try loadItems(),
            cursors: try loadCursors(),
            approvals: try loadApprovals(),
            drafts: try loadDrafts()
        )
    }

    public func save(_ snapshot: OfflineSessionCacheSnapshot) throws {
        lock.lock()
        defer { lock.unlock() }
        try requireDatabase()
        try execute("BEGIN IMMEDIATE")
        do {
            for table in ["sessions", "items", "cursors", "approvals", "drafts"] {
                try execute("DELETE FROM \(table)")
            }
            try insertSessions(snapshot.sessions)
            try insertItems(snapshot.entries)
            try insertCursors(snapshot.cursors)
            try insertApprovals(snapshot.approvals)
            try insertDrafts(snapshot.drafts)
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func removeHost(_ hostID: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        try requireDatabase()
        let host = hostID.uuidString
        try execute("BEGIN IMMEDIATE")
        do {
            for table in ["sessions", "items", "cursors", "approvals", "drafts"] {
                try execute("DELETE FROM \(table) WHERE host_id = ?", bindings: [.text(host)])
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    // MARK: - Schema

    private func migrate() throws {
        try execute("""
            CREATE TABLE IF NOT EXISTS sessions (
                host_id TEXT NOT NULL,
                id TEXT NOT NULL,
                title TEXT,
                project_id TEXT,
                mode TEXT,
                permission_mode TEXT,
                model_id TEXT,
                provider_id TEXT,
                epoch TEXT,
                sequence INTEGER,
                updated_at REAL NOT NULL,
                PRIMARY KEY (host_id, id)
            )
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS items (
                host_id TEXT NOT NULL,
                id TEXT NOT NULL,
                session_id TEXT NOT NULL,
                kind TEXT,
                role TEXT,
                text TEXT NOT NULL,
                tool_name TEXT,
                status TEXT,
                epoch TEXT,
                sequence INTEGER,
                created_at REAL NOT NULL,
                PRIMARY KEY (host_id, session_id, id)
            )
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS cursors (
                host_id TEXT NOT NULL,
                session_id TEXT NOT NULL,
                epoch TEXT NOT NULL,
                sequence INTEGER NOT NULL,
                updated_at REAL NOT NULL,
                PRIMARY KEY (host_id, session_id)
            )
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS approvals (
                host_id TEXT NOT NULL,
                id TEXT NOT NULL,
                session_id TEXT NOT NULL,
                payload TEXT NOT NULL,
                status TEXT NOT NULL,
                revision INTEGER,
                decision TEXT,
                created_at REAL NOT NULL,
                PRIMARY KEY (host_id, session_id, id)
            )
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS drafts (
                host_id TEXT NOT NULL,
                session_id TEXT NOT NULL,
                text TEXT NOT NULL,
                idempotency_key TEXT NOT NULL,
                updated_at REAL NOT NULL,
                PRIMARY KEY (host_id, session_id)
            )
            """)
        try execute("PRAGMA user_version=1")
    }

    // MARK: - Reads

    private func loadSessions() throws -> [OfflineSessionCacheSession] {
        try query("""
            SELECT host_id, id, title, project_id, mode, permission_mode,
                   model_id, provider_id, epoch, sequence, updated_at
            FROM sessions
            """) { statement in
            let rawTitle = text(statement, 2)
            let title: String?
            if let rawTitle {
                guard let decrypted = OfflineCacheCipher.openOrNil(rawTitle) else {
                    throw OfflineSessionCacheSQLiteError.decryptionFailed
                }
                title = decrypted
            } else {
                title = nil
            }
            return OfflineSessionCacheSession(
                hostID: Self.hostID(text(statement, 0)),
                id: text(statement, 1) ?? "",
                title: title,
                projectID: text(statement, 3),
                mode: text(statement, 4),
                permissionMode: text(statement, 5),
                modelID: text(statement, 6),
                providerID: text(statement, 7),
                epoch: text(statement, 8),
                sequence: integer(statement, 9),
                updatedAt: date(statement, 10)
            )
        }
    }

    private func loadItems() throws -> [OfflineSessionCacheEntry] {
        try query("""
            SELECT host_id, id, session_id, kind, role, text, tool_name,
                   status, epoch, sequence, created_at
            FROM items
            """) { statement in
            let rawText = text(statement, 5) ?? ""
            guard let itemText = OfflineCacheCipher.openOrNil(rawText) else {
                throw OfflineSessionCacheSQLiteError.decryptionFailed
            }
            return OfflineSessionCacheEntry(
                id: text(statement, 1) ?? "",
                sessionId: text(statement, 2) ?? "",
                hostID: Self.hostID(text(statement, 0)),
                text: itemText,
                createdAt: date(statement, 10),
                kind: text(statement, 3),
                role: text(statement, 4),
                toolName: text(statement, 6),
                status: text(statement, 7),
                epoch: text(statement, 8),
                sequence: integer(statement, 9)
            )
        }
    }

    private func loadCursors() throws -> [OfflineSessionCursor] {
        try query("""
            SELECT host_id, session_id, epoch, sequence, updated_at FROM cursors
            """) { statement in
            OfflineSessionCursor(
                hostID: Self.hostID(text(statement, 0)),
                sessionId: text(statement, 1) ?? "",
                epoch: text(statement, 2) ?? "",
                sequence: Int(integer(statement, 3) ?? 0),
                updatedAt: date(statement, 4)
            )
        }
    }

    private func loadApprovals() throws -> [OfflineSessionApproval] {
        try query("""
            SELECT host_id, id, session_id, payload, status, revision,
                   decision, created_at
            FROM approvals
            """) { statement in
            let rawPayload = text(statement, 3) ?? "null"
            guard let payloadText = OfflineCacheCipher.openOrNil(rawPayload) else {
                throw OfflineSessionCacheSQLiteError.decryptionFailed
            }
            let payload = (try? JSONDecoder().decode(
                JSONValue.self,
                from: Data(payloadText.utf8)
            )) ?? .null
            return OfflineSessionApproval(
                id: text(statement, 1) ?? "",
                sessionId: text(statement, 2) ?? "",
                hostID: Self.hostID(text(statement, 0)),
                payload: payload,
                revision: integer(statement, 5),
                status: text(statement, 4) ?? "",
                decision: text(statement, 6),
                createdAt: date(statement, 7)
            )
        }
    }

    private func loadDrafts() throws -> [OfflineSessionDraft] {
        try query("""
            SELECT host_id, session_id, text, idempotency_key, updated_at FROM drafts
            """) { statement in
            let rawDraft = text(statement, 2) ?? ""
            guard let draftText = OfflineCacheCipher.openOrNil(rawDraft) else {
                throw OfflineSessionCacheSQLiteError.decryptionFailed
            }
            return OfflineSessionDraft(
                hostID: Self.hostID(text(statement, 0)),
                sessionId: text(statement, 1) ?? "",
                text: draftText,
                idempotencyKey: text(statement, 3) ?? "",
                updatedAt: date(statement, 4)
            )
        }
    }

    // MARK: - Writes

    private func insertSessions(_ sessions: [OfflineSessionCacheSession]) throws {
        for session in sessions {
            try execute("""
                INSERT INTO sessions
                    (host_id, id, title, project_id, mode, permission_mode,
                     model_id, provider_id, epoch, sequence, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, bindings: [
                    .text(Self.hostID(session.hostID)),
                    .text(session.id),
                    .optionalText(OfflineCacheCipher.seal(optional: session.title)),
                    .optionalText(session.projectID),
                    .optionalText(session.mode),
                    .optionalText(session.permissionMode),
                    .optionalText(session.modelID),
                    .optionalText(session.providerID),
                    .optionalText(session.epoch),
                    .optionalInt(session.sequence),
                    .real(session.updatedAt.timeIntervalSince1970),
                ])
        }
    }

    private func insertItems(_ entries: [OfflineSessionCacheEntry]) throws {
        for entry in entries {
            try execute("""
                INSERT INTO items
                    (host_id, id, session_id, kind, role, text, tool_name,
                     status, epoch, sequence, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, bindings: [
                    .text(Self.hostID(entry.hostID)),
                    .text(entry.id),
                    .text(entry.sessionId),
                    .optionalText(entry.kind),
                    .optionalText(entry.role),
                    .text(OfflineCacheCipher.seal(entry.text)),
                    .optionalText(entry.toolName),
                    .optionalText(entry.status),
                    .optionalText(entry.epoch),
                    .optionalInt(entry.sequence),
                    .real(entry.createdAt.timeIntervalSince1970),
                ])
        }
    }

    private func insertCursors(_ cursors: [OfflineSessionCursor]) throws {
        for cursor in cursors {
            try execute("""
                INSERT INTO cursors
                    (host_id, session_id, epoch, sequence, updated_at)
                VALUES (?, ?, ?, ?, ?)
                """, bindings: [
                    .text(Self.hostID(cursor.hostID)),
                    .text(cursor.sessionId),
                    .text(cursor.epoch),
                    .integer(cursor.sequence),
                    .real(cursor.updatedAt.timeIntervalSince1970),
                ])
        }
    }

    private func insertApprovals(_ approvals: [OfflineSessionApproval]) throws {
        for approval in approvals {
            let payloadData = try JSONEncoder().encode(approval.payload)
            let payload = String(decoding: payloadData, as: UTF8.self)
            try execute("""
                INSERT INTO approvals
                    (host_id, id, session_id, payload, status, revision,
                     decision, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, bindings: [
                    .text(Self.hostID(approval.hostID)),
                    .text(approval.id),
                    .text(approval.sessionId),
                    .text(OfflineCacheCipher.seal(payload)),
                    .text(approval.status),
                    .optionalInt(approval.revision),
                    .optionalText(approval.decision),
                    .real(approval.createdAt.timeIntervalSince1970),
                ])
        }
    }

    private func insertDrafts(_ drafts: [OfflineSessionDraft]) throws {
        for draft in drafts {
            try execute("""
                INSERT INTO drafts
                    (host_id, session_id, text, idempotency_key, updated_at)
                VALUES (?, ?, ?, ?, ?)
                """, bindings: [
                    .text(Self.hostID(draft.hostID)),
                    .text(draft.sessionId),
                    .text(OfflineCacheCipher.seal(draft.text)),
                    .text(draft.idempotencyKey),
                    .real(draft.updatedAt.timeIntervalSince1970),
                ])
        }
    }

    // MARK: - SQLite helpers

    private enum Binding {
        case text(String)
        case optionalText(String?)
        case integer(Int)
        case optionalInt(Int?)
        case real(TimeInterval)
    }

    private func requireDatabase() throws {
        guard database != nil else {
            throw DatabaseError(message: "database is closed")
        }
    }

    private func execute(_ sql: String, bindings: [Binding] = []) throws {
        guard let database else { throw DatabaseError(message: "database is closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw DatabaseError(message: String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement, database: database)
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw DatabaseError(message: String(cString: sqlite3_errmsg(database)))
        }
    }

    private func query<T>(
        _ sql: String,
        _ row: (OpaquePointer) throws -> T
    ) throws -> [T] {
        guard let database else { throw DatabaseError(message: "database is closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw DatabaseError(message: String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        var rows: [T] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                rows.append(try row(statement))
            case SQLITE_DONE:
                return rows
            default:
                throw DatabaseError(message: String(cString: sqlite3_errmsg(database)))
            }
        }
    }

    private func bind(
        _ bindings: [Binding],
        to statement: OpaquePointer,
        database: OpaquePointer
    ) throws {
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch binding {
            case .text(let value):
                result = sqlite3_bind_text(statement, index, value, -1, Self.sqliteTransient)
            case .optionalText(let value):
                result = value.map {
                    sqlite3_bind_text(statement, index, $0, -1, Self.sqliteTransient)
                } ?? sqlite3_bind_null(statement, index)
            case .integer(let value):
                result = sqlite3_bind_int64(statement, index, sqlite3_int64(value))
            case .optionalInt(let value):
                result = value.map {
                    sqlite3_bind_int64(statement, index, sqlite3_int64($0))
                } ?? sqlite3_bind_null(statement, index)
            case .real(let value):
                result = sqlite3_bind_double(statement, index, value)
            }
            guard result == SQLITE_OK else {
                throw DatabaseError(message: String(cString: sqlite3_errmsg(database)))
            }
        }
    }

    private static let sqliteTransient = unsafeBitCast(
        -1,
        to: sqlite3_destructor_type.self
    )

    private static func hostID(_ value: String?) -> UUID? {
        guard let value, value != "none" else { return nil }
        return UUID(uuidString: value)
    }

    private static func hostID(_ hostID: UUID?) -> String {
        hostID?.uuidString ?? "none"
    }

    private static func applyFileProtection(to url: URL) {
#if os(iOS)
        for protectedURL in [url.deletingLastPathComponent(), url] {
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUnlessOpen],
                ofItemAtPath: protectedURL.path
            )
        }
#endif
        var resourceURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? resourceURL.setResourceValues(values)
    }
}

private func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL,
          let pointer = sqlite3_column_text(statement, index)
    else { return nil }
    return String(cString: pointer)
}

private func integer(_ statement: OpaquePointer, _ index: Int32) -> Int? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
    return Int(sqlite3_column_int64(statement, index))
}

private func date(_ statement: OpaquePointer, _ index: Int32) -> Date {
    Date(timeIntervalSince1970: sqlite3_column_double(statement, index))
}
