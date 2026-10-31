import Foundation

// MARK: - 缓存表与字段（契约 §6）

/// 契约 §6 的五张本地缓存表。**名称级**约束：任何表的列里都不允许出现 API Key、
/// 设备令牌、配对令牌（AC-04.3 / AC-15.3），所以这里把列名固化下来，供 `CacheFieldPolicy` 检查。
public enum CacheRecordKind: String, CaseIterable, Sendable {
    case sessions
    case items
    case cursors
    case approvals
    case drafts

    public var primaryKey: String {
        switch self {
        case .sessions, .items, .approvals: return "id"
        case .cursors, .drafts: return "session_id"
        }
    }

    /// 契约 §6 表格的「关键列」，逐字对应。
    public var columns: [String] {
        switch self {
        case .sessions:
            return [
                "id", "title", "project_id", "mode", "permission_mode", "model_id", "provider_id",
                "epoch", "sequence", "updated_at",
            ]
        case .items:
            return [
                "id", "session_id", "kind", "role", "text", "tool_name", "status",
                "epoch", "sequence", "created_at",
            ]
        case .cursors:
            return ["session_id", "epoch", "sequence", "updated_at"]
        case .approvals:
            return ["id", "session_id", "status", "revision", "decision", "created_at"]
        case .drafts:
            return ["session_id", "text", "idempotency_key", "updated_at"]
        }
    }

    public static var allColumns: [String] {
        CacheRecordKind.allCases.flatMap(\.columns)
    }
}

/// 「缓存不得包含密钥」的名称级约束（契约 §6 末句）。
///
/// 名称级检查挡不住加密后才写入的值，但能挡住「把 `secretValue` 当普通列存下来」这类错误，
/// 也让 schema 变更时有一条可断言的规则（AC-15.3）。
public enum CacheFieldPolicy {
    /// 给用户/开发者看的规则说明。
    public static let rule = "缓存中禁止出现 API Key、设备令牌、配对令牌（契约 §6）"

    /// 归一化后禁止出现的名称片段（大小写不敏感，忽略 `_` 与 `-`）。
    public static let forbiddenNameFragments: [String] = [
        "secret", "apikey", "devicetoken", "pairingtoken", "token", "authorization", "password", "privatekey",
    ]

    static func normalize(_ field: String) -> String {
        field.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "")
    }

    /// 返回命中的禁用字段名（空数组表示干净）。
    public static func violations(inFields fields: [String]) -> [String] {
        fields.filter { field in
            let normalized = normalize(field)
            return forbiddenNameFragments.contains { normalized.contains($0) }
        }
    }

    /// 断言一组字段名不含密钥列；命中即抛错（便于在 schema 定义处调用）。
    public static func assertClean(_ fields: [String], context: String) throws {
        let hits = violations(inFields: fields)
        guard hits.isEmpty else {
            throw CacheFieldPolicyError.forbiddenFields(context: context, fields: hits)
        }
    }

    /// 契约 §6 表格自身的列名是否干净（恒应为空）。
    public static var schemaViolations: [String] {
        violations(inFields: CacheRecordKind.allColumns + OfflineSessionCacheSchema.allColumns)
    }

    /// Recursively redact credential-looking keys from opaque JSON before it
    /// enters the offline cache. The field-name policy is the same one used for
    /// schema columns; values under matching keys are never persisted.
    public static func redactedForCache(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(let object):
            var redacted: [String: JSONValue] = [:]
            redacted.reserveCapacity(object.count)
            for (key, child) in object {
                if !violations(inFields: [key]).isEmpty {
                    redacted[key] = .string("[redacted]")
                } else {
                    redacted[key] = redactedForCache(child)
                }
            }
            return .object(redacted)
        case .array(let array):
            return .array(array.map(redactedForCache))
        default:
            return value
        }
    }
}

public enum CacheFieldPolicyError: Error, Equatable, CustomStringConvertible {
    case forbiddenFields(context: String, fields: [String])

    public var description: String {
        switch self {
        case let .forbiddenFields(context, fields):
            return "\(context) 出现禁止字段：\(fields.joined(separator: ", "))（\(CacheFieldPolicy.rule)）"
        }
    }
}

// MARK: - 保留策略（契约 §6、spec AC-15.1）

/// 缓存里的一条会话记录（保留策略只看 `created_at`）。
public struct CacheSessionRecord: Equatable, Sendable {
    public let id: String
    public let createdAt: Date

    public init(id: String, createdAt: Date) {
        self.id = id
        self.createdAt = createdAt
    }
}

/// 缓存里的一条消息记录。
public struct CacheItemRecord: Equatable, Sendable {
    public let id: String
    public let sessionId: String
    public let createdAt: Date

    public init(id: String, sessionId: String, createdAt: Date) {
        self.id = id
        self.sessionId = sessionId
        self.createdAt = createdAt
    }
}

/// 一次裁剪的结果：保留的 id 与淘汰的 id，顺序都是「新→旧」。
public struct CacheRetentionPlan: Equatable, Sendable {
    public let kept: [String]
    public let evicted: [String]

    public init(kept: [String], evicted: [String]) {
        self.kept = kept
        self.evicted = evicted
    }
}

/// 离线缓存保留策略的纯函数实现（不接 SQLite）：
/// 单会话保留最新 **200** 条、最多 **20** 个会话，超限按 `created_at` 淘汰（契约 §6、AC-15.1）。
public enum CacheRetention {
    public static let maxItemsPerSession = 200
    public static let maxSessions = 20

    /// 单会话保留条数的默认值（= 契约 §6 的 200）。
    /// 设置里的「离线缓存上限」没有给出值时用它。
    public static let defaultItemsPerSession = maxItemsPerSession

    /// 把设置里的「离线缓存上限」（`offlineCacheLimit`）转成单会话保留条数。
    ///
    /// 缓存层必须用这个值裁剪：`pruneItems` 的无参默认值恒为 200，若调用方不传设置值，
    /// 用户在设置里选 1000 也会按 200 淘汰（AC-15.1）。缺省或非法值回落到默认 200。
    public static func itemsPerSessionLimit(offlineCacheLimit: Int?) -> Int {
        guard let offlineCacheLimit, offlineCacheLimit > 0 else { return defaultItemsPerSession }
        return offlineCacheLimit
    }

    /// 按设置里的上限裁剪单会话条数（`offlineCacheLimit` 为 `nil` 时用默认 200）。
    public static func pruneItems(_ items: [CacheItemRecord], offlineCacheLimit: Int?) -> CacheRetentionPlan {
        pruneItems(items, limit: itemsPerSessionLimit(offlineCacheLimit: offlineCacheLimit))
    }

    /// 每个会话保留最新 `limit` 条，超出的按 `created_at` 从旧到新淘汰。
    public static func pruneItems(_ items: [CacheItemRecord], limit: Int = maxItemsPerSession) -> CacheRetentionPlan {
        guard limit >= 0 else { return CacheRetentionPlan(kept: [], evicted: items.map(\.id)) }
        var kept: [String] = []
        var evicted: [String] = []
        for sessionId in orderedSessionIds(items) {
            let sessionItems = items.filter { $0.sessionId == sessionId }.sorted(by: newestFirst)
            kept.append(contentsOf: sessionItems.prefix(limit).map(\.id))
            evicted.append(contentsOf: sessionItems.dropFirst(limit).map(\.id))
        }
        return CacheRetentionPlan(kept: kept, evicted: evicted)
    }

    /// 最多保留 `limit` 个会话，超出的按 `created_at` 从旧到新淘汰。
    public static func pruneSessions(_ sessions: [CacheSessionRecord], limit: Int = maxSessions) -> CacheRetentionPlan {
        guard limit >= 0 else { return CacheRetentionPlan(kept: [], evicted: sessions.map(\.id)) }
        let ordered = sessions.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.id < rhs.id
        }
        return CacheRetentionPlan(
            kept: ordered.prefix(limit).map(\.id),
            evicted: ordered.dropFirst(limit).map(\.id)
        )
    }

    /// 单会话裁剪：给定会话的记录整体保留策略（先按会话裁条数，再裁会话数）。
    /// `offlineCacheLimit` 传设置里的「离线缓存上限」，`nil` 时按默认 200 裁。
    public static func prune(
        sessions: [CacheSessionRecord],
        items: [CacheItemRecord],
        offlineCacheLimit: Int? = nil
    ) -> (sessions: CacheRetentionPlan, items: CacheRetentionPlan) {
        let sessionPlan = pruneSessions(sessions)
        let keptSessions = Set(sessionPlan.kept)
        let survivingItems = items.filter { keptSessions.contains($0.sessionId) }
        let droppedBySession = items.filter { !keptSessions.contains($0.sessionId) }
        let itemPlan = pruneItems(survivingItems, offlineCacheLimit: offlineCacheLimit)
        return (
            sessionPlan,
            CacheRetentionPlan(kept: itemPlan.kept, evicted: droppedBySession.map(\.id) + itemPlan.evicted)
        )
    }

    private static func orderedSessionIds(_ items: [CacheItemRecord]) -> [String] {
        var seen = Set<String>()
        var order: [String] = []
        for item in items where seen.insert(item.sessionId).inserted {
            order.append(item.sessionId)
        }
        return order
    }

    private static func newestFirst(_ lhs: CacheItemRecord, _ rhs: CacheItemRecord) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
        return lhs.id < rhs.id
    }
}
