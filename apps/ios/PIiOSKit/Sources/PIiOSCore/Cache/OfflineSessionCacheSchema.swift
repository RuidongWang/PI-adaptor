import Foundation

/// 会话断线续传游标在本地缓存中的一行（契约 §6 `cursors`）。
public struct OfflineSessionCursor: Codable, Equatable, Sendable {
    public var hostID: UUID?
    public var sessionId: String
    public var epoch: String
    public var sequence: Int
    public var updatedAt: Date

    public init(
        hostID: UUID?,
        sessionId: String,
        epoch: String,
        sequence: Int,
        updatedAt: Date
    ) {
        self.hostID = hostID
        self.sessionId = sessionId
        self.epoch = epoch
        self.sequence = sequence
        self.updatedAt = updatedAt
    }
}

/// 离线展示用的待审批卡（契约 §6 `approvals`）。
///
/// `revision` 与 `status` 必须单独落列，不能只依赖未冻结的 `payload`：
/// 恢复在线后 Host 会用快照重新生成卡片，离线缓存里的这张卡永远不能被当作可提交状态。
public struct OfflineSessionApproval: Codable, Equatable, Sendable {
    public var id: String
    public var sessionId: String
    public var hostID: UUID?
    public var payload: JSONValue
    public var revision: Int?
    public var status: String
    public var decision: String?
    public var createdAt: Date

    public init(
        id: String,
        sessionId: String,
        hostID: UUID?,
        payload: JSONValue,
        revision: Int?,
        status: String,
        decision: String?,
        createdAt: Date
    ) {
        self.id = id
        self.sessionId = sessionId
        self.hostID = hostID
        self.payload = payload
        self.revision = revision
        self.status = status
        self.decision = decision
        self.createdAt = createdAt
    }

    /// 离线缓存从不提供可提交动作；恢复在线后只能使用快照里的新卡。
    public var isActionable: Bool { false }

    public var offlineStatusText: String {
        let normalized = status.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty
            ? "离线只读 · 可能已过期"
            : "离线只读 · 可能已过期（\(normalized)）"
    }
}

/// 未发送草稿（契约 §6 `drafts`）。保存幂等键是为了超时重试仍能复用同一次发送。
public struct OfflineSessionDraft: Codable, Equatable, Sendable {
    public var hostID: UUID?
    public var sessionId: String
    public var text: String
    public var idempotencyKey: String
    public var updatedAt: Date

    public init(
        hostID: UUID?,
        sessionId: String,
        text: String,
        idempotencyKey: String,
        updatedAt: Date
    ) {
        self.hostID = hostID
        self.sessionId = sessionId
        self.text = text
        self.idempotencyKey = idempotencyKey
        self.updatedAt = updatedAt
    }
}

/// 单个会话的离线只读视图。Host 未确定时不会返回任何行。
public struct OfflineCachedSession: Equatable, Sendable {
    public var entries: [OfflineSessionCacheEntry]
    public var cursor: OfflineSessionCursor?
    public var approvals: [OfflineSessionApproval]
    public var draft: OfflineSessionDraft?

    public init(
        entries: [OfflineSessionCacheEntry],
        cursor: OfflineSessionCursor?,
        approvals: [OfflineSessionApproval],
        draft: OfflineSessionDraft?
    ) {
        self.entries = entries
        self.cursor = cursor
        self.approvals = approvals
        self.draft = draft
    }
}

/// 本地 JSON 缓存里除 `items` 外的全部契约表。
public struct OfflineSessionCacheSnapshot: Codable, Equatable, Sendable {
    public var sessions: [OfflineSessionCacheSession]
    public var entries: [OfflineSessionCacheEntry]
    public var cursors: [OfflineSessionCursor]
    public var approvals: [OfflineSessionApproval]
    public var drafts: [OfflineSessionDraft]

    public init(
        sessions: [OfflineSessionCacheSession] = [],
        entries: [OfflineSessionCacheEntry] = [],
        cursors: [OfflineSessionCursor] = [],
        approvals: [OfflineSessionApproval] = [],
        drafts: [OfflineSessionDraft] = []
    ) {
        self.sessions = sessions
        self.entries = entries
        self.cursors = cursors
        self.approvals = approvals
        self.drafts = drafts
    }

    private enum CodingKeys: String, CodingKey {
        case sessions, entries, cursors, approvals, drafts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessions = try container.decodeIfPresent([OfflineSessionCacheSession].self, forKey: .sessions) ?? []
        entries = try container.decodeIfPresent([OfflineSessionCacheEntry].self, forKey: .entries) ?? []
        cursors = try container.decodeIfPresent([OfflineSessionCursor].self, forKey: .cursors) ?? []
        approvals = try container.decodeIfPresent([OfflineSessionApproval].self, forKey: .approvals) ?? []
        drafts = try container.decodeIfPresent([OfflineSessionDraft].self, forKey: .drafts) ?? []
    }

    /// 读取某个 Host 的某个会话；`hostID == nil` 时禁止跨 Host 猜取。
    public func cachedSession(hostID: UUID?, sessionID: String) -> OfflineCachedSession? {
        guard let hostID else { return nil }
        let matchingEntries = OfflineSessionCachePolicy.cachedEntries(
            entries,
            hostID: hostID,
            sessionID: sessionID
        )
        let matchingCursor = cursors
            .filter { $0.hostID == hostID && $0.sessionId == sessionID }
            .max { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt < rhs.updatedAt }
                return lhs.sequence < rhs.sequence
            }
        let matchingApprovals = approvals
            .filter { $0.hostID == hostID && $0.sessionId == sessionID }
            .sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
                return $0.id < $1.id
            }
        let matchingDraft = drafts
            .filter { $0.hostID == hostID && $0.sessionId == sessionID }
            .max { $0.updatedAt < $1.updatedAt }

        guard !matchingEntries.isEmpty
                || matchingCursor != nil
                || !matchingApprovals.isEmpty
                || matchingDraft != nil
        else { return nil }

        return OfflineCachedSession(
            entries: matchingEntries,
            cursor: matchingCursor,
            approvals: matchingApprovals,
            draft: matchingDraft
        )
    }

    public func cachedSessionMetadata(hostID: UUID?, sessionID: String) -> OfflineSessionCacheSession? {
        guard let hostID else { return nil }
        return sessions
            .filter { $0.hostID == hostID && $0.id == sessionID }
            .max { $0.updatedAt < $1.updatedAt }
    }

    /// 某个 Host 出现过的会话，按最近一次缓存活动排序。
    public func sessionIDs(hostID: UUID?) -> [String] {
        guard let hostID else { return [] }
        var latestBySession: [String: Date] = [:]
        func record(_ sessionID: String, _ date: Date) {
            latestBySession[sessionID] = max(latestBySession[sessionID] ?? .distantPast, date)
        }
        for session in sessions where session.hostID == hostID {
            record(session.id, session.updatedAt)
        }
        for entry in entries where entry.hostID == hostID {
            record(entry.sessionId, entry.createdAt)
        }
        for cursor in cursors where cursor.hostID == hostID {
            record(cursor.sessionId, cursor.updatedAt)
        }
        for approval in approvals where approval.hostID == hostID {
            record(approval.sessionId, approval.createdAt)
        }
        for draft in drafts where draft.hostID == hostID {
            record(draft.sessionId, draft.updatedAt)
        }
        return latestBySession.sorted {
            if $0.value != $1.value { return $0.value > $1.value }
            return $0.key < $1.key
        }.map(\.key)
    }

    /// 权威快照写回前整体替换一个会话的 items/cursor/approvals，草稿由用户输入单独维护。
    public mutating func removeSession(hostID: UUID, sessionID: String) {
        sessions.removeAll { $0.hostID == hostID && $0.id == sessionID }
        entries.removeAll { $0.hostID == hostID && $0.sessionId == sessionID }
        cursors.removeAll { $0.hostID == hostID && $0.sessionId == sessionID }
        approvals.removeAll { $0.hostID == hostID && $0.sessionId == sessionID }
    }

    public mutating func removeSessionAndDraft(hostID: UUID, sessionID: String) {
        removeSession(hostID: hostID, sessionID: sessionID)
        drafts.removeAll { $0.hostID == hostID && $0.sessionId == sessionID }
    }

    public mutating func removeHost(_ hostID: UUID) {
        sessions.removeAll { $0.hostID == hostID }
        entries.removeAll { $0.hostID == hostID }
        cursors.removeAll { $0.hostID == hostID }
        approvals.removeAll { $0.hostID == hostID }
        drafts.removeAll { $0.hostID == hostID }
    }
}

/// 版本化落盘文件。旧版 `{version:1, entries:[...]}` 仍可解码，其余表按空数组补齐。
public struct OfflineSessionCacheDocument: Codable, Equatable, Sendable {
    public enum SchemaError: Error { case unsupportedVersion }
    public static let currentVersion = 3

    public var version: Int
    public var sessions: [OfflineSessionCacheSession]
    public var entries: [OfflineSessionCacheEntry]
    public var cursors: [OfflineSessionCursor]
    public var approvals: [OfflineSessionApproval]
    public var drafts: [OfflineSessionDraft]

    public init(
        version: Int = OfflineSessionCacheDocument.currentVersion,
        sessions: [OfflineSessionCacheSession] = [],
        entries: [OfflineSessionCacheEntry] = [],
        cursors: [OfflineSessionCursor] = [],
        approvals: [OfflineSessionApproval] = [],
        drafts: [OfflineSessionDraft] = []
    ) {
        self.version = version
        self.sessions = sessions
        self.entries = entries
        self.cursors = cursors
        self.approvals = approvals
        self.drafts = drafts
    }

    public init(snapshot: OfflineSessionCacheSnapshot) {
        self.init(
            sessions: snapshot.sessions,
            entries: snapshot.entries,
            cursors: snapshot.cursors,
            approvals: snapshot.approvals,
            drafts: snapshot.drafts
        )
    }

    public var snapshot: OfflineSessionCacheSnapshot {
        OfflineSessionCacheSnapshot(
            sessions: sessions,
            entries: entries,
            cursors: cursors,
            approvals: approvals,
            drafts: drafts
        )
    }

    private enum CodingKeys: String, CodingKey {
        case version, sessions, entries, cursors, approvals, drafts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let storedVersion = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        guard (1...Self.currentVersion).contains(storedVersion) else { throw SchemaError.unsupportedVersion }
        // 读取旧文件即按当前 schema 处理；下次写入自然完成升级。
        version = Self.currentVersion
        sessions = try container.decodeIfPresent([OfflineSessionCacheSession].self, forKey: .sessions) ?? []
        entries = try container.decodeIfPresent([OfflineSessionCacheEntry].self, forKey: .entries) ?? []
        cursors = try container.decodeIfPresent([OfflineSessionCursor].self, forKey: .cursors) ?? []
        approvals = try container.decodeIfPresent([OfflineSessionApproval].self, forKey: .approvals) ?? []
        drafts = try container.decodeIfPresent([OfflineSessionDraft].self, forKey: .drafts) ?? []
    }
}

/// Missing files are empty caches; unreadable, corrupt and future files remain untouched.
public enum OfflineSessionCacheFile {
    private static let lock = NSLock()

    public static func load(from url: URL) throws -> OfflineSessionCacheDocument? {
        lock.lock()
        defer { lock.unlock() }
        return try read(url)
    }

    public static func save(_ document: OfflineSessionCacheDocument, to url: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        _ = try read(url)
        let data = try JSONEncoder().encode(document)
        // Validate outgoing versions too; never create a document this reader cannot reopen.
        _ = try JSONDecoder().decode(OfflineSessionCacheDocument.self, from: data)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        var fileURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try fileURL.setResourceValues(values)
    }

    private static func read(_ url: URL) throws -> OfflineSessionCacheDocument? {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        try PersistentJSONValidation.rejectDuplicateKeys(in: data)
        return try JSONDecoder().decode(OfflineSessionCacheDocument.self, from: data)
    }
}

/// 一次缓存写入的租约。App 层在异步读取快照前捕获它，落盘前同时校验
/// client 身份、连接代次、Host 和会话，防止旧连接或旧 Host 的迟到结果覆盖新状态。
public struct OfflineSessionCacheWriteLease: Equatable, Sendable {
    public let clientID: UUID
    public let connectionGeneration: Int
    public let hostID: UUID
    public let sessionID: String

    public init(
        clientID: UUID,
        connectionGeneration: Int,
        hostID: UUID,
        sessionID: String
    ) {
        self.clientID = clientID
        self.connectionGeneration = connectionGeneration
        self.hostID = hostID
        self.sessionID = sessionID
    }

    public func isCurrent(
        clientID: UUID,
        connectionGeneration: Int,
        hostID: UUID?,
        sessionID: String?
    ) -> Bool {
        self.clientID == clientID
            && self.connectionGeneration == connectionGeneration
            && self.hostID == hostID
            && self.sessionID == sessionID
    }

    /// Drafts belong to a session, but must still flush after the UI switches sessions
    /// as long as the same client/Host connection is current.
    public func isCurrentHost(
        clientID: UUID,
        connectionGeneration: Int,
        hostID: UUID?
    ) -> Bool {
        self.clientID == clientID
            && self.connectionGeneration == connectionGeneration
            && self.hostID == hostID
    }
}

/// 新增表的列名，供 AC-15.3 的「缓存不得包含凭证字段」契约测试覆盖。
public enum OfflineSessionCacheSchema {
    public static let cursorColumns = ["host_id", "session_id", "epoch", "sequence", "updated_at"]
    public static let approvalColumns = [
        "host_id", "id", "session_id", "payload", "revision", "status", "decision", "created_at",
    ]
    public static let draftColumns = [
        "host_id", "session_id", "text", "idempotency_key", "updated_at",
    ]

    public static var allColumns: [String] {
        cursorColumns + approvalColumns + draftColumns
    }
}
