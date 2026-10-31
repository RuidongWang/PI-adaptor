import Foundation

/// 离线缓存条目。`hostID` 是分区键的一部分，同一 `sessionId` 在不同 Host 上不能互相覆盖。
public struct OfflineSessionCacheEntry: Codable, Equatable, Sendable {
    public var id: String
    public var sessionId: String
    public var hostID: UUID?
    public var text: String
    public var createdAt: Date
    /// C-4 `items` 表的其余关键列。旧 JSON 缓存没有这些字段时保持 nil。
    public var kind: String?
    public var role: String?
    public var toolName: String?
    public var status: String?
    public var epoch: String?
    public var sequence: Int?

    public init(
        id: String,
        sessionId: String,
        hostID: UUID?,
        text: String,
        createdAt: Date,
        kind: String? = nil,
        role: String? = nil,
        toolName: String? = nil,
        status: String? = nil,
        epoch: String? = nil,
        sequence: Int? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.hostID = hostID
        self.text = text
        self.createdAt = createdAt
        self.kind = kind
        self.role = role
        self.toolName = toolName
        self.status = status
        self.epoch = epoch
        self.sequence = sequence
    }

    /// Offline history still needs a readable row for tool/status items whose
    /// canonical payload has no text body.
    public var displayText: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return text }
        if let toolName, !toolName.isEmpty { return "工具调用：\(toolName)" }
        if let kind, !kind.isEmpty { return "\(kind)（无文本内容）" }
        return "（无文本内容）"
    }
}

/// C-4 `sessions` 表。Host 与会话 ID 组成复合键，避免两个 Host 的同名会话互相覆盖。
public struct OfflineSessionCacheSession: Codable, Equatable, Sendable {
    public var hostID: UUID?
    public var id: String
    public var title: String?
    public var projectID: String?
    public var mode: String?
    public var permissionMode: String?
    public var modelID: String?
    public var providerID: String?
    public var epoch: String?
    public var sequence: Int?
    public var updatedAt: Date

    public init(
        hostID: UUID?,
        id: String,
        title: String?,
        projectID: String?,
        mode: String?,
        permissionMode: String?,
        modelID: String?,
        providerID: String?,
        epoch: String?,
        sequence: Int?,
        updatedAt: Date
    ) {
        self.hostID = hostID
        self.id = id
        self.title = title
        self.projectID = projectID
        self.mode = mode
        self.permissionMode = permissionMode
        self.modelID = modelID
        self.providerID = providerID
        self.epoch = epoch
        self.sequence = sequence
        self.updatedAt = updatedAt
    }
}

/// 离线缓存的纯策略：Host 分区、去重、读取隔离与保留上限。
public enum OfflineSessionCachePolicy {
    /// 会话缓存键：Host + 会话 ID。`nil` Host 也不会退化成仅按会话 ID 跨 Host 合并。
    public static func sessionKey(hostID: UUID?, sessionID: String) -> String {
        [
            lengthPrefixedField("host", hostID?.uuidString ?? "none"),
            lengthPrefixedField("session", sessionID),
        ].joined(separator: "|")
    }

    /// 条目缓存键：Host + 会话 ID + 条目 ID。
    public static func itemKey(hostID: UUID?, sessionID: String, itemID: String) -> String {
        [
            sessionKey(hostID: hostID, sessionID: sessionID),
            lengthPrefixedField("item", itemID),
        ].joined(separator: "|")
    }

    /// 同一 Host 的同一会话、同一消息只保留最新副本；不同 Host 的同名 ID 仍是不同条目。
    public static func deduplicatedEntries(_ entries: [OfflineSessionCacheEntry]) -> [OfflineSessionCacheEntry] {
        var latestByKey: [String: OfflineSessionCacheEntry] = [:]
        for entry in entries {
            let key = itemKey(hostID: entry.hostID, sessionID: entry.sessionId, itemID: entry.id)
            if let existing = latestByKey[key], existing.createdAt > entry.createdAt {
                continue
            }
            latestByKey[key] = entry
        }
        return latestByKey.values.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return itemKey(hostID: $0.hostID, sessionID: $0.sessionId, itemID: $0.id)
                < itemKey(hostID: $1.hostID, sessionID: $1.sessionId, itemID: $1.id)
        }
    }

    /// C-4 `sessions` 表按 Host + 会话 ID 去重，保留最近写入的行。
    public static func deduplicatedSessions(
        _ sessions: [OfflineSessionCacheSession]
    ) -> [OfflineSessionCacheSession] {
        var latestByKey: [String: OfflineSessionCacheSession] = [:]
        for session in sessions {
            let key = sessionKey(hostID: session.hostID, sessionID: session.id)
            guard let existing = latestByKey[key] else {
                latestByKey[key] = session
                continue
            }
            if session.updatedAt >= existing.updatedAt {
                latestByKey[key] = session
            }
        }
        return latestByKey.values.sorted {
            sessionKey(hostID: $0.hostID, sessionID: $0.id)
                < sessionKey(hostID: $1.hostID, sessionID: $1.id)
        }
    }

    /// 当前 Host 的指定会话条目（新→旧）。Host 未确定时必须返回空，禁止跨 Host 猜取。
    public static func cachedEntries(
        _ entries: [OfflineSessionCacheEntry],
        hostID: UUID?,
        sessionID: String
    ) -> [OfflineSessionCacheEntry] {
        guard let hostID else { return [] }
        return deduplicatedEntries(entries).filter {
            $0.hostID == hostID && $0.sessionId == sessionID
        }
    }

    /// 当前 Host 已缓存过的会话 ID（按最近条目时间新→旧）。Host 未确定时返回空。
    public static func sessionIDs(
        _ entries: [OfflineSessionCacheEntry],
        hostID: UUID?
    ) -> [String] {
        guard let hostID else { return [] }
        var latestBySession: [String: Date] = [:]
        for entry in deduplicatedEntries(entries) where entry.hostID == hostID {
            latestBySession[entry.sessionId] = max(
                latestBySession[entry.sessionId] ?? .distantPast,
                entry.createdAt
            )
        }
        return latestBySession.sorted {
            if $0.value != $1.value { return $0.value > $1.value }
            return $0.key < $1.key
        }.map(\.key)
    }

    /// 合并写回时先按完整复合键去重，避免重复条目进入落盘文件。
    public static func merged(
        _ existing: [OfflineSessionCacheEntry],
        with incoming: [OfflineSessionCacheEntry]
    ) -> [OfflineSessionCacheEntry] {
        deduplicatedEntries(existing + incoming)
    }

    /// 同一会话只保留最新一份游标；Host 是键的一部分。
    public static func deduplicatedCursors(
        _ cursors: [OfflineSessionCursor]
    ) -> [OfflineSessionCursor] {
        var latestByKey: [String: OfflineSessionCursor] = [:]
        for cursor in cursors {
            let key = sessionKey(hostID: cursor.hostID, sessionID: cursor.sessionId)
            guard let existing = latestByKey[key] else {
                latestByKey[key] = cursor
                continue
            }
            if cursor.updatedAt > existing.updatedAt
                || (cursor.updatedAt == existing.updatedAt && cursor.sequence >= existing.sequence) {
                latestByKey[key] = cursor
            }
        }
        return latestByKey.values.sorted {
            let lhsKey = sessionKey(hostID: $0.hostID, sessionID: $0.sessionId)
            let rhsKey = sessionKey(hostID: $1.hostID, sessionID: $1.sessionId)
            return lhsKey < rhsKey
        }
    }

    /// 审批卡按 Host + 会话 + `approval.id` 去重，重复写入时保留最新状态与 revision。
    public static func deduplicatedApprovals(
        _ approvals: [OfflineSessionApproval]
    ) -> [OfflineSessionApproval] {
        var latestByKey: [String: OfflineSessionApproval] = [:]
        for approval in approvals {
            let key = approvalKey(
                hostID: approval.hostID,
                sessionID: approval.sessionId,
                approvalID: approval.id
            )
            guard let existing = latestByKey[key] else {
                latestByKey[key] = approval
                continue
            }
            if approval.createdAt >= existing.createdAt {
                latestByKey[key] = approval
            }
        }
        return latestByKey.values.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return approvalKey(hostID: $0.hostID, sessionID: $0.sessionId, approvalID: $0.id)
                < approvalKey(hostID: $1.hostID, sessionID: $1.sessionId, approvalID: $1.id)
        }
    }

    /// 每个 Host + 会话只保留最新一份草稿。
    public static func deduplicatedDrafts(
        _ drafts: [OfflineSessionDraft]
    ) -> [OfflineSessionDraft] {
        var latestByKey: [String: OfflineSessionDraft] = [:]
        for draft in drafts {
            let key = sessionKey(hostID: draft.hostID, sessionID: draft.sessionId)
            guard let existing = latestByKey[key] else {
                latestByKey[key] = draft
                continue
            }
            if draft.updatedAt >= existing.updatedAt {
                latestByKey[key] = draft
            }
        }
        return latestByKey.values.sorted {
            sessionKey(hostID: $0.hostID, sessionID: $0.sessionId)
                < sessionKey(hostID: $1.hostID, sessionID: $1.sessionId)
        }
    }

    /// 对完整缓存快照执行统一裁剪：
    /// - 会话活动时间取自 items/cursors/approvals/drafts 的最新时间；
    /// - 最多保留 20 个 Host + 会话；
    /// - 每个会话的 items 按设置上限（默认 200）保留最新记录；
    /// - 游标与草稿每会话一份，审批卡去重后只保留未淘汰会话。
    public static func prunedSnapshot(
        _ snapshot: OfflineSessionCacheSnapshot,
        offlineCacheLimit: Int?
    ) -> OfflineSessionCacheSnapshot {
        let sessions = deduplicatedSessions(snapshot.sessions)
        let entries = deduplicatedEntries(snapshot.entries)
        let cursors = deduplicatedCursors(snapshot.cursors)
        let approvals = deduplicatedApprovals(snapshot.approvals)
        let drafts = deduplicatedDrafts(snapshot.drafts)

        var latestBySession: [String: Date] = [:]
        func record(_ hostID: UUID?, _ sessionID: String, _ date: Date) {
            let key = sessionKey(hostID: hostID, sessionID: sessionID)
            latestBySession[key] = max(latestBySession[key] ?? .distantPast, date)
        }
        for session in sessions {
            record(session.hostID, session.id, session.updatedAt)
        }
        for entry in entries {
            record(entry.hostID, entry.sessionId, entry.createdAt)
        }
        for cursor in cursors {
            record(cursor.hostID, cursor.sessionId, cursor.updatedAt)
        }
        for approval in approvals {
            record(approval.hostID, approval.sessionId, approval.createdAt)
        }
        for draft in drafts {
            record(draft.hostID, draft.sessionId, draft.updatedAt)
        }

        let sessionPlan = CacheRetention.pruneSessions(
            latestBySession.map { CacheSessionRecord(id: $0.key, createdAt: $0.value) }
        )
        let keptSessions = Set(sessionPlan.kept)
        func isKept(_ hostID: UUID?, _ sessionID: String) -> Bool {
            keptSessions.contains(sessionKey(hostID: hostID, sessionID: sessionID))
        }

        let keptEntries = entries.filter { isKept($0.hostID, $0.sessionId) }
        let itemRecords = keptEntries.map { entry in
            CacheItemRecord(
                id: itemKey(hostID: entry.hostID, sessionID: entry.sessionId, itemID: entry.id),
                sessionId: sessionKey(hostID: entry.hostID, sessionID: entry.sessionId),
                createdAt: entry.createdAt
            )
        }
        let itemPlan = CacheRetention.pruneItems(
            itemRecords,
            offlineCacheLimit: offlineCacheLimit
        )
        let entryByKey = Dictionary(
            uniqueKeysWithValues: keptEntries.map { entry in
                (itemKey(hostID: entry.hostID, sessionID: entry.sessionId, itemID: entry.id), entry)
            }
        )

        return OfflineSessionCacheSnapshot(
            sessions: sessions.filter { isKept($0.hostID, $0.id) },
            entries: itemPlan.kept.compactMap { entryByKey[$0] },
            cursors: cursors.filter { isKept($0.hostID, $0.sessionId) },
            approvals: approvals.filter { isKept($0.hostID, $0.sessionId) },
            drafts: drafts.filter { isKept($0.hostID, $0.sessionId) }
        )
    }

    /// 按契约保留单会话最新 N 条、最多 20 个 Host+会话；重复条目先去重，避免以重复键建字典。
    public static func prunedEntries(
        _ entries: [OfflineSessionCacheEntry],
        offlineCacheLimit: Int?
    ) -> [OfflineSessionCacheEntry] {
        prunedSnapshot(
            OfflineSessionCacheSnapshot(entries: entries),
            offlineCacheLimit: offlineCacheLimit
        ).entries
    }

    private static func approvalKey(
        hostID: UUID?,
        sessionID: String,
        approvalID: String
    ) -> String {
        [
            sessionKey(hostID: hostID, sessionID: sessionID),
            lengthPrefixedField("approval", approvalID),
        ].joined(separator: "|")
    }

    private static func lengthPrefixedField(_ name: String, _ value: String) -> String {
        let normalized = value.precomposedStringWithCanonicalMapping
        return "\(name):\(normalized.utf8.count):\(normalized)"
    }
}
