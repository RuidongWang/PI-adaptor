import Foundation

// MARK: - 未冻结形状的通用处理

/// 契约 §3.2 只冻结了 `items[]` / `pendingApprovals[]` / `pendingInputs[]` 的**去重键**
/// （`item.id`）与快照骨架，元素内部字段没有冻结。因此这里把整个元素读成 `JSONValue`
/// 原样保留，只对 `id` 做硬约束；需要展示的字段走只读访问器，读不到就是 `nil`，
/// 不把猜测的键名写成必填字段。

/// 动态键：用于「不知道字段名但必须保留全部字段」的场景。
struct JSONObjectCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }

    init(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
    }
}

enum JSONObjectPayload {
    /// 把任意 JSON 对象整体读成一个 `.object` 值。
    static func decodeObject(from decoder: Decoder) throws -> JSONValue {
        let container = try decoder.container(keyedBy: JSONObjectCodingKey.self)
        var object: [String: JSONValue] = [:]
        for key in container.allKeys {
            object[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
        }
        return .object(object)
    }

    /// 同 `decodeObject`，但要求对象里有非空字符串 `id`。
    static func decodeIdentifyObject(from decoder: Decoder, type: String) throws -> (id: String, payload: JSONValue) {
        let payload = try decodeObject(from: decoder)
        guard let id = payload.value(at: ["id"])?.stringValue, !id.isEmpty else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "\(type) 缺少字符串字段 id"
                )
            )
        }
        return (id, payload)
    }
}

// MARK: - 会话条目

/// 会话/历史里的一条内容项（契约 §3.2、§6 `items` 表）。
///
/// - `id`：去重键，唯一强约束。
/// - `payload`：整条原始 JSON，未冻结的字段一律保留原样。
public struct RACPItem: Equatable, Sendable {
    public let id: String
    public let payload: JSONValue

    public init(id: String, payload: JSONValue) {
        self.id = id
        self.payload = payload
    }

    public init(payload: JSONValue) throws {
        guard let id = payload.value(at: ["id"])?.stringValue, !id.isEmpty else {
            throw RACPSessionModelError.missingIdentifier(type: "item")
        }
        self.init(id: id, payload: payload)
    }

    /// Host snapshots use `itemType + content`; older fixtures use `kind` and
    /// message fields at the top level. Accept both without changing storage.
    public var itemType: String? {
        payload.value(at: ["itemType"])?.stringValue
            ?? payload.value(at: ["kind"])?.stringValue
    }
    public var kind: String? { itemType }
    public var role: String? {
        payload.value(at: ["role"])?.stringValue
            ?? contentObject?.value(at: ["role"])?.stringValue
    }
    public var text: String? {
        if let text = payload.value(at: ["text"])?.stringValue { return text }
        if let content = contentObject {
            if let text = content.value(at: ["content"])?.stringValue { return text }
            if let text = content.stringValue { return text }
            // 工具结果：契约 §7.2 的 `tool.completed` 把 Pi 的 `AgentToolResult`
            // 放进 `result`（正文在 `result.content[].text`），流式阶段的
            // `tool.updated` 只给增量 `delta`。
            if let text = Self.toolResultText(content.value(at: ["result"])) { return text }
            if let delta = content.value(at: ["delta"])?.stringValue, !delta.isEmpty { return delta }
        }
        return contentObject?.value(at: ["error", "message"])?.stringValue
            ?? payload.value(at: ["error", "message"])?.stringValue
    }
    /// `AgentToolResult`（或已渲染成字符串的结果）→ 展示正文。
    private static func toolResultText(_ result: JSONValue?) -> String? {
        guard let result else { return nil }
        if let text = result.stringValue, !text.isEmpty { return text }
        if let text = result.value(at: ["text"])?.stringValue, !text.isEmpty { return text }
        if let text = result.value(at: ["content"])?.stringValue, !text.isEmpty { return text }
        guard let parts = result.value(at: ["content"])?.arrayValue else { return nil }
        let joined = parts
            .map { $0.value(at: ["text"])?.stringValue ?? $0.stringValue ?? "" }
            .joined()
        return joined.isEmpty ? nil : joined
    }

    public var toolName: String? {
        payload.value(at: ["toolName"])?.stringValue
            ?? contentObject?.value(at: ["toolName"])?.stringValue
    }
    public var status: String? {
        contentObject?.value(at: ["status"])?.stringValue
            ?? payload.value(at: ["status"])?.stringValue
    }
    /// 是否属于工具卡片条目（`tool.started` 之后的帧不再携带 `toolName`）。
    public var isToolItem: Bool {
        itemType == "tool" || toolName != nil || role == "tool" || role == "toolResult"
    }
    /// 就地更新同一条 `item.id` 时的字段保留规则。
    ///
    /// 契约 §7.2 只规定了 `tool.updated {itemId,delta}` 与
    /// `tool.completed {itemId,status,result}`：两者都不重复携带 `tool.started` 的
    /// `toolName`，且工具被拒/未执行时 `result` 可能为空。直接整体覆盖会让卡片
    /// 丢掉工具名，并把已经流式到达的正文又变回空（正是「服务器没有返回工具输出正文。」
    /// 的来源），因此就地更新必须保留前帧已有的工具名与正文。
    func mergingUpdate(from previous: RACPItem) -> RACPItem {
        guard previous.isToolItem, var object = payload.objectValue else { return self }
        if object["toolName"] == nil, let toolName = previous.toolName {
            object["toolName"] = .string(toolName)
        }
        if object["text"] == nil, text == nil, let previousText = previous.text, !previousText.isEmpty {
            object["text"] = .string(previousText)
        }
        return RACPItem(id: id, payload: .object(object))
    }
    public var turnId: String? { payload.value(at: ["turnId"])?.stringValue }
    public var attachments: [RACPV2Attachment] {
        guard let values = payload.value(at: ["attachments"])?.arrayValue,
              let data = try? JSONEncoder().encode(values),
              let decoded = try? JSONDecoder().decode([RACPV2Attachment].self, from: data)
        else { return [] }
        return decoded
    }

    private var contentObject: JSONValue? { payload.value(at: ["content"]) }

    /// Apply one append-only `item.delta` frame to the canonical message
    /// content while retaining role/tool/model metadata from the snapshot row.
    func applyingTextDelta(_ delta: String) -> RACPItem {
        guard !delta.isEmpty, var object = payload.objectValue else { return self }
        if var content = object["content"]?.objectValue {
            let previous = content["content"]?.stringValue ?? ""
            content["content"] = .string(previous + delta)
            object["content"] = .object(content)
        } else {
            object["text"] = .string((object["text"]?.stringValue ?? "") + delta)
        }
        return RACPItem(id: id, payload: .object(object))
    }
}

extension RACPItem: Codable {
    public init(from decoder: Decoder) throws {
        let decoded = try JSONObjectPayload.decodeIdentifyObject(from: decoder, type: "item")
        self.init(id: decoded.id, payload: decoded.payload)
    }

    public func encode(to encoder: Encoder) throws {
        try payload.encode(to: encoder)
    }
}

// MARK: - 待处理卡片

/// 快照 `pendingApprovals[]` 的一项。`revision` 取自快照，是 `approval/respond` 的
/// `context.expectedRevision` 来源（spec AC-14.6）。
public struct RACPApprovalRequest: Equatable, Sendable {
    public let id: String
    public let payload: JSONValue

    public init(id: String, payload: JSONValue) {
        self.id = id
        self.payload = payload
    }

    public init(payload: JSONValue) throws {
        guard let id = payload.value(at: ["id"])?.stringValue, !id.isEmpty else {
            throw RACPSessionModelError.missingIdentifier(type: "approval")
        }
        self.init(id: id, payload: payload)
    }

    public var revision: Int? { payload.value(at: ["revision"])?.intValue }
    public var status: String? { payload.value(at: ["status"])?.stringValue }
    /// 工具名等摘要字段——未冻结，读不到返回 `nil`。
    public var toolName: String? { payload.value(at: ["toolName"])?.stringValue }
}

extension RACPApprovalRequest: Codable {
    public init(from decoder: Decoder) throws {
        let decoded = try JSONObjectPayload.decodeIdentifyObject(from: decoder, type: "approval")
        self.init(id: decoded.id, payload: decoded.payload)
    }

    public func encode(to encoder: Encoder) throws {
        try payload.encode(to: encoder)
    }
}

/// 快照 `pendingInputs[]` 的一项；`answers` 顺序与该卡的问题顺序对齐（契约 §3.1）。
public struct RACPInputRequest: Equatable, Sendable {
    public let id: String
    public let payload: JSONValue

    public init(id: String, payload: JSONValue) {
        self.id = id
        self.payload = payload
    }

    public init(payload: JSONValue) throws {
        guard let id = payload.value(at: ["id"])?.stringValue, !id.isEmpty else {
            throw RACPSessionModelError.missingIdentifier(type: "input")
        }
        self.init(id: id, payload: payload)
    }

    public var revision: Int? { payload.value(at: ["revision"])?.intValue }
    public var status: String? { payload.value(at: ["status"])?.stringValue }
    public var questionCount: Int? { payload.value(at: ["questions"])?.arrayValue?.count }
}

extension RACPInputRequest: Codable {
    public init(from decoder: Decoder) throws {
        let decoded = try JSONObjectPayload.decodeIdentifyObject(from: decoder, type: "input")
        self.init(id: decoded.id, payload: decoded.payload)
    }

    public func encode(to encoder: Encoder) throws {
        try payload.encode(to: encoder)
    }
}

// MARK: - 快照

/// `session/attach` 的 `snapshot`（契约 §3.2 形状）。
public struct RACPSnapshot: Equatable, Sendable {
    public var cursor: RACPCursor
    public var revision: Int
    public var items: [RACPItem]
    public var activeItems: [RACPItem]
    /// Host's authoritative running/waiting turn, when present.
    public var activeTurn: RACPTurnRef?
    /// `queuedTurns` 的元素形状在 FROZEN 契约里未定义，保留原始 JSON。
    public var queuedTurns: [JSONValue]
    public var pendingApprovals: [RACPApprovalRequest]
    public var pendingInputs: [RACPInputRequest]
    public var hasMoreHistory: Bool

    public init(
        cursor: RACPCursor,
        revision: Int,
        items: [RACPItem] = [],
        activeItems: [RACPItem] = [],
        activeTurn: RACPTurnRef? = nil,
        queuedTurns: [JSONValue] = [],
        pendingApprovals: [RACPApprovalRequest] = [],
        pendingInputs: [RACPInputRequest] = [],
        hasMoreHistory: Bool = false
    ) {
        self.cursor = cursor
        self.revision = revision
        self.items = items
        self.activeItems = activeItems
        self.activeTurn = activeTurn
        self.queuedTurns = queuedTurns
        self.pendingApprovals = pendingApprovals
        self.pendingInputs = pendingInputs
        self.hasMoreHistory = hasMoreHistory
    }
}

extension RACPSnapshot: Codable {
    private enum CodingKeys: String, CodingKey {
        case cursor, revision, items, activeItems, activeTurn, queuedTurns, pendingApprovals, pendingInputs, hasMoreHistory
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // `cursor` 是增量续传的唯一依据（§3.2 规则 3），缺失即无法继续，必须报错。
        cursor = try container.decode(RACPCursor.self, forKey: .cursor)
        revision = try container.decode(Int.self, forKey: .revision)
        items = try container.decodeIfPresent([RACPItem].self, forKey: .items) ?? []
        activeItems = try container.decodeIfPresent([RACPItem].self, forKey: .activeItems) ?? []
        activeTurn = try container.decodeIfPresent(RACPTurnRef.self, forKey: .activeTurn)
        queuedTurns = try container.decodeIfPresent([JSONValue].self, forKey: .queuedTurns) ?? []
        pendingApprovals = try container.decodeIfPresent([RACPApprovalRequest].self, forKey: .pendingApprovals) ?? []
        pendingInputs = try container.decodeIfPresent([RACPInputRequest].self, forKey: .pendingInputs) ?? []
        hasMoreHistory = try container.decodeIfPresent(Bool.self, forKey: .hasMoreHistory) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(cursor, forKey: .cursor)
        try container.encode(revision, forKey: .revision)
        try container.encode(items, forKey: .items)
        try container.encode(activeItems, forKey: .activeItems)
        try container.encodeIfPresent(activeTurn, forKey: .activeTurn)
        try container.encode(queuedTurns, forKey: .queuedTurns)
        try container.encode(pendingApprovals, forKey: .pendingApprovals)
        try container.encode(pendingInputs, forKey: .pendingInputs)
        try container.encode(hasMoreHistory, forKey: .hasMoreHistory)
    }
}

/// 会话模型层错误。
public enum RACPSessionModelError: Error, Equatable, CustomStringConvertible {
    case missingIdentifier(type: String)

    public var description: String {
        switch self {
        case let .missingIdentifier(type):
            return "\(type) 缺少字符串字段 id"
        }
    }
}
