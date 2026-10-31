import Foundation

// MARK: - 标识与帧

/// JSON-RPC 2.0 的 `id`：允许整数或字符串（契约 §3.1 未限制形态）。
public enum RACPIdentifier: Hashable, Codable, Sendable {
    case number(Int)
    case string(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self = .number(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        }
    }
}

/// P0 使用的 RACP 操作子集（契约 §3.1 与 spec §6.0）。
public enum RACPMethod: String, CaseIterable, Sendable {
    case initialize = "connection/initialize"
    case ping = "connection/ping"
    case pair = "connection/pair"
    case projectList = "project/list"
    case projectBrowse = "project/browse"
    case projectRegister = "project/register"
    case sessionList = "session/list"
    case sessionGet = "session/get"
    case sessionCreate = "session/create"
    case sessionAttach = "session/attach"
    case sessionHistory = "session/history"
    case sessionConfigure = "session/configure"
    case sessionRevoke = "session/revoke"
    case eventsSubscribe = "events/subscribe"
    case eventsUnsubscribe = "events/unsubscribe"
    case eventsAck = "events/ack"
    case turnStart = "turn/start"
    case turnGet = "turn/get"
    case turnStop = "turn/stop"
    case turnInterrupt = "turn/interrupt"
    case turnCancel = "turn/cancel"
    case turnPrioritize = "turn/prioritize"
    case approvalRespond = "approval/respond"
    case inputRespond = "input/respond"
    /// 通知，无 `id`、无响应。
    case initializedNotification = "notifications/initialized"
}

/// 出站请求。`params` 用泛型保证每个方法只能携带自己的参数类型。
public struct RACPRequest<Params: Encodable & Sendable>: Encodable, Sendable {
    public let jsonrpc: String = "2.0"
    public let id: RACPIdentifier
    public let method: String
    public let params: Params

    public init(id: RACPIdentifier, method: RACPMethod, params: Params) {
        self.id = id
        self.method = method.rawValue
        self.params = params
    }
}

/// 出站通知（`notifications/initialized`）。
public struct RACPNotification<Params: Encodable & Sendable>: Encodable, Sendable {
    public let jsonrpc: String = "2.0"
    public let method: String
    public let params: Params

    public init(method: RACPMethod, params: Params) {
        self.method = method.rawValue
        self.params = params
    }
}

/// 入站帧：响应（带 `id`）或通知/事件（带 `method`）。
public struct RACPIncomingFrame: Decodable, Sendable {
    public let id: RACPIdentifier?
    public let method: String?
    public let result: JSONValue?
    public let error: RACPErrorBody?

    public var isResponse: Bool { id != nil && method == nil }

    private enum CodingKeys: String, CodingKey {
        case id, method, result, error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(RACPIdentifier.self, forKey: .id)
        method = try container.decodeIfPresent(String.self, forKey: .method)
        result = try container.decodeIfPresent(JSONValue.self, forKey: .result)
        error = try container.decodeIfPresent(RACPErrorBody.self, forKey: .error)
    }

    /// 响应成功时取 `result`；缺 `result` 视为协议异常。
    public func decodeResult<T: Decodable>(as type: T.Type) throws -> T {
        guard let result else {
            throw RACPWireError.missingResult(method: method)
        }
        return try T.decoded(from: result)
    }
}

public enum RACPWireError: Error, Equatable {
    case missingResult(method: String?)
}

// MARK: - 错误模型

/// JSON-RPC 错误体。`code` 上游可能给字符串（契约 §7 的枚举）或数字，这里都保留原值。
public struct RACPErrorBody: Decodable, Equatable, Sendable {
    public let code: String
    public let message: String?
    public let data: JSONValue?

    private enum CodingKeys: String, CodingKey {
        case code, message, data
    }

    public init(code: String, message: String? = nil, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let text = try? container.decode(String.self, forKey: .code) {
            code = text
        } else {
            code = String(try container.decode(Int.self, forKey: .code))
        }
        message = try container.decodeIfPresent(String.self, forKey: .message)
        data = try container.decodeIfPresent(JSONValue.self, forKey: .data)
    }

    /// 归一为契约 §7 的错误码；未列出的原样保留（不静默吞掉）。
    public var normalizedCode: RACPErrorCode { RACPErrorCode(raw: code) }
}

/// 契约 §7 的错误码集合。
public enum RACPErrorCode: Equatable, Sendable {
    case unauthorized
    case forbidden
    case protocolMismatch
    case invalidArgument
    case notFound
    case methodNotFound
    case agentUnavailable
    case agentBusy
    case conflict
    case idempotencyConflict
    case cursorExpired
    case clientTooSlow
    case approvalExpired
    case approvalStale
    case payloadTooLarge
    case rateLimited
    case pairingFailed
    case pairingTokenExpired
    case capabilityUnavailable
    case serverInternal
    /// 契约未列出的码，原样展示，不得静默归类为成功。
    case unknown(String)

    public init(raw: String) {
        switch raw {
        case "UNAUTHORIZED": self = .unauthorized
        case "FORBIDDEN": self = .forbidden
        case "PROTOCOL_MISMATCH": self = .protocolMismatch
        case "INVALID_ARGUMENT": self = .invalidArgument
        case "NOT_FOUND": self = .notFound
        case "METHOD_NOT_FOUND": self = .methodNotFound
        case "AGENT_UNAVAILABLE": self = .agentUnavailable
        case "AGENT_BUSY": self = .agentBusy
        case "CONFLICT": self = .conflict
        case "IDEMPOTENCY_CONFLICT": self = .idempotencyConflict
        case "CURSOR_EXPIRED": self = .cursorExpired
        case "CLIENT_TOO_SLOW": self = .clientTooSlow
        case "APPROVAL_EXPIRED": self = .approvalExpired
        case "APPROVAL_STALE": self = .approvalStale
        case "PAYLOAD_TOO_LARGE": self = .payloadTooLarge
        case "RATE_LIMITED": self = .rateLimited
        case "PAIRING_FAILED": self = .pairingFailed
        case "PAIRING_TOKEN_EXPIRED": self = .pairingTokenExpired
        case "CAPABILITY_UNAVAILABLE": self = .capabilityUnavailable
        case "INTERNAL": self = .serverInternal
        default: self = .unknown(raw)
        }
    }

    /// 契约 §7「可重试」列。
    public var isRetryable: Bool {
        switch self {
        case .agentUnavailable, .conflict, .clientTooSlow, .rateLimited, .serverInternal:
            return true
        default:
            return false
        }
    }

    public var action: RACPClientAction {
        switch self {
        case .unauthorized: return .clearTokenAndRepair
        case .forbidden: return .surfacePermissionDenied
        case .protocolMismatch: return .stopConnecting
        case .invalidArgument: return .showFieldErrors
        case .notFound: return .refreshListsAndDropOrphans
        case .methodNotFound: return .treatAsMissingCapability
        case .agentUnavailable: return .backoffReconnect
        case .agentBusy: return .queueOrReportQueueFull
        case .conflict: return .refetchThenRetryOnce
        case .idempotencyConflict: return .requireManualConfirmation
        case .cursorExpired: return .rebuildFromSnapshot
        case .clientTooSlow: return .resubscribeThenRebuild
        case .approvalExpired, .approvalStale: return .markApprovalStale
        case .payloadTooLarge: return .askToShortenInput
        case .rateLimited: return .retryAfterBackoff
        case .pairingFailed, .pairingTokenExpired: return .restartHostForNewToken
        case .capabilityUnavailable: return .hideOrDisableEntry
        case .serverInternal: return .recordTraceAndRetryOnce
        case .unknown: return .displayVerbatim
        }
    }
}

/// 契约 §7「客户端行为」列的可执行枚举，交给上层（连接层/界面）决策。
public enum RACPClientAction: Equatable, Sendable {
    case clearTokenAndRepair
    case surfacePermissionDenied
    case stopConnecting
    case showFieldErrors
    case refreshListsAndDropOrphans
    case treatAsMissingCapability
    case backoffReconnect
    case queueOrReportQueueFull
    case refetchThenRetryOnce
    case requireManualConfirmation
    case rebuildFromSnapshot
    case resubscribeThenRebuild
    case markApprovalStale
    case askToShortenInput
    case retryAfterBackoff
    case restartHostForNewToken
    case hideOrDisableEntry
    case recordTraceAndRetryOnce
    case displayVerbatim
}

// MARK: - 公共结构

/// 契约 §3.1 的 `context`：`requestId` 必填。
public struct RACPContext: Codable, Equatable, Sendable {
    public var requestId: String
    public var idempotencyKey: String?
    public var expectedRevision: Int?
    public var traceparent: String?

    public init(
        requestId: String,
        idempotencyKey: String? = nil,
        expectedRevision: Int? = nil,
        traceparent: String? = nil
    ) {
        self.requestId = requestId
        self.idempotencyKey = idempotencyKey
        self.expectedRevision = expectedRevision
        self.traceparent = traceparent
    }
}

/// 事件游标。禁止用墙钟时间做增量判断（契约 §3.2 规则 3）。
public struct RACPCursor: Codable, Equatable, Sendable {
    public var epoch: String
    public var sequence: Int

    public init(epoch: String, sequence: Int) {
        self.epoch = epoch
        self.sequence = sequence
    }
}

public enum RACPPermissionMode: String, Codable, CaseIterable, Sendable {
    case ask
    case acceptEdits = "accept-edits"
    case auto
}

public enum RACPSessionMode: String, Codable, CaseIterable, Sendable {
    case agent
    case plan
    case goal
}

public enum RACPThinkingLevel: String, Codable, CaseIterable, Sendable {
    case off, minimal, low, medium, high, xhigh, max
}

public enum RACPSubscriptionScope: String, Codable, Sendable {
    case session
    case host
}

public enum RACPTurnAdmission: String, Codable, Sendable {
    case rejectIfBusy = "reject_if_busy"
    case queue
}

/// 工具类审批决策；Plan/Goal 契约用 `approve | reject`（见 `RACPContractDecision`）。
public enum RACPApprovalDecision: String, Codable, Sendable {
    case allowOnce = "allow-once"
    case allowSession = "allow-session"
    case deny
}

public enum RACPContractDecision: String, Codable, Sendable {
    case approve
    case reject
}

// MARK: - 参数（P0 子集）

public struct RACPClientInfo: Codable, Equatable, Sendable {
    public var name: String
    public var version: String

    public init(name: String = "PI-IOS", version: String) {
        self.name = name
        self.version = version
    }
}

public struct RACPClientCapabilities: Codable, Equatable, Sendable {
    public var eventReplay: Bool?
    public var approvals: Bool?
    public var inputRequests: Bool?
    public var turnQueue: Bool?
    public var hostEvents: Bool?
    public var history: Bool?

    /// P0 口径：除 `attachments` 外全为 true（契约 §2.2）。
    public static let p0 = RACPClientCapabilities(
        eventReplay: true,
        approvals: true,
        inputRequests: true,
        turnQueue: true,
        hostEvents: true,
        history: true
    )

    public init(
        eventReplay: Bool? = nil,
        approvals: Bool? = nil,
        inputRequests: Bool? = nil,
        turnQueue: Bool? = nil,
        hostEvents: Bool? = nil,
        history: Bool? = nil
    ) {
        self.eventReplay = eventReplay
        self.approvals = approvals
        self.inputRequests = inputRequests
        self.turnQueue = turnQueue
        self.hostEvents = hostEvents
        self.history = history
    }
}

public struct RACPInitializeParams: Codable, Equatable, Sendable {
    public var protocolVersion: String
    public var client: RACPClientInfo
    public var bindings: [String]
    public var capabilities: RACPClientCapabilities
    public var maxReceiveBytes: Int

    public static let protocolVersion = "1.0"

    public init(
        protocolVersion: String = RACPInitializeParams.protocolVersion,
        client: RACPClientInfo,
        bindings: [String] = ["RACP-WS"],
        capabilities: RACPClientCapabilities = .p0,
        maxReceiveBytes: Int = 1_048_576
    ) {
        self.protocolVersion = protocolVersion
        self.client = client
        self.bindings = bindings
        self.capabilities = capabilities
        self.maxReceiveBytes = maxReceiveBytes
    }
}

public struct RACPEmptyParams: Codable, Equatable, Sendable {
    public init() {}
}

public struct RACPPairParams: Codable, Equatable, Sendable {
    public var deviceLabel: String?

    public init(deviceLabel: String? = nil) {
        self.deviceLabel = deviceLabel
    }
}

public struct RACPPairResult: Codable, Equatable, Sendable {
    public var deviceId: String
    public var deviceToken: String
    public var roles: [String]
}

public struct RACPProjectSummary: Codable, Equatable, Sendable {
    public var id: String
    public var label: String?
    public var archived: Bool?
}

public struct RACPProjectListResult: Codable, Equatable, Sendable {
    public var projects: [RACPProjectSummary]
}

public struct RACPProjectBrowseParams: Codable, Equatable, Sendable {
    public var path: String?

    public init(path: String? = nil) {
        self.path = path
    }
}

public struct RACPProjectBrowseResult: Codable, Equatable, Sendable {
    public var path: String
    /// Host 在非浏览根目录时返回上级；根目录没有该字段。
    public var parent: String?
    /// 上游 `entries` 的元素形状未在 FROZEN 契约中定义，保留原始 JSON。
    public var entries: [JSONValue]
}

public struct RACPProjectRegisterParams: Codable, Equatable, Sendable {
    public var path: String

    public init(path: String) {
        self.path = path
    }
}

public struct RACPProjectRegisterResult: Codable, Equatable, Sendable {
    public var project: RACPProjectSummary
}

public struct RACPSessionSummary: Codable, Equatable, Sendable {
    public var id: String
    public var title: String?
    public var projectId: String?
    public var status: String?
    public var revision: Int?
    /// `session/get` / `session/attach` expose the Host's currently running turn.
    /// This is needed to interrupt a turn that was promoted from the Host queue.
    public var activeTurnId: String? = nil
    public var mode: RACPSessionMode?
    public var permissionMode: RACPPermissionMode?
    // 注意：此处**不**声明 providerId / modelId / thinkingLevel。
    // 上游 RacpSessionSchema（packages/shared/src/racp.ts）没有这三个字段，
    // `session/get` 也不会返回它们——它们只是 session/create 与 session/configure 的入参。
    // 「会话当前绑定哪个模型、是否可用」必须走删除增量里新增的只读查询能力，
    // 不要在这个投影上建 AC-05.2 / AC-06.2 的 UI，否则拿到的恒为 nil。
}

public struct RACPSessionListResult: Codable, Equatable, Sendable {
    public var sessions: [RACPSessionSummary]
}

public struct RACPSessionGetParams: Codable, Equatable, Sendable {
    public var sessionId: String

    public init(sessionId: String) {
        self.sessionId = sessionId
    }
}

public struct RACPSessionGetResult: Codable, Equatable, Sendable {
    public var session: RACPSessionSummary
}

public struct RACPSessionCreateParams: Codable, Equatable, Sendable {
    public var title: String?
    public var projectId: String?
    public var mode: RACPSessionMode?
    public var providerId: String?
    public var modelId: String?
    public var thinkingLevel: RACPThinkingLevel?
    public var permissionMode: RACPPermissionMode?

    public init(
        title: String? = nil,
        projectId: String? = nil,
        mode: RACPSessionMode? = nil,
        providerId: String? = nil,
        modelId: String? = nil,
        thinkingLevel: RACPThinkingLevel? = nil,
        permissionMode: RACPPermissionMode? = nil
    ) {
        self.title = title
        self.projectId = projectId
        self.mode = mode
        self.providerId = providerId
        self.modelId = modelId
        self.thinkingLevel = thinkingLevel
        self.permissionMode = permissionMode
    }
}

public struct RACPSessionCreateResult: Codable, Equatable, Sendable {
    public var session: RACPSessionSummary
}

public struct RACPSessionConfigureParams: Codable, Equatable, Sendable {
    public var sessionId: String
    public var mode: RACPSessionMode?
    public var providerId: String?
    public var modelId: String?
    public var thinkingLevel: RACPThinkingLevel?
    public var permissionMode: RACPPermissionMode?

    public init(
        sessionId: String,
        mode: RACPSessionMode? = nil,
        providerId: String? = nil,
        modelId: String? = nil,
        thinkingLevel: RACPThinkingLevel? = nil,
        permissionMode: RACPPermissionMode? = nil
    ) {
        self.sessionId = sessionId
        self.mode = mode
        self.providerId = providerId
        self.modelId = modelId
        self.thinkingLevel = thinkingLevel
        self.permissionMode = permissionMode
    }
}

public struct RACPSessionConfigureResult: Codable, Equatable, Sendable {
    public var session: RACPSessionSummary
}

public struct RACPSessionRevokeParams: Codable, Equatable, Sendable {
    public var deviceId: String

    public init(deviceId: String) {
        self.deviceId = deviceId
    }
}

public struct RACPSessionRevokeResult: Codable, Equatable, Sendable {
    public var revoked: Bool
}

public struct RACPSessionHistoryParams: Codable, Equatable, Sendable {
    public var sessionId: String
    public var beforeItemId: String?
    /// 默认 100，上限 200（契约 §3.1）。
    public var limit: Int?

    public static let maxLimit = 200
    public static let defaultLimit = 100

    public init(sessionId: String, beforeItemId: String? = nil, limit: Int? = nil) {
        self.sessionId = sessionId
        self.beforeItemId = beforeItemId
        self.limit = limit.map { min($0, RACPSessionHistoryParams.maxLimit) }
    }
}

public struct RACPSessionHistoryResult: Codable, Equatable, Sendable {
    public var items: [RACPItem]
    public var hasMore: Bool?
    public var revision: Int?
}

public struct RACPEventsSubscribeParams: Codable, Equatable, Sendable {
    public var scope: RACPSubscriptionScope
    public var sessionId: String?
    public var after: RACPCursor?

    public init(scope: RACPSubscriptionScope, sessionId: String? = nil, after: RACPCursor? = nil) {
        self.scope = scope
        self.sessionId = sessionId
        self.after = after
    }
}

public struct RACPEventsSubscribeResult: Codable, Equatable, Sendable {
    public var subscriptionId: String
    public var starting: RACPCursor?
    public var replayComplete: Bool?
}

public struct RACPEventsUnsubscribeParams: Codable, Equatable, Sendable {
    public var subscriptionId: String

    public init(subscriptionId: String) {
        self.subscriptionId = subscriptionId
    }
}

public struct RACPEventsAckParams: Codable, Equatable, Sendable {
    public var subscriptionId: String
    public var sequence: Int

    public init(subscriptionId: String, sequence: Int) {
        self.subscriptionId = subscriptionId
        self.sequence = sequence
    }
}

public struct RACPTurnInput: Codable, Equatable, Sendable {
    public var text: String
    /// P0 恒为空数组：非空 attachments 会返回 CAPABILITY_UNAVAILABLE（契约 §3.1）。
    public var attachments: [JSONValue]
    public var sessionMessageId: String?
    public var messageId: String?

    public init(
        text: String,
        attachments: [JSONValue] = [],
        sessionMessageId: String? = nil,
        messageId: String? = nil
    ) {
        self.text = text
        self.attachments = attachments
        self.sessionMessageId = sessionMessageId
        self.messageId = messageId
    }
}

public struct RACPTurnStartParams: Codable, Equatable, Sendable {
    public var sessionId: String
    /// 只放在 `context.idempotencyKey`，顶层不再传（契约 §3.1 要点）。
    public var admission: RACPTurnAdmission?
    public var input: RACPTurnInput
    public var context: RACPContext

    public init(
        sessionId: String,
        admission: RACPTurnAdmission? = nil,
        input: RACPTurnInput,
        context: RACPContext
    ) {
        self.sessionId = sessionId
        self.admission = admission
        self.input = input
        self.context = context
    }
}

public struct RACPTurnRef: Codable, Equatable, Sendable {
    public var id: String
    public var sessionId: String?
    public var status: String?
}

public struct RACPTurnStartResult: Codable, Equatable, Sendable {
    public var accepted: Bool
    public var turn: RACPTurnRef
    public var cursor: RACPCursor?

    enum CodingKeys: String, CodingKey {
        case accepted
        case turn
        case cursor
    }

    public init(accepted: Bool, turn: RACPTurnRef, cursor: RACPCursor? = nil) {
        self.accepted = accepted
        self.turn = turn
        self.cursor = cursor
    }

    // v2 `turn/start` 的冻结响应体只有 `turn`（见 golden），不带 v1 的 `accepted`。
    // 兼容 v1 旧 Host 的同时容忍新 Host：缺省视为 accepted = true。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.accepted = try container.decodeIfPresent(Bool.self, forKey: .accepted) ?? true
        self.turn = try container.decode(RACPTurnRef.self, forKey: .turn)
        self.cursor = try container.decodeIfPresent(RACPCursor.self, forKey: .cursor)
    }
}

public struct RACPTurnByIDParams: Codable, Equatable, Sendable {
    public var turnId: String

    public init(turnId: String) {
        self.turnId = turnId
    }
}

public struct RACPTurnResult: Codable, Equatable, Sendable {
    public var turn: RACPTurnRef
}

public struct RACPApprovalRespondParams: Codable, Equatable, Sendable {
    public var approvalId: String
    public var decision: String
    public var permissionMode: RACPPermissionMode?
    public var context: RACPContext

    public init(
        approvalId: String,
        decision: RACPApprovalDecision,
        permissionMode: RACPPermissionMode? = nil,
        context: RACPContext
    ) {
        self.approvalId = approvalId
        self.decision = decision.rawValue
        self.permissionMode = permissionMode
        self.context = context
    }

    public init(
        approvalId: String,
        contractDecision: RACPContractDecision,
        permissionMode: RACPPermissionMode? = nil,
        context: RACPContext
    ) {
        self.approvalId = approvalId
        self.decision = contractDecision.rawValue
        self.permissionMode = permissionMode
        self.context = context
    }

    public enum ActionError: Error { case invalidAction, permissionModeRequired }

    /// The same action is hashed for idempotency and encoded for the Host.
    public init(approvalId: String, action: SessionRequestAction, context: RACPContext) throws {
        switch action {
        case .approval(let decision, let mode):
            self.init(approvalId: approvalId, decision: decision, permissionMode: mode, context: context)
        case .contract(let decision, let mode):
            guard mode != nil else { throw ActionError.permissionModeRequired }
            self.init(approvalId: approvalId, contractDecision: decision, permissionMode: mode, context: context)
        default: throw ActionError.invalidAction
        }
    }
}

public struct RACPInputRespondParams: Codable, Equatable, Sendable {
    public var inputId: String
    /// 契约 §3.1：`answers` 是 `(string[] | null)[]`，`null` 表示跳过该问题，
    /// 顺序与快照 `pendingInputs` 对齐。每个元素是一组选中标签，不是单个标签。
    public var answers: [[String]?]
    public var context: RACPContext

    public init(inputId: String, answers: [[String]?], context: RACPContext) {
        self.inputId = inputId
        self.answers = answers
        self.context = context
    }
}

/// `input/respond` 的返回体。
///
/// v2 契约（`docs/api/pi-adaptor.md` §8.4）冻结为 `{ "resolved": true, "alreadyResolved": false }`；
/// 早期 v1 golden 形状为 `{ "inputId": …, "status": "resolved" }`。这里两种都接受，
/// 否则严格按 v2 返回时 `JSONDecoder` 会因缺少 `inputId`/`status` 抛 `keyNotFound`，
/// 用户回答 AskTool 提问时表现为「未能读取数据」——与已修的 `turn/start` 属同一类缺陷。
public struct RACPInputRespondResult: Codable, Equatable, Sendable {
    public var resolved: Bool
    public var alreadyResolved: Bool
    /// 仅 v1 形状携带；仅用于诊断，不参与判定。
    public var inputId: String?

    public init(resolved: Bool = true, alreadyResolved: Bool = false, inputId: String? = nil) {
        self.resolved = resolved
        self.alreadyResolved = alreadyResolved
        self.inputId = inputId
    }

    enum CodingKeys: String, CodingKey {
        case resolved, alreadyResolved, inputId, status
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.alreadyResolved = try container.decodeIfPresent(Bool.self, forKey: .alreadyResolved) ?? false
        self.inputId = try container.decodeIfPresent(String.self, forKey: .inputId)
        if let resolved = try container.decodeIfPresent(Bool.self, forKey: .resolved) {
            self.resolved = resolved
        } else {
            // v1 形状：没有 `resolved`，用 `status` 推导；缺省或 "resolved" 视为已解决。
            let status = try container.decodeIfPresent(String.self, forKey: .status)
            self.resolved = (status == nil || status == "resolved")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(resolved, forKey: .resolved)
        try container.encode(alreadyResolved, forKey: .alreadyResolved)
        try container.encodeIfPresent(inputId, forKey: .inputId)
    }
}
