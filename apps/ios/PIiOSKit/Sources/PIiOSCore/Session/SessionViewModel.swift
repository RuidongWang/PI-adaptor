import Foundation
import CryptoKit

// MARK: - Persistent request identity (AC-14.4)

public enum SessionRequestAction: Codable, Equatable, Sendable {
    case turn(text: String)
    case turnAttachments(text: String, attachmentIds: [String])
    case approval(decision: RACPApprovalDecision, permissionMode: RACPPermissionMode?)
    case contract(decision: RACPContractDecision, permissionMode: RACPPermissionMode? = nil)
    case input(answers: [[String]?])
}

public struct SessionRequestIdentity: Codable, Equatable, Sendable {
    public let hostID: String
    public let sessionID: String
    public let itemID: String?
    public let action: SessionRequestAction

    public init(hostID: String, sessionID: String, itemID: String? = nil, action: SessionRequestAction) {
        self.hostID = hostID
        self.sessionID = sessionID
        self.itemID = itemID
        self.action = action
    }

    fileprivate func fingerprint() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(self)).map { String(format: "%02x", $0) }.joined()
    }
}

public struct SessionRequestAttempt: Codable, Equatable, Sendable {
    public let fingerprint: String
    public let idempotencyKey: String
    // Admission is part of the wire payload: a timeout must not turn a start into a queue.
    public let admission: RACPTurnAdmission?
}

/// Stores only SHA-256 identities and random keys, never text, answers or credentials.
/// A failed read/write is fatal to preparation: an unpersisted key must never reach the network.
public final class SessionRequestKeyStore {
    private struct Payload: Codable {
        var version = 1
        var pending: [String: SessionRequestAttempt] = [:]
    }

    public enum StoreError: Error {
        case unavailable
        case unsupportedVersion
        case invalidIdentity
        case corrupt
    }

    private static let lock = NSLock()
    private let fileURL: URL?
    private let setResourceValues: (URL) throws -> Void

    public init(fileURL: URL?) {
        self.fileURL = fileURL
        self.setResourceValues = Self.excludeFromBackup
    }

    init(fileURL: URL?, setResourceValues: @escaping (URL) throws -> Void) {
        self.fileURL = fileURL
        self.setResourceValues = setResourceValues
    }

    public func prepare(
        _ identity: SessionRequestIdentity,
        admission: RACPTurnAdmission? = nil
    ) throws -> SessionRequestAttempt {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        guard !identity.hostID.isEmpty, !identity.sessionID.isEmpty else {
            throw StoreError.invalidIdentity
        }
        let fingerprint = try identity.fingerprint()
        var payload = try load()
        if let existing = payload.pending[fingerprint] {
            if let fileURL { try setResourceValues(fileURL) }
            return existing
        }
        let attempt = SessionRequestAttempt(
            fingerprint: fingerprint,
            idempotencyKey: "request_\(UUID().uuidString)",
            admission: admission
        )
        payload.pending[fingerprint] = attempt
        try save(payload, requireResourceValues: true)
        return attempt
    }

    /// A late acknowledgement may retire only its own attempt, never a subsequent one.
    public func acknowledge(_ attempt: SessionRequestAttempt) throws {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        var payload = try load()
        guard payload.pending[attempt.fingerprint]?.idempotencyKey == attempt.idempotencyKey else { return }
        payload.pending.removeValue(forKey: attempt.fingerprint)
        try save(payload, requireResourceValues: false)
    }

    private func load() throws -> Payload {
        guard let fileURL else { throw StoreError.unavailable }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return Payload()
        }
        try PersistentJSONValidation.rejectDuplicateKeys(in: data)
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard payload.version == 1 else { throw StoreError.unsupportedVersion }
        var keys: Set<String> = []
        for (fingerprint, attempt) in payload.pending {
            guard fingerprint.utf8.count == 64,
                  fingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  attempt.fingerprint == fingerprint,
                  !attempt.idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  keys.insert(attempt.idempotencyKey).inserted
            else { throw StoreError.corrupt }
        }
        return payload
    }

    private func save(_ payload: Payload, requireResourceValues: Bool) throws {
        guard let fileURL else { throw StoreError.unavailable }
        try JSONEncoder().encode(payload).write(to: fileURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        // After retirement commits, metadata failure must not turn success into a resend.
        if requireResourceValues { try setResourceValues(fileURL) }
        else { try? setResourceValues(fileURL) }
    }

    private static func excludeFromBackup(_ fileURL: URL) throws {
        var url = fileURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
}

/// JSONDecoder otherwise silently chooses one value when an object repeats a key.
enum PersistentJSONValidation {
    enum ValidationError: Error { case duplicateKey }

    static func rejectDuplicateKeys(in data: Data) throws {
        let bytes = Array(data)
        var objects: [Set<String>] = []
        var index = 0
        while index < bytes.count {
            switch bytes[index] {
            case 123: objects.append([])
            case 125: if !objects.isEmpty { objects.removeLast() }
            case 34:
                let start = index
                index += 1
                while index < bytes.count {
                    if bytes[index] == 92 { index += 2; continue }
                    if bytes[index] == 34 { break }
                    index += 1
                }
                guard index < bytes.count else { break }
                var next = index + 1
                while next < bytes.count && [9, 10, 13, 32].contains(bytes[next]) { next += 1 }
                if next < bytes.count, bytes[next] == 58, !objects.isEmpty {
                    let key = try JSONDecoder().decode(String.self, from: Data(bytes[start...index]))
                    guard objects[objects.count - 1].insert(key).inserted else {
                        throw ValidationError.duplicateKey
                    }
                }
            default: break
            }
            index += 1
        }
    }
}

// MARK: - 事件帧

/// 一条入站事件（`events/subscribe` 之后推送的帧）。
///
/// 事件帧的**内部形状**在 FROZEN 契约里没有冻结（契约 §3.2 只规定游标 `{epoch, sequence}`、
/// 去重键 `item.id`、禁止用墙钟时间判断增量）。因此这里只提取归约必需的三项：
/// `sequence`（游标推进与过期判定）、`epoch`（变化即要求快照重建）、`item`（可渲染条目），
/// 其余字段整体保留在 `payload` 里，不臆造字段名。
public struct RACPEvent: Equatable, Sendable {
    /// Durable replay cursor. `nil` for ephemeral live frames.
    public let durableSequence: Int?
    /// Last durable sequence followed by an ephemeral frame.
    public let afterSequence: Int?
    /// Compatibility projection used by host-event acknowledgements/tests.
    public var sequence: Int { durableSequence ?? afterSequence ?? 0 }
    public var isDurable: Bool { durableSequence != nil }
    /// `nil` 表示该帧未携带 epoch（沿用当前游标 epoch）。
    public let epoch: String?
    public let item: RACPItem?
    /// 整帧原始 JSON。
    public let payload: JSONValue

    public init(sequence: Int, epoch: String? = nil, item: RACPItem? = nil, payload: JSONValue = .null) {
        durableSequence = sequence
        afterSequence = nil
        self.epoch = epoch
        self.item = item
        self.payload = payload
    }
}

extension RACPEvent: Codable {
    private enum CodingKeys: String, CodingKey {
        case sequence, afterSequence, epoch, item
    }

    public init(from decoder: Decoder) throws {
        payload = try JSONObjectPayload.decodeObject(from: decoder)
        let durableSequence = payload.value(at: ["sequence"])?.intValue
        let afterSequence = payload.value(at: ["afterSequence"])?.intValue
        guard durableSequence != nil || afterSequence != nil else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "事件帧缺少 durable sequence 或 ephemeral afterSequence"
                )
            )
        }
        self.durableSequence = durableSequence
        self.afterSequence = afterSequence
        epoch = payload.value(at: ["epoch"])?.stringValue
        if let itemValue = payload.value(at: ["item"]) {
            item = try RACPItem(payload: itemValue)
        } else if let itemValue = payload.value(at: ["payload", "item"]) {
            // v2 contract: `item.completed` nests the canonical item under `payload.item`.
            item = try RACPItem(payload: itemValue)
        } else if let projected = Self.projectedItem(from: payload) {
            item = projected
        } else {
            item = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        if case .object = payload {
            try payload.encode(to: encoder)
            return
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(durableSequence, forKey: .sequence)
        try container.encodeIfPresent(afterSequence, forKey: .afterSequence)
        try container.encodeIfPresent(epoch, forKey: .epoch)
        try container.encodeIfPresent(item, forKey: .item)
    }

    /// Host event envelopes keep item identity in `payload.itemId`, canonical
    /// message/tool data either in `payload.event` (v1) or directly on the
    /// payload (v2); normalize both shapes to the snapshot projection.
    private static func projectedItem(from envelope: JSONValue) -> RACPItem? {
        guard let eventPayload = envelope.value(at: ["payload"]),
              let itemId = eventPayload.value(at: ["itemId"])?.stringValue,
              !itemId.isEmpty
        else { return nil }
        let kind = envelope.value(at: ["kind"])?.stringValue
        guard let itemType =
            eventPayload.value(at: ["itemType"])?.stringValue ?? inferredItemType(forKind: kind)
        else { return nil }
        let turnId = envelope.value(at: ["turnId"])?.stringValue
        let event = eventPayload.value(at: ["event"])
        var object: [String: JSONValue] = [
            "id": .string(itemId),
            "itemType": .string(itemType),
            "kind": .string(itemType),
        ]
        if let turnId { object["turnId"] = .string(turnId) }
        if let message = event?.value(at: ["message"])?.objectValue {
            object.merge(message) { _, new in new }
            object["id"] = .string(itemId)
            object["itemType"] = .string(itemType)
            object["kind"] = .string(itemType)
            object["content"] = .object(message)
        } else if let event {
            object["content"] = event
            if let toolName = event.value(at: ["toolName"])?.stringValue {
                object["toolName"] = .string(toolName)
            }
            if itemType == "tool" {
                object["role"] = .string("tool")
            }
        } else {
            // v2 contract: the payload itself carries the fields.
            object["content"] = eventPayload
            if let toolName = eventPayload.value(at: ["toolName"])?.stringValue {
                object["toolName"] = .string(toolName)
            }
            if itemType == "tool" {
                object["role"] = .string("tool")
            }
        }
        return try? RACPItem(payload: .object(object))
    }

    /// v2 event payloads omit `itemType`, so infer it from the event `kind`.
    private static func inferredItemType(forKind kind: String?) -> String? {
        switch kind {
        case "item.delta", "item.completed":
            return "message"
        case "tool.started", "tool.updated", "tool.completed":
            return "tool"
        default:
            return nil
        }
    }
}

// MARK: - 草稿

/// 未完成的输入草稿（契约 §6 `drafts` 表：`text` + `idempotency_key`）。
/// 快照重建时必须整体丢弃（契约 §3.2 规则 1、AC-14.2）。
public struct SessionDraft: Equatable, Sendable {
    public var text: String
    public var idempotencyKey: String

    public init(text: String = "", idempotencyKey: String) {
        self.text = text
        self.idempotencyKey = idempotencyKey
    }
}

// MARK: - 归约结果

/// 快照应用结果，供界面决定是否提示「已按服务器状态重建」。
public struct SessionSnapshotOutcome: Equatable, Sendable {
    /// 快照替换后的 `items` 数量。
    public let itemCount: Int
    /// 是否丢弃了未完成草稿。
    public let discardedDraft: Bool
    /// 应用快照后应显示为「已过期」的审批卡 id：包含之前已过期、这次仍不在快照里的那些。
    public let newlyExpiredApprovalIds: [String]
}

/// 事件应用结果。
public enum SessionEventsOutcome: Equatable, Sendable {
    /// `appended` 新增条目数，`updated` 按 id 就地更新数，`ignored` 因重复/过期被忽略的条目数。
    case applied(appended: Int, updated: Int, ignored: Int)
    /// 必须重建视图（丢弃游标、按快照整体替换）。
    case requiresSnapshotRebuild(SessionRebuildReason)

    public var needsRebuild: Bool {
        if case .requiresSnapshotRebuild = self { return true }
        return false
    }
}

/// 需要快照重建的原因（契约 §3.2 规则 4：epoch 变化或游标越界）。
public enum SessionRebuildReason: Equatable, Sendable, CustomStringConvertible {
    case epochChanged(from: String, to: String)
    case cursorExpired
    case eventGap(expected: Int, actual: Int)

    public var description: String {
        switch self {
        case let .epochChanged(from, to):
            return "事件 epoch 由 \(from) 变为 \(to)，必须按快照整体重建"
        case .cursorExpired:
            return "游标已超出事件重放窗口，必须按快照整体重建"
        case let .eventGap(expected, actual):
            return "事件序号不连续（期望 \(expected)，收到 \(actual)），必须按快照整体重建"
        }
    }
}

// MARK: - 会话视图

/// 单会话视图归约器（契约 §3.2、§6；spec AC-14.1 / AC-14.2 / AC-14.5 / AC-14.6）。
///
/// 三条硬规则：
/// 1. 快照是权威状态，`applySnapshot` **整体替换**且丢弃未完成草稿（不合并）；
/// 2. 事件按 `item.id` 去重，不按追加顺序合并（同 id 就地更新，不产生重复行）；
/// 3. 游标只由 `{epoch, sequence}` 推进，epoch 变化或重复/过期 sequence 都有明确处置。
public final class SessionViewModel {
    public private(set) var cursor: RACPCursor?
    public private(set) var revision: Int = 0
    public private(set) var items: [RACPItem] = []
    public private(set) var activeItems: [RACPItem] = []
    public private(set) var activeTurnId: String?
    public private(set) var queuedTurns: [JSONValue] = []
    private var queuedTurnIDs: Set<String> = []
    public private(set) var pendingApprovals: [RACPApprovalRequest] = []
    public private(set) var pendingInputs: [RACPInputRequest] = []
    public private(set) var hasMoreHistory: Bool = false
    /// 未完成草稿；快照重建后为 `nil`。
    public private(set) var draft: SessionDraft?
    /// 最近一次快照/订阅是否声明重放已完成。
    public private(set) var lastReplayComplete: Bool = false
    /// 曾出现过、但已不在快照 `pendingApprovals` 中的审批卡：界面应显示为过期而非可点击（AC-14.5）。
    public private(set) var expiredApprovalIds: Set<String> = []
    private var explicitlyExpiredApprovals: [String: RACPApprovalRequest] = [:]
    /// 已被快照替换掉的旧 epoch：这些 epoch 的重放帧必须丢弃，不能当成「epoch 变化」触发重建
    /// （重建会丢弃用户未发送的草稿）。
    public private(set) var staleEpochs: Set<String> = []

    private var itemIndexByID: [String: Int] = [:]

    public init() {}

    /// 切换会话前清空所有归约状态；新会话的快照不能继承旧会话的游标、
    /// 运行中 turn、审批失效集合或草稿。
    public func resetForSession() {
        cursor = nil
        revision = 0
        items = []
        activeItems = []
        activeTurnId = nil
        queuedTurns = []
        queuedTurnIDs = []
        pendingApprovals = []
        pendingInputs = []
        hasMoreHistory = false
        draft = nil
        lastReplayComplete = false
        expiredApprovalIds = []
        explicitlyExpiredApprovals = [:]
        staleEpochs = []
        itemIndexByID = [:]
    }

    /// Keep the last good view visible while a CURSOR_EXPIRED rebuild is in flight,
    /// but never resubscribe from the expired cursor if the snapshot request fails.
    public func discardCursorForSnapshotRebuild() {
        cursor = nil
        lastReplayComplete = false
        staleEpochs = []
    }

    // MARK: 草稿

    public func beginDraft(idempotencyKey: String, text: String = "") {
        draft = SessionDraft(text: text, idempotencyKey: idempotencyKey)
    }

    public func updateDraft(text: String) {
        guard var current = draft else { return }
        if current.text != text { current.idempotencyKey = "draft_\(UUID().uuidString)" }
        current.text = text
        draft = current
    }

    public func discardDraft() {
        draft = nil
    }

    // MARK: 快照

    /// 应用快照：**整体替换**本地视图，丢弃未完成草稿，不合并。
    ///
    /// `replayComplete` 只是上游对该快照覆盖范围的声明（契约 §3.2 规则 1 说明
    /// `replayComplete=false` 也必须整体替换），两种取值都执行替换；界面可据此显示同步态。
    @discardableResult
    public func applySnapshot(_ snapshot: RACPSnapshot, replayComplete: Bool) -> SessionSnapshotOutcome {
        let previousApprovalIds = Set(pendingApprovals.map(\.id))
        let deduplicated = Self.deduplicatedByID(snapshot.items)

        let snapshotEpoch = snapshot.cursor.epoch
        if let previousEpoch = cursor?.epoch, previousEpoch != snapshotEpoch {
            staleEpochs.insert(previousEpoch)
        }
        staleEpochs.remove(snapshotEpoch)

        items = deduplicated
        itemIndexByID = Self.indexByID(deduplicated)
        activeItems = snapshot.activeItems
        activeTurnId = Self.validTurnId(snapshot.activeTurn?.id)
            ?? Self.inferredActiveTurnId(from: snapshot.activeItems)
        queuedTurns = snapshot.queuedTurns
        queuedTurnIDs = Set(snapshot.queuedTurns.compactMap {
            $0.value(at: ["id"])?.stringValue
        })
        pendingApprovals = snapshot.pendingApprovals
        pendingInputs = snapshot.pendingInputs
        hasMoreHistory = snapshot.hasMoreHistory
        revision = snapshot.revision
        cursor = snapshot.cursor
        lastReplayComplete = replayComplete

        let discardedDraft = draft != nil
        draft = nil

        // 过期集合 = (原有过期 ∪ 本次从快照里消失的) − 仍然出现在快照 pendingApprovals 里的：
        // Reappearing cards recover, except a revision explicitly rejected by the server.
        let newApprovalIds = Set(snapshot.pendingApprovals.map(\.id))
        explicitlyExpiredApprovals = explicitlyExpiredApprovals.filter { id, rejected in
            guard let current = snapshot.pendingApprovals.first(where: { $0.id == id }) else { return false }
            return current.revision == nil || current.revision == rejected.revision
        }
        let expired = expiredApprovalIds
            .union(previousApprovalIds.subtracting(newApprovalIds))
            .subtracting(newApprovalIds)
            .union(explicitlyExpiredApprovals.keys)
            .sorted()
        expiredApprovalIds = Set(expired)

        // 返回值只报「本次快照新消失的」卡片：累计过期集合用于把卡片置灰，
        // 不能每次重建都当成新失效上报，否则界面会反复提示同一张卡。
        let newlyExpired = previousApprovalIds.subtracting(newApprovalIds).sorted()

        return SessionSnapshotOutcome(
            itemCount: items.count,
            discardedDraft: discardedDraft,
            newlyExpiredApprovalIds: newlyExpired
        )
    }

    // MARK: 事件

    /// 应用一批事件。
    ///
    /// - 已被快照替换掉的旧 epoch（`staleEpochs`）的重放帧 → 丢弃，不触发重建（保住未发送草稿）；
    /// - epoch 变化 → 返回 `.requiresSnapshotRebuild(.epochChanged)`，不应用该批事件；
    /// - sequence ≤ 当前游标 → 视为重复/过期，忽略；
    /// - 携带 `item` 的事件按 `item.id` 去重：已存在则就地更新，不存在则追加。
    @discardableResult
    public func applyEvents(_ events: [RACPEvent]) -> SessionEventsOutcome {
        guard !events.isEmpty else { return .applied(appended: 0, updated: 0, ignored: 0) }

        // 1) 陈旧 epoch 的重放帧先单独丢弃：它们属于已被快照替换掉的 epoch，
        //    按「epoch 变化」处理会触发重建并清空用户未发送的草稿。
        var ignored = 0
        var candidates: [RACPEvent] = []
        candidates.reserveCapacity(events.count)
        for event in events {
            if let epoch = event.epoch, staleEpochs.contains(epoch) {
                ignored += 1
                continue
            }
            candidates.append(event)
        }

        // 2) 再对本批事件做 epoch 判定：陈旧 epoch 已在上面丢弃，剩下的 epoch 变化都是真变化
        //    （新 epoch 的 sequence 可能回到 1，因此不能用 sequence 过滤掉这次判定）。
        if let currentCursor = cursor {
            for event in candidates {
                if let epoch = event.epoch, epoch != currentCursor.epoch {
                    return .requiresSnapshotRebuild(.epochChanged(from: currentCursor.epoch, to: epoch))
                }
            }
        }

        // 不对 sequence 连续性做判定。`sequence` 是 Host 的**全局**持久游标
        // （契约 §3.2），同一订阅里只会收到本会话的事件，其它会话/主机事件的
        // 序号会自然穿插进来，因此「本会话序号不连续」是常态而非丢事件。
        // 真正的缺口由服务端以 `CURSOR_EXPIRED` / `replayComplete=false` 显式
        // 告知（契约 §3.2 规则 4），客户端据此重建，见 requiresCursorReset。

        var appended = 0
        var updated = 0

        for event in candidates {
            if let durableSequence = event.durableSequence {
                if let current = cursor, durableSequence <= current.sequence {
                    ignored += 1
                    continue
                }
                let epoch = event.epoch ?? cursor?.epoch ?? Self.unknownEpoch
                cursor = RACPCursor(epoch: epoch, sequence: durableSequence)
            }

            reduceTurnLifecycle(event)
            reduceApprovalLifecycle(event)
            reduceInputLifecycle(event)
            guard let item = event.item else { continue }
            // Host v1 events nest the delta under `payload.event.deltaText`; the
            // v2 contract flattens it to `payload.delta`. Accept both shapes.
            let deltaText =
                event.payload.value(at: ["payload", "event", "deltaText"])?.stringValue
                ?? event.payload.value(at: ["payload", "delta"])?.stringValue
            let kind = event.payload.value(at: ["kind"])?.stringValue
            // 契约 §7.2：`item.delta` 与 `tool.updated` 都是**追加**语义的增量帧
            // （工具卡片的 `delta` 同样只携带新到的片段）。两者必须走同一条累计
            // 路径，否则工具卡片的正文永远不会出现（回归：卡片只显示
            // 「服务器没有返回工具输出正文。」）。
            if (kind == "item.delta" || kind == "tool.updated"), let delta = deltaText {
                if let index = itemIndexByID[item.id] {
                    items[index] = items[index].applyingTextDelta(delta)
                    updated += 1
                } else {
                    let initialItem = item.applyingTextDelta(delta)
                    itemIndexByID[item.id] = items.count
                    items.append(initialItem)
                    appended += 1
                }
                continue
            }
            if let index = itemIndexByID[item.id] {
                // 后续帧（`tool.completed` 等）不重复携带 `tool.started` 的元数据，
                // 就地更新时保留工具名与已到达的正文，见 `RACPItem.mergingUpdate`。
                let merged = item.mergingUpdate(from: items[index])
                if items[index] == merged {
                    ignored += 1
                } else {
                    items[index] = merged
                    updated += 1
                }
            } else {
                itemIndexByID[item.id] = items.count
                items.append(item)
                appended += 1
            }
        }

        return .applied(appended: appended, updated: updated, ignored: ignored)
    }

    // MARK: 查询

    public func item(id: String) -> RACPItem? {
        guard let index = itemIndexByID[id] else { return nil }
        return items[index]
    }

    public func approval(id: String) -> RACPApprovalRequest? {
        pendingApprovals.first { $0.id == id }
    }

    /// `approval/respond` 的 `context.expectedRevision`：只取快照里该卡自己的 revision
    /// （AC-14.6：重建后点同一条必须用快照里的 revision）。卡片不在快照里时返回 `nil`，
    /// 不拿会话 revision 顶替——那会让一个已失效的请求看起来还能提交。
    public func expectedRevisionForApproval(id: String) -> Int? {
        approval(id: id)?.revision
    }

    public func input(id: String) -> RACPInputRequest? {
        pendingInputs.first { $0.id == id }
    }

    public func expectedRevisionForInput(id: String) -> Int? {
        input(id: id)?.revision
    }

    /// 用户确认过「已过期」提示后清空该集合（只清展示标记，不恢复卡片）。
    public func markSnapshotExpiredApprovalsCleared() {
        expiredApprovalIds = Set(explicitlyExpiredApprovals.keys)
    }

    /// Server explicitly rejected this card as stale/expired; block repeated submission.
    public func markApprovalExpired(id: String) {
        if let card = approval(id: id) { explicitlyExpiredApprovals[id] = card }
        expiredApprovalIds.insert(id)
    }

    // MARK: 内部

    /// Apply a turn lifecycle event only after its durable sequence has been
    /// accepted. A late terminal event for the previous turn must not clear a
    /// replacement turn that is already running.
    private func reduceTurnLifecycle(_ event: RACPEvent) {
        // v2 golden（`docs/api/pi-adaptor.golden.json`）把 turn id 放在 `payload.turn.id`，
        // 无顶层 `turnId`；现网 Host 两者都带。优先顶层以兼容旧形态，缺失时回退到 `payload.turn.id`，
        // 否则严格按冻结契约实现的 Host 会让 turn.completed/interrupted 无法清除运行态，
        // 会话永久停在「正在运行」。
        guard let kind = event.payload.value(at: ["kind"])?.stringValue,
              let turnId = Self.validTurnId(
                event.payload.value(at: ["turnId"])?.stringValue
                  ?? event.payload.value(at: ["payload", "turn", "id"])?.stringValue
                  ?? event.payload.value(at: ["turn", "id"])?.stringValue
                  ?? event.payload.value(at: ["payload", "turnId"])?.stringValue
              )
        else { return }
        switch kind {
        case "turn.queued":
            if activeTurnId != turnId, !queuedTurnIDs.contains(turnId) {
                recordQueuedTurn(id: turnId, text: nil)
            }
        case "turn.started":
            activeTurnId = turnId
            removeQueuedTurn(id: turnId)
        case "turn.completed", "turn.interrupted", "turn.failed", "turn.canceled":
            if activeTurnId == turnId {
                activeTurnId = nil
                activeItems.removeAll()
            }
            removeQueuedTurn(id: turnId)
        default:
            break
        }
    }

    public func recordActiveTurn(id: String?) {
        activeTurnId = Self.validTurnId(id)
    }

    /// Reduce live `approval.*` frames into `pendingApprovals`.
    ///
    /// The Host emits a tool approval as a live session event, not as a history
    /// item, so without this the card never appears and the tool call waits
    /// forever for a decision that cannot be made (the model never receives a
    /// tool result). Snapshot replay covers reattach; this covers the live path.
    private func reduceApprovalLifecycle(_ event: RACPEvent) {
        guard let kind = event.payload.value(at: ["kind"])?.stringValue else { return }
        switch kind {
        case "approval.requested":
            guard let approvalValue = event.payload.value(at: ["payload", "approval"]),
                  let request = try? RACPApprovalRequest(payload: approvalValue)
            else { return }
            if let index = pendingApprovals.firstIndex(where: { $0.id == request.id }) {
                pendingApprovals[index] = request
            } else {
                pendingApprovals.append(request)
            }
            // A re-requested card is live again: clear any stale "expired" marks.
            expiredApprovalIds.remove(request.id)
            explicitlyExpiredApprovals[request.id] = nil
        case "approval.resolved":
            guard let approvalId = event.payload.value(at: ["payload", "approvalId"])?.stringValue
            else { return }
            pendingApprovals.removeAll { $0.id == approvalId }
            expiredApprovalIds.remove(approvalId)
            explicitlyExpiredApprovals[approvalId] = nil
        default:
            break
        }
    }

    /// Reduce live `input.*` frames into `pendingInputs`.
    ///
    /// Contract §7.2 defines `input.requested` / `input.resolved` as live session
    /// events, not history items. Without this an online follow-up question never
    /// appears, and a resolved card never disappears.
    private func reduceInputLifecycle(_ event: RACPEvent) {
        guard let kind = event.payload.value(at: ["kind"])?.stringValue else { return }
        switch kind {
        case "input.requested":
            guard let inputValue = event.payload.value(at: ["payload", "input"]),
                  let request = try? RACPInputRequest(payload: inputValue)
            else { return }
            if let index = pendingInputs.firstIndex(where: { $0.id == request.id }) {
                pendingInputs[index] = request
            } else {
                pendingInputs.append(request)
            }
        case "input.resolved":
            // Contract payload is `{inputId, status}`; accept a nested id too for
            // Host versions that echo the whole input object.
            guard let inputId = event.payload.value(at: ["payload", "inputId"])?.stringValue
                ?? event.payload.value(at: ["payload", "input", "id"])?.stringValue
            else { return }
            pendingInputs.removeAll { $0.id == inputId }
        default:
            break
        }
    }

    public func recordQueuedTurn(id: String, text: String?) {
        guard !id.isEmpty else { return }
        queuedTurnIDs.insert(id)
        guard !queuedTurns.contains(where: { $0.value(at: ["id"])?.stringValue == id }) else { return }
        var payload: [String: JSONValue] = ["id": .string(id)]
        if let text, !text.isEmpty { payload["text"] = .string(text) }
        queuedTurns.append(.object(payload))
    }

    public func removeQueuedTurn(id: String) {
        queuedTurnIDs.remove(id)
        queuedTurns.removeAll { $0.value(at: ["id"])?.stringValue == id }
    }

    private static func inferredActiveTurnId(from activeItems: [RACPItem]) -> String? {
        let ids = Set(activeItems.compactMap(\.turnId).filter { !$0.isEmpty })
        return ids.count == 1 ? ids.first : nil
    }

    private static func validTurnId(_ raw: String?) -> String? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return raw
    }

    static let unknownEpoch = "unknown"

    private static func deduplicatedByID(_ source: [RACPItem]) -> [RACPItem] {
        var seen = Set<String>()
        var result: [RACPItem] = []
        result.reserveCapacity(source.count)
        for item in source where seen.insert(item.id).inserted {
            result.append(item)
        }
        return result
    }

    private static func indexByID(_ source: [RACPItem]) -> [String: Int] {
        var index: [String: Int] = [:]
        index.reserveCapacity(source.count)
        for (offset, item) in source.enumerated() {
            index[item.id] = offset
        }
        return index
    }
}
