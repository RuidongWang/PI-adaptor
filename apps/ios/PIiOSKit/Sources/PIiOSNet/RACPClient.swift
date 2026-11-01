import Foundation
import CryptoKit
import NIOCore
import PIiOSCore

// MARK: - 隧道状态

/// 隧道 + 会话层状态（设置页与项目页都直接展示这里的状态，绝不伪造在线）。
public enum RACPTunnelState: Equatable, Sendable {
    /// 未连接；`reason` 为上次失败原因。
    case offline(reason: String?)
    case connecting
    /// 正在等用户核对主机指纹（S-04「核对指纹」）。
    case verifyingHostKey(fingerprint: String, status: HostKeyTrustStatus)
    case authenticating
    case handshaking
    case online
    /// 退避重连中（契约 §7 `AGENT_UNAVAILABLE`）。
    case reconnecting(attempt: Int, delay: TimeInterval, reason: String)

    public var displayText: String {
        switch self {
        case .offline: return "未连接"
        case .connecting: return "连接中"
        case .verifyingHostKey: return "等待核对指纹"
        case .authenticating: return "认证中"
        case .handshaking: return "握手中"
        case .online: return "在线"
        case .reconnecting: return "重连中"
        }
    }

    public var isOnline: Bool { self == .online }
}

public struct RACPServerInfo: Equatable, Sendable {
    public var protocolVersion: String
    public var serverName: String
    public var serverVersion: String
    public var hostId: String?
    public var connectionId: String
    public var roles: [String]
    /// `policy.remoteMaxPermissionMode`：权限展示的唯一依据（契约 §2.2）。
    public var remoteMaxPermissionMode: String?
    /// `policy.applyCeilingToPairedDevices`
    public var applyCeilingToPairedDevices: Bool?
    /// `capabilities` 原始值：入口可用性按它裁剪（契约 §2.2 / §8）。
    public var capabilities: JSONValue?

    public init(
        protocolVersion: String,
        serverName: String,
        serverVersion: String,
        hostId: String?,
        connectionId: String,
        roles: [String],
        remoteMaxPermissionMode: String? = nil,
        applyCeilingToPairedDevices: Bool? = nil,
        capabilities: JSONValue? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.serverName = serverName
        self.serverVersion = serverVersion
        self.hostId = hostId
        self.connectionId = connectionId
        self.roles = roles
        self.remoteMaxPermissionMode = remoteMaxPermissionMode
        self.applyCeilingToPairedDevices = applyCeilingToPairedDevices
        self.capabilities = capabilities
    }
}

public enum RACPClientUpdate: Sendable {
    case state(RACPTunnelState)
    case ready(RACPServerInfo)
    /// 会话视图（items / 快照）已变化。
    case sessionChanged
    /// Host 级事件表明会话目录或某个会话的 revision 已变化，需要刷新列表。
    case hostChanged(RACPHostChange)
    /// 收到一条事件（已按契约 §3.2 归约）。
    case event(RACPEvent)
    case error(code: RACPErrorCode, message: String?)
}

public enum RACPHostChangeReason: String, Equatable, Sendable {
    /// `session.created` / `session.changed` / `session.archived` / `host.changed`。
    case catalogChanged
    /// Host 无可重放事件；客户端必须拉取完整目录。
    case replayIncomplete
    /// Host 明确要求重新同步。
    case resyncRequired
    /// Host 事件流的 epoch 已变化。
    case epochChanged
    /// durable sequence 不连续，说明中间有事件丢失。
    case eventGap
}

/// Host 级变更的最小投影。原始载荷仍保留在事件的 `payload` 中。
public struct RACPHostChange: Equatable, Sendable {
    public var reason: RACPHostChangeReason
    public var kind: String?
    public var sessionId: String?
    public var revision: Int?
    public var cursor: RACPCursor?
    public var payload: JSONValue

    public init(
        reason: RACPHostChangeReason,
        kind: String?,
        sessionId: String?,
        revision: Int?,
        cursor: RACPCursor?,
        payload: JSONValue
    ) {
        self.reason = reason
        self.kind = kind
        self.sessionId = sessionId
        self.revision = revision
        self.cursor = cursor
        self.payload = payload
    }
}

/// 事件帧只冻结了 `{epoch, sequence}` 与 `payload`；Host 订阅需要的分类字段从原始载荷读取。
extension RACPEvent {
    public var scope: RACPSubscriptionScope? {
        guard let raw = payload.value(at: ["scope"])?.stringValue else { return nil }
        return RACPSubscriptionScope(rawValue: raw)
    }

    public var kind: String? {
        payload.value(at: ["kind"])?.stringValue
    }

    public var sessionId: String? {
        payload.value(at: ["sessionId"])?.stringValue
    }

    public var revision: Int? {
        payload.value(at: ["revision"])?.intValue
    }
}

enum RACPEventRoute: Equatable {
    case session(RACPEvent)
    case host(RACPEvent)
    case ignored
}

/// 会话事件只能归约到当前 attach 的会话；Host 事件走独立通道。
enum RACPEventRouter {
    static func route(_ event: RACPEvent, currentSessionID: String?) -> RACPEventRoute {
        switch event.scope {
        case .host:
            return .host(event)
        case .session:
            guard let currentSessionID else { return .ignored }
            if let eventSessionID = event.sessionId, eventSessionID != currentSessionID {
                return .ignored
            }
            return .session(event)
        case nil:
            // 兼容未携带 scope 的旧会话帧；无 item 的未知帧不能污染会话归约器。
            guard let currentSessionID else { return .ignored }
            if let eventSessionID = event.sessionId, eventSessionID != currentSessionID {
                return .ignored
            }
            return event.item == nil ? .ignored : .session(event)
        }
    }
}

struct RACPHostEventObservation: Equatable {
    var change: RACPHostChange
    var requiresCatalogRefresh: Bool
}

/// Host 订阅跨重连保留“最后已处理游标”，但每次连接都重建 subscription id。
struct RACPHostSubscriptionTracker: Equatable, Sendable {
    static let catalogKinds: Set<String> = [
        "session.created",
        "session.changed",
        "session.archived",
        "host.changed",
    ]

    private(set) var subscriptionID: String?
    private(set) var cursor: RACPCursor?

    mutating func prepareForReconnect() {
        subscriptionID = nil
    }

    mutating func resetAfterCursorExpired() {
        subscriptionID = nil
        cursor = nil
    }

    mutating func restoreCursor(_ cursor: RACPCursor) {
        self.cursor = cursor
    }

    mutating func install(subscriptionID: String, starting: RACPCursor?) {
        self.subscriptionID = subscriptionID
        guard let starting else { return }
        let baseline = RACPCursor(
            epoch: starting.epoch,
            sequence: max(0, starting.sequence - 1)
        )
        guard let cursor else {
            self.cursor = baseline
            return
        }
        // 重放事件可能先于 subscribe 响应到达；不要把已经推进的游标回拨。
        if cursor.epoch != baseline.epoch || cursor.sequence < baseline.sequence {
            self.cursor = baseline
        }
    }

    mutating func observe(_ event: RACPEvent) -> RACPHostEventObservation? {
        guard event.scope?.rawValue == RACPSubscriptionScope.host.rawValue else { return nil }
        let kind = event.kind

        if kind == "resync.required" {
            let epoch = event.epoch ?? cursor?.epoch ?? "unknown"
            let sequence = event.durableSequence ?? event.afterSequence ?? cursor?.sequence ?? 0
            let next = RACPCursor(epoch: epoch, sequence: sequence)
            if event.isDurable {
                self.cursor = next
            }
            return observation(
                for: event,
                cursor: next,
                reason: .resyncRequired,
                requiresRefresh: true
            )
        }

        guard let sequence = event.durableSequence else { return nil }

        if let epoch = event.epoch,
           let cursor,
           cursor.epoch != epoch {
            let next = RACPCursor(epoch: epoch, sequence: sequence)
            self.cursor = next
            return observation(
                for: event,
                cursor: next,
                reason: .epochChanged,
                requiresRefresh: true
            )
        }

        if let cursor,
           (event.epoch == nil || event.epoch == cursor.epoch),
           sequence <= cursor.sequence {
            return nil
        }

        let epoch = event.epoch ?? cursor?.epoch ?? "unknown"
        let next = RACPCursor(epoch: epoch, sequence: sequence)
        cursor = next
        // 不要用序号连续性判定缺口：`sequence` 是 Host 的**全局**序号（契约 §3.2），
        // host 订阅只收到 host 事件，会话事件会穿插占用序号，因此「相邻 host 事件
        // 序号不连续」是常态。真正的重同步信号是 epoch 变化、`resync.required`
        // 以及服务端 `CURSOR_EXPIRED`。
        if let kind, Self.catalogKinds.contains(kind) {
            return observation(
                for: event,
                cursor: next,
                reason: .catalogChanged,
                requiresRefresh: true
            )
        }
        return observation(
            for: event,
            cursor: next,
            reason: .catalogChanged,
            requiresRefresh: false
        )
    }

    private func observation(
        for event: RACPEvent,
        cursor: RACPCursor,
        reason: RACPHostChangeReason,
        requiresRefresh: Bool
    ) -> RACPHostEventObservation {
        RACPHostEventObservation(
            change: RACPHostChange(
                reason: reason,
                kind: event.kind,
                sessionId: event.sessionId,
                revision: event.revision,
                cursor: cursor,
                payload: event.payload
            ),
            requiresCatalogRefresh: requiresRefresh
        )
    }
}

// MARK: - 配置

public struct RACPConfiguration: Sendable {
    public var ssh: SSHConnectionRequest
    /// Host 在服务器回环上的端口（`direct-tcpip` 目标端口）。
    public var hostPort: Int
    /// 设备令牌（契约 §2.3，走 `Authorization: Bearer`）。
    public var deviceToken: String?
    public var clientVersion: String

    public init(
        ssh: SSHConnectionRequest,
        hostPort: Int,
        deviceToken: String?,
        clientVersion: String = "0.1.0"
    ) {
        self.ssh = ssh
        self.hostPort = hostPort
        self.deviceToken = deviceToken
        self.clientVersion = clientVersion
    }
}

/// 会话视图的对外快照（`SessionViewModel` 只在客户端内部持有）。
/// 会话视图的对外快照（`SessionViewModel` 只在客户端内部持有）。
public struct RACPSessionView: Equatable, Sendable {
    public var sessionId: String?
    public var summary: RACPSessionSummary?
    public var items: [RACPItem]
    /// 正在运行中的条目（快照 `activeItems`）；非空即视为有 turn 在跑。
    public var activeItems: [RACPItem]
    /// 排队中的补充指令（AC-13.1）；元素形状未冻结，只解析出可用于取消的 id。
    public var queuedTurns: [QueuedTurn]
    public var pendingApprovals: [RACPApprovalRequest]
    public var pendingInputs: [RACPInputRequest]
    /// 曾出现、但已不在快照里的审批卡（AC-14.5：显示为失效且不可点击）。
    public var expiredApprovalIds: Set<String>
    public var cursor: RACPCursor?
    public var revision: Int
    public var replayComplete: Bool
    public var hasMoreHistory: Bool
    /// 正在运行的 turn id；`nil` 表示没有可中止的 turn。
    public var runningTurnId: String?

    public init(
        sessionId: String?,
        summary: RACPSessionSummary?,
        items: [RACPItem],
        activeItems: [RACPItem],
        queuedTurns: [QueuedTurn],
        pendingApprovals: [RACPApprovalRequest],
        pendingInputs: [RACPInputRequest],
        expiredApprovalIds: Set<String>,
        cursor: RACPCursor?,
        revision: Int,
        replayComplete: Bool,
        hasMoreHistory: Bool,
        runningTurnId: String?
    ) {
        self.sessionId = sessionId
        self.summary = summary
        self.items = items
        self.activeItems = activeItems
        self.queuedTurns = queuedTurns
        self.pendingApprovals = pendingApprovals
        self.pendingInputs = pendingInputs
        self.expiredApprovalIds = expiredApprovalIds
        self.cursor = cursor
        self.revision = revision
        self.replayComplete = replayComplete
        self.hasMoreHistory = hasMoreHistory
        self.runningTurnId = runningTurnId
    }

    public static let empty = RACPSessionView(
        sessionId: nil, summary: nil, items: [], activeItems: [], queuedTurns: [],
        pendingApprovals: [], pendingInputs: [], expiredApprovalIds: [],
        cursor: nil, revision: 0, replayComplete: false, hasMoreHistory: false, runningTurnId: nil
    )
}

public enum RACPClientError: Error, Equatable, CustomStringConvertible {
    case notConnected
    case protocolMismatch(String)
    case server(code: RACPErrorCode, message: String?)
    case timedOut(String)
    case malformedFrame(String)

    public var description: String {
        switch self {
        case .notConnected:
            return "隧道未连接"
        case .protocolMismatch(let detail):
            return "Host 版本不兼容：\(detail)"
        case .server(let code, let message):
            return message ?? "服务器返回错误：\(code)"
        case .timedOut(let phase):
            return "超时：\(phase)"
        case .malformedFrame(let detail):
            return "收到无法解析的帧：\(detail)"
        }
    }
}

/// The host key was already checked when the bootstrap SSH transport was
/// opened. This confirmer is never consulted on the supplied-transport path;
/// rejecting is the safe fallback if that invariant is ever broken.
private struct SuppliedTransportHostKeyConfirmer: HostKeyConfirming {
    func confirmHostKey(
        _ key: SSHHostKey,
        status: HostKeyTrustStatus
    ) async -> HostKeyConfirmation {
        .reject
    }
}

// MARK: - 客户端

/// RACP 客户端最小闭环（契约 §2.2 / §2.3 / §3）：
/// SSH 隧道 → `direct-tcpip` → WebSocket（子协议 `pi-racp.v1.jsonrpc`）→ 握手 → 请求/事件。
fileprivate enum RequestRecoveryScope: Sendable {
    case session
    case host
}

private struct PendingEventAck: Equatable, Sendable {
    let subscriptionId: String
    let sequence: Int
}

private enum SnapshotRebuildOutcome: Equatable {
    case rebuilt
    case inProgress
    case superseded
    case failed
}

public actor RACPClient {
    private let configuration: RACPConfiguration
    private let confirmer: any HostKeyConfirming
    private let backoff: ReconnectBackoff
    /// Bootstrap 已经建立并持有 SSH 连接时必须复用它，不能为配对/校验再开第二条连接。
    private let suppliedTransport: SSHTransport?
    private let updates: AsyncStream<RACPClientUpdate>
    private let continuation: AsyncStream<RACPClientUpdate>.Continuation
    private var runTask: Task<Void, Never>?
    private var subscriptionTerminalReason: String?

    private var transport: SSHTransport?
    private var socket: (any RACPSocket)?
    private var serverInfo: RACPServerInfo?
    private var state: RACPTunnelState = .offline(reason: nil)

    private var nextRequestId = 1
    private var pending: [RACPIdentifier: PendingRequest] = [:]

    private let viewModel = SessionViewModel()
    private var attachedSession: RACPSessionSummary?
    private var sessionId: String?
    private var subscriptionId: String?
    private var subscribedSessionId: String?
    private var sessionAttachGeneration = 0
    private var sessionEventsSuspended = false
    private var pendingSessionSubscriptionAttempt: UUID?
    private var pendingSessionSubscriptionSessionId: String?
    private var pendingSessionSubscriptionGeneration: Int?
    private var pendingSessionAckDuringSubscribe: Int?
    private var isHostSubscriptionPending = false
    private var pendingHostAckDuringSubscribe: Int?
    private var isRebuildingSnapshot = false
    private var bufferedSessionEventsDuringAttach: [RACPEvent] = []
    private var rebuildingSnapshots: Set<String> = []
    private var hostSubscription = RACPHostSubscriptionTracker()
    private var pendingHostAck: PendingEventAck?
    private var isDrainingHostAcks = false
    private var pendingSessionAck: PendingEventAck?
    private var isDrainingSessionAcks = false
    public init(
        configuration: RACPConfiguration,
        confirmer: any HostKeyConfirming,
        backoff: ReconnectBackoff = ReconnectBackoff()
    ) {
        self.configuration = configuration
        self.confirmer = confirmer
        self.backoff = backoff
        self.suppliedTransport = nil
        var sink: AsyncStream<RACPClientUpdate>.Continuation!
        self.updates = AsyncStream<RACPClientUpdate> { sink = $0 }
        self.continuation = sink
    }

    private init(
        suppliedTransport: SSHTransport,
        hostPort: Int,
        deviceToken: String,
        clientVersion: String
    ) {
        // The SSH request is never used for this instance. Keeping it structurally
        // valid lets the one-shot path share the normal request/handshake machinery.
        self.configuration = RACPConfiguration(
            ssh: SSHConnectionRequest(
                host: "127.0.0.1",
                port: 22,
                username: "",
                credential: .password(""),
                pinnedHostKey: nil
            ),
            hostPort: hostPort,
            deviceToken: deviceToken,
            clientVersion: clientVersion
        )
        self.confirmer = SuppliedTransportHostKeyConfirmer()
        self.backoff = ReconnectBackoff()
        self.suppliedTransport = suppliedTransport
        var sink: AsyncStream<RACPClientUpdate>.Continuation!
        self.updates = AsyncStream<RACPClientUpdate> { sink = $0 }
        self.continuation = sink
    }

#if DEBUG
    init(
        testingSocket: any RACPSocket,
        subscriptionId: String?,
        subscribedSessionId: String?
    ) {
        self.configuration = RACPConfiguration(
            ssh: SSHConnectionRequest(
                host: "127.0.0.1",
                port: 22,
                username: "",
                credential: .password(""),
                pinnedHostKey: nil
            ),
            hostPort: 1,
            deviceToken: nil
        )
        self.confirmer = SuppliedTransportHostKeyConfirmer()
        self.backoff = ReconnectBackoff()
        self.suppliedTransport = nil
        var sink: AsyncStream<RACPClientUpdate>.Continuation!
        self.updates = AsyncStream<RACPClientUpdate> { sink = $0 }
        self.continuation = sink
        self.socket = testingSocket
        self.state = .online
        self.subscriptionId = subscriptionId
        self.subscribedSessionId = subscribedSessionId
        self.sessionId = subscribedSessionId
    }

    func receiveForTesting(_ data: Data) async {
        guard let socket else { return }
        await receive(data, from: socket)
    }

    func pendingRequestCountForTesting() -> Int {
        pending.count
    }

    func setSessionSubscriptionForTesting(_ id: String?) {
        subscriptionId = id
    }

    func enqueueSessionAckForTesting(subscriptionId: String, sequence: Int) async {
        guard let socket else { return }
        await queueSessionAck(
            PendingEventAck(subscriptionId: subscriptionId, sequence: sequence),
            from: socket
        )
    }
#endif

    // MARK: 生命周期

    /// 启动连接循环，返回状态/事件流。重复调用返回同一个流。
    @discardableResult
    public func start() -> AsyncStream<RACPClientUpdate> {
        if runTask == nil {
            runTask = Task { [weak self] in
                await self?.runLoop()
            }
        }
        return updates
    }

    /// 只取状态/事件流，不启动连接（用于界面先订阅再决定何时连）。
    public func stream() -> AsyncStream<RACPClientUpdate> { updates }

    public func stop() async {
        runTask?.cancel()
        runTask = nil
        await teardown(reason: nil)
        continuation.finish()
    }

    /// Bounded cleanup for recovery paths. `teardown` ultimately closes SSH/NIO
    /// resources whose close futures may not cooperate with task cancellation.
    @discardableResult
    public func stopBestEffort(timeout: TimeInterval = 1) async -> Bool {
        runTask?.cancel()
        runTask = nil
        let completed = await boundedAsyncValue(seconds: timeout) { [self] in
            await teardown(reason: nil)
            continuation.finish()
            return true
        }
        if completed != true {
            // Make the update stream terminal even if an underlying close future
            // continues in the background. No caller waits for that orphaned close.
            continuation.finish()
        }
        return completed == true
    }

    public func currentState() -> RACPTunnelState { state }
    public func info() -> RACPServerInfo? { serverInfo }

    /// 使用一次性配对令牌完成单次交换。调用者必须持久化结果，随后用设备令牌重建连接。
    /// 此方法不会重试：超时可能意味着令牌已被消费，不能盲目再次交换。
    public func pairOnce(deviceLabel: String? = nil) async throws -> RACPPairResult {
        guard runTask == nil, transport == nil, let token = configuration.deviceToken,
              (token.hasPrefix("ppt1.") || token.hasPrefix("ppt2.")),
              !token.contains(where: { $0.isWhitespace }) else {
            throw RACPClientError.protocolMismatch("需要有效的一次性配对令牌且连接必须处于空闲状态")
        }
        do {
            try await establish()
            let result: RACPPairResult = try await request(.pair, params: RACPPairParams(deviceLabel: deviceLabel))
            guard !result.deviceId.isEmpty,
                  (result.deviceToken.hasPrefix("pdt1.") || result.deviceToken.hasPrefix("pdt2.")) else {
                throw RACPClientError.malformedFrame("配对响应缺少有效设备凭证")
            }
            await teardown(reason: nil)
            state = .offline(reason: nil)
            return result
        } catch {
            await teardown(reason: nil)
            state = .offline(reason: nil)
            throw error
        }
    }

    /// Runs `connection/initialize` + `connection/pair` on the caller-owned SSH
    /// transport used by bootstrap. The transport remains open for the next
    /// polling step; only the RACP WebSocket child channel is closed.
    public static func pairOnce(
        using transport: SSHTransport,
        hostPort: Int,
        pairingToken: String,
        clientVersion: String = "0.1.0",
        deviceLabel: String? = nil
    ) async throws -> RACPPairResult {
        guard (1...65_535).contains(hostPort),
              let token = RACPPairingToken.normalize(pairingToken) else {
            throw RACPClientError.protocolMismatch("需要有效的 PI-adaptor 端口与一次性配对令牌")
        }
        let client = RACPClient(
            suppliedTransport: transport,
            hostPort: hostPort,
            deviceToken: token,
            clientVersion: clientVersion
        )
        return try await client.pairOnceOnSuppliedTransport(deviceLabel: deviceLabel)
    }

    /// Reconnects RACP with the newly issued device token on the same bootstrap
    /// SSH transport, then verifies the round trip with `connection/ping`.
    public static func verifyDevice(
        using transport: SSHTransport,
        hostPort: Int,
        deviceToken: String,
        clientVersion: String = "0.1.0"
    ) async throws -> RACPServerInfo {
        guard (1...65_535).contains(hostPort),
              !deviceToken.isEmpty,
              !deviceToken.contains(where: \.isWhitespace) else {
            throw RACPClientError.protocolMismatch("需要有效的 PI-adaptor 端口与设备令牌")
        }
        let client = RACPClient(
            suppliedTransport: transport,
            hostPort: hostPort,
            deviceToken: deviceToken,
            clientVersion: clientVersion
        )
        return try await client.verifyDeviceOnSuppliedTransport()
    }

    private func pairOnceOnSuppliedTransport(
        deviceLabel: String?
    ) async throws -> RACPPairResult {
        guard suppliedTransport != nil,
              (configuration.deviceToken?.hasPrefix("ppt1.") == true
                || configuration.deviceToken?.hasPrefix("ppt2.") == true) else {
            throw RACPClientError.protocolMismatch("一次性配对需要 bootstrap 提供的 SSH 连接")
        }
        do {
            try await establish()
            let result: RACPPairResult = try await request(
                .pair,
                params: RACPPairParams(deviceLabel: deviceLabel)
            )
            guard !result.deviceId.isEmpty,
                  (result.deviceToken.hasPrefix("pdt1.") || result.deviceToken.hasPrefix("pdt2.")) else {
                throw RACPClientError.malformedFrame("配对响应缺少有效设备凭证")
            }
            await closeWebSocketPreservingTransport()
            return result
        } catch {
            await closeWebSocketPreservingTransport()
            throw error
        }
    }

    private func verifyDeviceOnSuppliedTransport() async throws -> RACPServerInfo {
        guard suppliedTransport != nil else {
            throw RACPClientError.protocolMismatch("设备校验需要 bootstrap 提供的 SSH 连接")
        }
        do {
            try await establish()
            try await ping()
            guard let serverInfo else {
                throw RACPClientError.malformedFrame("设备校验未取得 Host 信息")
            }
            await closeWebSocketPreservingTransport()
            return serverInfo
        } catch {
            await closeWebSocketPreservingTransport()
            throw error
        }
    }

    // MARK: 会话

    /// `session/attach` + （可选）`events/subscribe`：申请快照并整体替换本地视图。
    @discardableResult
    public func attach(sessionId: String, subscribe: Bool = true) async throws -> Bool? {
        sessionAttachGeneration &+= 1
        let attachGeneration = sessionAttachGeneration
        let previousSessionId = self.sessionId
        let switchesSession = previousSessionId != nil && previousSessionId != sessionId
        // 从发起到快照落地的窗口内冻结会话事件；旧订阅的迟到事件不能污染新会话。
        sessionEventsSuspended = true
        let params = RACPSessionAttachParams(sessionId: sessionId)
        let result: RACPSessionAttachResult
        do {
            result = try await request(.sessionAttach, params: params)
        } catch {
            guard attachGeneration == sessionAttachGeneration else { throw error }
            sessionEventsSuspended = false
            subscribedSessionId = previousSessionId
            if let previousSessionId {
                // The old subscription may have lost events while suspended; replay from its cursor.
                try? await subscribeSession(sessionId: previousSessionId, after: viewModel.cursor)
            }
            throw error
        }
        guard attachGeneration == sessionAttachGeneration else { return nil }
        if switchesSession {
            viewModel.resetForSession()
        }
        // 契约 §3.2 规则 1：`replayComplete=false` 也必须整体替换，并丢弃未完成草稿。
        if let snapshot = result.snapshot {
            if switchesSession || snapshot.revision >= viewModel.revision {
                _ = viewModel.applySnapshot(snapshot, replayComplete: result.replayComplete ?? false)
            }
        }
        self.attachedSession = result.session
        self.sessionId = sessionId
        self.subscribedSessionId = sessionId
        if result.snapshot == nil, let activeTurnId = result.session.activeTurnId {
            viewModel.recordActiveTurn(id: activeTurnId)
        }
        await emit(.sessionChanged)
        if subscribe {
            try await subscribeSession(sessionId: sessionId, after: viewModel.cursor)
        } else {
            sessionEventsSuspended = false
        }
        return result.snapshot != nil
    }

    /// 用会话**当前游标**重新订阅（重连后补齐缺失事件，AC-14.1）。
    public func subscribeSession(sessionId: String, after: RACPCursor?) async throws {
        let attachGeneration = sessionAttachGeneration
        guard let socket else { throw RACPClientError.notConnected }
        let subscribeAttempt = UUID()
        pendingSessionSubscriptionAttempt = subscribeAttempt
        pendingSessionSubscriptionSessionId = nil
        pendingSessionSubscriptionGeneration = nil
        pendingSessionAckDuringSubscribe = nil
        if let previousSubscriptionId = subscriptionId {
            subscriptionId = nil
            do {
                let _: JSONValue? = try await requestJSON(
                    .eventsUnsubscribe,
                    params: RACPEventsUnsubscribeParams(subscriptionId: previousSubscriptionId),
                    timeout: 10
                )
            } catch {
                let ownsAttempt = pendingSessionSubscriptionAttempt == subscribeAttempt
                    && attachGeneration == sessionAttachGeneration
                    && self.sessionId == sessionId
                if ownsAttempt {
                    // A live old subscription could keep delivering unscoped
                    // frames. Drop the whole socket rather than risk applying
                    // them to a replacement subscription on the same socket.
                    await socket.close()
                    throw RACPClientError.notConnected
                }
                return
            }
        }
        guard attachGeneration == sessionAttachGeneration, self.sessionId == sessionId else { return }
        // Replay frames may arrive before `events/subscribe` returns its new
        // subscription id. Apply them from the durable cursor and remember the
        // highest watermark so it can be ACKed once the id is installed.
        sessionEventsSuspended = false
        pendingSessionSubscriptionSessionId = sessionId
        pendingSessionSubscriptionGeneration = attachGeneration
        pendingSessionAckDuringSubscribe = nil
        let params = RACPEventsSubscribeParams(scope: .session, sessionId: sessionId, after: after)
        let value: JSONValue
        do {
            value = try await requestJSON(
                .eventsSubscribe,
                params: params,
                timeout: 20,
                recoveryScope: .session
            )
        } catch {
            let ownsAttempt = pendingSessionSubscriptionAttempt == subscribeAttempt
                && pendingSessionSubscriptionGeneration == attachGeneration
                && pendingSessionSubscriptionSessionId == sessionId
                && attachGeneration == sessionAttachGeneration
                && self.sessionId == sessionId
            if ownsAttempt {
                pendingSessionSubscriptionAttempt = nil
                pendingSessionSubscriptionSessionId = nil
                pendingSessionSubscriptionGeneration = nil
                pendingSessionAckDuringSubscribe = nil
            }
            guard ownsAttempt else { return }
            guard Self.requiresCursorReset(error) else {
                // The server may have installed the subscription even though
                // the response timed out. Drop the uncertain socket so a new
                // subscription replays from the durable cursor.
                await socket.close()
                throw RACPClientError.notConnected
            }
            let outcome = await rebuildFromSnapshot(from: socket)
            if outcome == .failed,
               attachGeneration == sessionAttachGeneration,
               self.sessionId == sessionId,
               self.socket === socket {
                await socket.close()
            }
            return
        }
        let result: RACPEventsSubscribeResult
        do {
            result = try RACPEventsSubscribeResult.decoded(from: value)
        } catch {
            let ownsAttempt = pendingSessionSubscriptionAttempt == subscribeAttempt
                && pendingSessionSubscriptionGeneration == attachGeneration
                && pendingSessionSubscriptionSessionId == sessionId
                && attachGeneration == sessionAttachGeneration
                && self.sessionId == sessionId
            if ownsAttempt {
                pendingSessionSubscriptionAttempt = nil
                pendingSessionSubscriptionSessionId = nil
                pendingSessionSubscriptionGeneration = nil
                pendingSessionAckDuringSubscribe = nil
                await socket.close()
                throw error
            }
            return
        }
        let ownsPendingAttempt = pendingSessionSubscriptionAttempt == subscribeAttempt
            && pendingSessionSubscriptionGeneration == attachGeneration
            && pendingSessionSubscriptionSessionId == sessionId
            && attachGeneration == sessionAttachGeneration
            && self.sessionId == sessionId
        let replayAck = ownsPendingAttempt
            ? pendingSessionAckDuringSubscribe
            : nil
        if ownsPendingAttempt {
            pendingSessionSubscriptionAttempt = nil
            pendingSessionSubscriptionSessionId = nil
            pendingSessionSubscriptionGeneration = nil
            pendingSessionAckDuringSubscribe = nil
        }
        guard !result.subscriptionId.isEmpty else {
            if ownsPendingAttempt {
                await socket.close()
                throw RACPClientError.malformedFrame("events/subscribe 未返回 subscriptionId")
            }
            return
        }
        guard ownsPendingAttempt,
              attachGeneration == sessionAttachGeneration,
              self.sessionId == sessionId
        else {
            _ = try? await requestJSON(
                .eventsUnsubscribe,
                params: RACPEventsUnsubscribeParams(subscriptionId: result.subscriptionId),
                timeout: 10
            )
            return
        }
        subscriptionId = result.subscriptionId
        subscribedSessionId = sessionId
        if let replayAck {
            await queueSessionAck(
                PendingEventAck(subscriptionId: result.subscriptionId, sequence: replayAck),
                from: socket
            )
        }
        if result.replayComplete != true {
            isRebuildingSnapshot = true
            bufferedSessionEventsDuringAttach.removeAll()
            defer {
                isRebuildingSnapshot = false
                bufferedSessionEventsDuringAttach.removeAll()
            }
            let attachResult: RACPSessionAttachResult = try await request(
                .sessionAttach,
                params: RACPSessionAttachParams(sessionId: sessionId)
            )
            guard attachGeneration == sessionAttachGeneration, self.sessionId == sessionId else {
                return
            }
            if let snapshot = attachResult.snapshot,
               snapshot.revision >= viewModel.revision {
                _ = viewModel.applySnapshot(snapshot, replayComplete: true)
                let snapshotSeq = snapshot.cursor.sequence
                let newerBuffered = bufferedSessionEventsDuringAttach.filter {
                    ($0.durableSequence ?? 0) > snapshotSeq
                }
                if !newerBuffered.isEmpty {
                    _ = viewModel.applyEvents(newerBuffered)
                }
            }
            attachedSession = attachResult.session
            self.sessionId = sessionId
            if attachResult.snapshot == nil, let activeTurnId = attachResult.session.activeTurnId {
                viewModel.recordActiveTurn(id: activeTurnId)
            }
            await emit(.sessionChanged)
        }
    }

    /// Host 级订阅：感知其他客户端创建会话、归档会话与 revision 变化。
    ///
    /// 游标跨重连保留；subscriber id 每次连接重建。`replayComplete=false` 时
    /// 不尝试逐条补齐，而是要求上层重新拉取完整项目/会话目录。
    private func subscribeHost() async throws {
        if let previousSubscriptionID = hostSubscription.subscriptionID {
            _ = try? await requestJSON(
                .eventsUnsubscribe,
                params: RACPEventsUnsubscribeParams(subscriptionId: previousSubscriptionID),
                timeout: 10
            )
        }
        hostSubscription.prepareForReconnect()

        var didResetExpiredCursor = false
        while true {
            isHostSubscriptionPending = true
            pendingHostAckDuringSubscribe = nil
            do {
                let value = try await requestJSON(
                    .eventsSubscribe,
                    params: RACPEventsSubscribeParams(scope: .host, after: hostSubscription.cursor),
                    timeout: 20,
                    recoveryScope: .host
                )
                let result = try RACPEventsSubscribeResult.decoded(from: value)
                guard !result.subscriptionId.isEmpty else {
                    throw RACPClientError.malformedFrame("host events/subscribe 未返回 subscriptionId")
                }
                guard let socket else { throw RACPClientError.notConnected }
                let replayAck = pendingHostAckDuringSubscribe
                isHostSubscriptionPending = false
                pendingHostAckDuringSubscribe = nil
                hostSubscription.install(
                    subscriptionID: result.subscriptionId,
                    starting: result.starting
                )
                if let replayAck {
                    await queueHostAck(
                        PendingEventAck(
                            subscriptionId: result.subscriptionId,
                            sequence: replayAck
                        ),
                        from: socket
                    )
                }
                await drainHostAcks(from: socket)

                if result.replayComplete != true {
                    await emit(.hostChanged(
                        RACPHostChange(
                            reason: .replayIncomplete,
                            kind: nil,
                            sessionId: nil,
                            revision: nil,
                            cursor: hostSubscription.cursor,
                            payload: .null
                        )
                    ))
                }
                return
            } catch {
                isHostSubscriptionPending = false
                pendingHostAckDuringSubscribe = nil
                guard !didResetExpiredCursor, Self.requiresCursorReset(error) else { throw error }
                didResetExpiredCursor = true
                hostSubscription.resetAfterCursorExpired()
                pendingHostAck = nil
                await emit(.hostChanged(
                    RACPHostChange(
                        reason: .replayIncomplete,
                        kind: nil,
                        sessionId: nil,
                        revision: nil,
                        cursor: nil,
                        payload: .null
                    )
                ))
            }
        }
    }

    public func listSessions(timeout: TimeInterval = 20) async throws -> [RACPSessionSummary] {
        let result: RACPSessionListResult = try await request(
            .sessionList,
            params: RACPEmptyParams(),
            timeout: timeout
        )
        return result.sessions
    }

    public func getSession(id: String) async throws -> RACPSessionSummary {
        let result: RACPSessionGetResult = try await request(.sessionGet, params: RACPSessionGetParams(sessionId: id))
        if self.sessionId == id {
            attachedSession = result.session
            if result.session.revision.map({ $0 >= viewModel.revision }) ?? true {
                viewModel.recordActiveTurn(id: result.session.activeTurnId)
            }
            await emit(.sessionChanged)
        }
        return result.session
    }

    public func listProjects(timeout: TimeInterval = 20) async throws -> [RACPProjectSummary] {
        let result: RACPProjectListResult = try await request(
            .projectList,
            params: RACPEmptyParams(),
            timeout: timeout
        )
        return result.projects
    }

    public func ping() async throws {
        let _: RACPJSONObject = try await request(.ping, params: RACPEmptyParams())
    }

    // MARK: - 发送 / 中止 / 排队（AC-08 / AC-09 / AC-13）

    public func uploadImage(
        sessionId: String,
        data: Data,
        mimeType: String,
        fileName: String
    ) async throws -> RACPV2Attachment {
        guard data.count > 0, data.count <= 20 * 1024 * 1024 else {
            throw RACPClientError.protocolMismatch("图片必须为 1 字节至 20 MiB")
        }
        guard ["image/jpeg", "image/png", "image/webp"].contains(mimeType) else {
            throw RACPClientError.protocolMismatch("仅支持 JPEG、PNG、WebP")
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let created: RACPV2AttachmentCreateResult = try await v2Request(
            method: RACPV2Method.attachmentCreate.rawValue,
            params: .object([
                "sessionId": .string(sessionId),
                "fileName": .string(fileName),
                "mimeType": .string(mimeType),
                "byteLength": .number(Double(data.count)),
                "sha256": .string(digest),
                "context": .object([
                    "requestId": .string("req_\(UUID().uuidString)"),
                    "idempotencyKey": .string("attach_\(UUID().uuidString)")
                ])
            ])
        )
        let chunkSize = max(1, created.chunkSize)
        var offset = 0
        while offset < data.count {
            let end = min(data.count, offset + chunkSize)
            let chunk = data.subdata(in: offset..<end)
            let _: RACPV2AttachmentChunkResult = try await v2Request(
                method: RACPV2Method.attachmentChunk.rawValue,
                params: .object([
                    "attachmentId": .string(created.attachmentId),
                    "offset": .number(Double(offset)),
                    "dataBase64": .string(chunk.base64EncodedString()),
                    "context": .object([
                        "requestId": .string("req_\(UUID().uuidString)"),
                        "idempotencyKey": .string("attach_chunk_\(UUID().uuidString)")
                    ])
                ])
            )
            offset = end
        }
        let completed: RACPV2AttachmentEnvelope = try await v2Request(
            method: RACPV2Method.attachmentComplete.rawValue,
            params: .object([
                "attachmentId": .string(created.attachmentId),
                "sha256": .string(digest),
                "context": .object([
                    "requestId": .string("req_\(UUID().uuidString)"),
                    "idempotencyKey": .string("attach_complete_\(UUID().uuidString)")
                ])
            ])
        )
        return completed.attachment
    }

    public func readImageAttachment(
        attachmentId: String,
        offset: Int = 0,
        length: Int = 262_144
    ) async throws -> RACPV2AttachmentReadResult {
        try await v2Request(
            method: RACPV2Method.attachmentRead.rawValue,
            params: .object([
                "attachmentId": .string(attachmentId),
                "offset": .number(Double(offset)),
                "length": .number(Double(length)),
                "context": .object([
                    "requestId": .string("req_\(UUID().uuidString)")
                ])
            ])
        )
    }

    /// 发送一条消息。`idempotencyKey` 必须由调用方持久化并在重试时复用（AC-14.4）。
    ///
    /// `admission` 为 `.queue` 时表示当前有 turn 在跑，这条指令排队（AC-13.1）。
    public func startTurn(
        sessionId: String,
        text: String,
        attachments: [String] = [],
        admission: RACPTurnAdmission?,
        idempotencyKey: String,
        timeout: TimeInterval = 30
    ) async throws -> RACPTurnStartResult {
        let params = RACPTurnStartParams(
            sessionId: sessionId,
            admission: admission,
            input: RACPTurnInput(text: text, attachments: attachments.map(JSONValue.string)),
            context: makeContext(idempotencyKey: idempotencyKey)
        )
        let result: RACPTurnStartResult = try await request(.turnStart, params: params, timeout: timeout)
        let status = result.turn.status?.lowercased()
        switch status {
        case "queued":
            viewModel.recordQueuedTurn(id: result.turn.id, text: text)
        case "running", "waiting_approval", "waiting_input", "in_progress":
            viewModel.recordActiveTurn(id: result.turn.id)
        case "completed", "interrupted", "failed", "canceled", "cancelled":
            viewModel.removeQueuedTurn(id: result.turn.id)
            if viewModel.activeTurnId == result.turn.id {
                viewModel.recordActiveTurn(id: nil)
            }
        case nil:
            if admission == .queue {
                viewModel.recordQueuedTurn(id: result.turn.id, text: text)
            } else {
                viewModel.recordActiveTurn(id: result.turn.id)
            }
        default:
            if admission == .queue {
                viewModel.recordQueuedTurn(id: result.turn.id, text: text)
            } else {
                viewModel.recordActiveTurn(id: result.turn.id)
            }
        }
        return result
    }

    /// 中止正在运行的 turn（AC-09.1）。
    public func interruptTurn(turnId: String) async throws {
        let _: RACPTurnResult = try await request(
            .turnInterrupt,
            params: RACPTurnIDParams(turnId: turnId, context: makeContext())
        )
        if viewModel.activeTurnId == turnId { viewModel.recordActiveTurn(id: nil) }
    }

    /// 取消一条排队中的 turn（AC-13.2）。
    public func cancelTurn(turnId: String) async throws {
        let _: RACPTurnResult = try await request(
            .turnCancel,
            params: RACPTurnIDParams(turnId: turnId, context: makeContext())
        )
        viewModel.removeQueuedTurn(id: turnId)
        if viewModel.activeTurnId == turnId { viewModel.recordActiveTurn(id: nil) }
    }

    // MARK: - 审批与提问（AC-10 / AC-11 / AC-12）

    /// 工具类审批。返回体形状未冻结，按原始 JSON 返回，由界面只读可能的 `alreadyResolved`。
    public func respondApproval(
        approvalId: String,
        decision: RACPApprovalDecision,
        permissionMode: RACPPermissionMode? = nil,
        expectedRevision: Int?,
        idempotencyKey: String
    ) async throws -> JSONValue {
        let params = RACPApprovalRespondParams(
            approvalId: approvalId,
            decision: decision,
            permissionMode: permissionMode,
            context: makeContext(idempotencyKey: idempotencyKey, expectedRevision: expectedRevision)
        )
        return try await request(.approvalRespond, params: params)
    }

    /// Plan / Goal 契约审批（AC-12.1）。
    public func respondContract(
        approvalId: String,
        decision: RACPContractDecision,
        expectedRevision: Int?,
        idempotencyKey: String
    ) async throws -> JSONValue {
        let params = RACPApprovalRespondParams(
            approvalId: approvalId,
            contractDecision: decision,
            context: makeContext(idempotencyKey: idempotencyKey, expectedRevision: expectedRevision)
        )
        return try await request(.approvalRespond, params: params)
    }

    /// 回答 AskTool 的提问（AC-11.1）。`answers` 顺序必须与快照 `pendingInputs` 的问题顺序对齐。
    public func respondInput(
        inputId: String,
        answers: [[String]?],
        expectedRevision: Int? = nil,
        idempotencyKey: String
    ) async throws -> RACPInputRespondResult {
        let params = RACPInputRespondParams(
            inputId: inputId,
            answers: answers,
            context: makeContext(
                idempotencyKey: idempotencyKey,
                expectedRevision: expectedRevision
            )
        )
        return try await request(.inputRespond, params: params)
    }

    public func markApprovalExpired(id: String) async {
        viewModel.markApprovalExpired(id: id)
        await emit(.sessionChanged)
    }

    // MARK: - 配置 / 项目 / 设备

    /// 切换模型、档位、会话模式与权限模式（AC-07.1）。只下发调用方明确给出的字段。
    public func configureSession(
        sessionId: String,
        mode: RACPSessionMode? = nil,
        permissionMode: RACPPermissionMode? = nil,
        providerId: String? = nil,
        modelId: String? = nil,
        thinkingLevel: RACPThinkingLevel? = nil
    ) async throws -> RACPSessionSummary {
        let params = RACPSessionConfigureParams(
            sessionId: sessionId,
            mode: mode,
            providerId: providerId,
            modelId: modelId,
            thinkingLevel: thinkingLevel,
            permissionMode: permissionMode
        )
        let result: RACPSessionConfigureResult = try await request(.sessionConfigure, params: params)
        if attachedSession?.id == result.session.id { attachedSession = result.session }
        return result.session
    }

    /// 新建会话（AC-08.1 / AC-08.2）。
    public func createSession(
        title: String? = nil,
        projectId: String? = nil,
        mode: RACPSessionMode? = nil,
        providerId: String? = nil,
        modelId: String? = nil,
        thinkingLevel: RACPThinkingLevel? = nil,
        permissionMode: RACPPermissionMode? = nil
    ) async throws -> RACPSessionSummary {
        let params = RACPSessionCreateParams(
            title: title,
            projectId: projectId,
            mode: mode,
            providerId: providerId,
            modelId: modelId,
            thinkingLevel: thinkingLevel,
            permissionMode: permissionMode
        )
        let result: RACPSessionCreateResult = try await request(.sessionCreate, params: params)
        return result.session
    }

    /// 浏览服务器目录（AC-08.4）。
    public func browseProject(path: String? = nil) async throws -> RACPProjectBrowseResult {
        try await request(.projectBrowse, params: RACPProjectBrowseParams(path: path))
    }

    /// 注册服务器目录为项目（AC-08.4）。
    public func registerProject(path: String) async throws -> RACPProjectSummary {
        let result: RACPProjectRegisterResult = try await request(
            .projectRegister,
            params: RACPProjectRegisterParams(path: path)
        )
        return result.project
    }

    /// 撤销某台设备的配对（AC-03.1）。
    public func revokeDevice(deviceId: String) async throws -> Bool {
        guard !deviceId.isEmpty, !deviceId.contains(where: \.isWhitespace) else {
            throw RACPClientError.protocolMismatch("需要有效的 deviceId")
        }
        let context = RACPV2Context(
            requestId: "req_\(UUID().uuidString)",
            idempotencyKey: "revoke_\(UUID().uuidString)"
        )
        let params = RACPV2RevokeParams(deviceId: deviceId, context: context)
        let value: JSONValue = try await v2Request(
            method: RACPV2Method.revoke.rawValue,
            params: .object([
                "deviceId": .string(params.deviceId),
                "context": .object([
                    "requestId": .string(params.context.requestId),
                    "idempotencyKey": .string(
                        params.context.idempotencyKey ?? "revoke_\(UUID().uuidString)"
                    ),
                ]),
            ])
        )
        let result = try RACPSessionRevokeResult.decoded(from: value)
        return result.revoked
    }

    /// Explicitly legacy `pi-host` operation. PI-adaptor installs and their
    /// staging cleanup must call `revokeDevice` (v2 `connection/revoke`).
    public func revokeLegacyDevice(deviceId: String) async throws -> Bool {
        let result: RACPSessionRevokeResult = try await request(
            .sessionRevoke,
            params: RACPSessionRevokeParams(deviceId: deviceId)
        )
        return result.revoked
    }

    public func sessionView() -> RACPSessionView {
        RACPSessionView(
            sessionId: sessionId,
            summary: attachedSession,
            items: viewModel.items,
            activeItems: viewModel.activeItems,
            queuedTurns: QueuedTurn.parse(viewModel.queuedTurns),
            pendingApprovals: viewModel.pendingApprovals,
            pendingInputs: viewModel.pendingInputs,
            expiredApprovalIds: viewModel.expiredApprovalIds,
            cursor: viewModel.cursor,
            revision: viewModel.revision,
            replayComplete: viewModel.lastReplayComplete,
            hasMoreHistory: viewModel.hasMoreHistory,
            runningTurnId: viewModel.activeTurnId
        )
    }

    /// 请求上下文：`requestId` 每次唯一；幂等键与期望 revision 由调用方给出。
    private func makeContext(idempotencyKey: String? = nil, expectedRevision: Int? = nil) -> RACPContext {
        RACPContext(
            requestId: "req_\(UUID().uuidString)",
            idempotencyKey: idempotencyKey,
            expectedRevision: expectedRevision
        )
    }

    // MARK: 请求

    public func request<P: Encodable & Sendable, R: Decodable & Sendable>(
        _ method: RACPMethod,
        params: P,
        timeout: TimeInterval = 20
    ) async throws -> R {
        let value = try await requestJSON(method, params: params, timeout: timeout)
        return try R.decoded(from: value)
    }

    /// Raw-method escape hatch used by the v2 Host adapter. The existing v1
    /// connection can carry additive v2 methods after the v1 compatibility
    /// handshake; the method string is never guessed or normalized here.
    public func v2Request<R: Decodable & Sendable>(
        method: String,
        params: JSONValue,
        timeout: TimeInterval = 20
    ) async throws -> R {
        let value = try await requestJSONRaw(method: method, params: params, timeout: timeout)
        return try R.decoded(from: value)
    }

    private func requestJSONRaw(
        method: String,
        params: JSONValue,
        timeout: TimeInterval
    ) async throws -> JSONValue {
        guard let socket, state.isOnline else { throw RACPClientError.notConnected }
        let id = RACPIdentifier.number(nextRequestId)
        nextRequestId += 1
        let request = RACPV2RawRequest(id: id, method: method, params: params)
        let data = try JSONEncoder().encode(request)
        guard let text = String(data: data, encoding: .utf8) else {
            throw RACPClientError.malformedFrame("请求编码失败")
        }
        let box = PendingRequest(recoveryScope: nil)
        pending[id] = box
        do {
            try await socket.send(text: text)
            let value = try await box.wait(timeout: timeout, method: method)
            pending.removeValue(forKey: id)
            return value
        } catch {
            pending.removeValue(forKey: id)
            let mapped: Error = error is RACPClientError ? error : RACPClientError.notConnected
            box.resolve(.failure(mapped))
            throw mapped
        }
    }

    private func requestJSON<P: Encodable & Sendable>(
        _ method: RACPMethod,
        params: P,
        timeout: TimeInterval,
        recoveryScope: RequestRecoveryScope? = nil
    ) async throws -> JSONValue {
        if (configuration.deviceToken?.hasPrefix("ppt1.") == true
            || configuration.deviceToken?.hasPrefix("ppt2.") == true),
           method != .pair && method != .initialize {
            throw RACPClientError.protocolMismatch("配对连接只允许交换设备令牌")
        }
        guard let socket, state.isOnline || method == .initialize else { throw RACPClientError.notConnected }
        let id = RACPIdentifier.number(nextRequestId)
        nextRequestId += 1
        let request = RACPRequest(id: id, method: method, params: params)
        let data = try JSONEncoder().encode(request)
        guard let text = String(data: data, encoding: .utf8) else {
            throw RACPClientError.malformedFrame("请求编码失败")
        }
        // 先登记再发送：响应可能比登记更快到达，反序会丢响应并等到超时。
        let box = PendingRequest(recoveryScope: recoveryScope)
        pending[id] = box
        do {
            try await socket.send(text: text)
            let value = try await box.wait(timeout: timeout, method: method.rawValue)
            pending.removeValue(forKey: id)
            return value
        } catch {
            pending.removeValue(forKey: id)
            let mappedError: Error = error is RACPClientError
                ? error
                : RACPClientError.notConnected
            box.resolve(.failure(mappedError))
            throw mappedError
        }
    }

    // MARK: 连接循环

    private func runLoop() async {
        var attempt = 0
        var connectionStageFailures = 0
        while !Task.isCancelled {
            do {
                try await establish()
                attempt = 0
                connectionStageFailures = 0
                guard let socket else { throw RACPClientError.notConnected }
                await emit(.state(.online))
                // Host 订阅必须先于会话恢复建立；否则重连窗口里新建的会话会完全不可见。
                try await subscribeHost()
                // 重连后按游标重新订阅（AC-14.1）。
                if let sessionId = subscribedSessionId {
                    try await subscribeSession(sessionId: sessionId, after: viewModel.cursor)
                }
                let heartbeat = Task { [weak self] in
                    await self?.heartbeatLoop(expectedSocket: socket)
                }
                await socket.waitUntilClosed()
                heartbeat.cancel()
                throw RACPClientError.notConnected
            } catch is CancellationError {
                await teardown(reason: nil)
                return
            } catch {
                let reason = Self.describe(error)
                await teardown(reason: reason)
                if let terminalReason = subscriptionTerminalReason {
                    await emit(.state(.offline(reason: terminalReason)))
                    continuation.finish()
                    return
                }
                if isFatal(error) {
                    // 契约 §7：不可重试的错误不进入退避。
                    await emit(.state(.offline(reason: reason)))
                    continuation.finish()
                    return
                }
                // 握手/认证/转发被服务器拒绝时重试毫无意义，而且会继续冲击 sshd
                // （可能触发 MaxStartups 或 fail2ban，把用户后续的正常连接也封掉）。
                // 同一类失败连续 3 次就停止自动重连，交给用户手动重试。
                if Self.isConnectionStageFailure(error) {
                    connectionStageFailures += 1
                    if connectionStageFailures >= Self.maxConnectionStageFailures {
                        await emit(.state(.offline(
                            reason: reason
                                + "\n连续 \(connectionStageFailures) 次在建立 SSH 通道阶段失败，已停止自动重连。"
                                + "先修服务器（端口/sshd/限流）再点「连接」。"
                        )))
                        continuation.finish()
                        return
                    }
                } else {
                    connectionStageFailures = 0
                }
                attempt += 1
                let delay = backoff.delay(forAttempt: attempt)
                await emit(.state(.reconnecting(attempt: attempt, delay: delay, reason: reason)))
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    private func heartbeatLoop(expectedSocket: any RACPSocket) async {
        var consecutiveFailures = 0
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(10))
            } catch {
                return
            }
            guard self.socket === expectedSocket, state.isOnline else { return }
            do {
                _ = try await requestJSON(
                    .ping,
                    params: RACPEmptyParams(),
                    timeout: 5
                )
                consecutiveFailures = 0
            } catch {
                guard !Task.isCancelled, self.socket === expectedSocket else { return }
                consecutiveFailures += 1
                if consecutiveFailures >= 2 {
                    await expectedSocket.close()
                    return
                }
            }
        }
    }

    /// 连续多少次「建立通道阶段」失败后停止自动重连。
    static let maxConnectionStageFailures = 3

    /// 是不是“再怎么重试也一样”的失败：握手被关闭、认证失败、端口无人监听、主机密钥不被接受。
    static func isConnectionStageFailure(_ error: Error) -> Bool {
        guard let error = error as? SSHTransportError else { return false }
        switch error {
        case .closedByPeer, .authenticationFailed, .tunnelRefused, .hostKeyAlgorithmUnsupported, .hostKeyUnreadable:
            return true
        case .invalidPrivateKey, .hostKeyRejected, .timedOut, .channelClosed, .networkFailure:
            return false
        }
    }

    private func establish() async throws {
        await emit(.state(.connecting))
        let ssh: SSHTransport
        if let suppliedTransport {
            ssh = suppliedTransport
        } else {
            ssh = try await SSHTransport.connect(configuration.ssh, confirmer: confirmer)
        }
        transport = ssh
        await emit(.state(.authenticating))
        let channel = try await ssh.directTCPIP(port: configuration.hostPort)
        await emit(.state(.handshaking))
        let socket = try await RACPWebSocket.connect(
            on: channel,
            bearerToken: configuration.deviceToken
        )
        self.socket = socket
        Task { [weak self] in
            for await message in socket.inbound {
                await self?.receive(message, from: socket)
            }
        }
        try await handshake()
    }

    /// 契约 §2.2：10 秒内完成 `connection/initialize` + `notifications/initialized`。
    private func handshake() async throws {
        let params = RACPInitializeParams(
            client: RACPClientInfo(version: configuration.clientVersion)
        )
        let result: JSONValue = try await withTimeoutValue(seconds: 10, phase: "RACP 握手") {
            try await self.requestJSON(.initialize, params: params, timeout: 10)
        }
        let info = try RACPInitializeResult.decoded(from: result).serverInfo()
        guard info.protocolVersion == RACPInitializeParams.protocolVersion else {
            throw RACPClientError.protocolMismatch("协议版本 \(info.protocolVersion)")
        }
        serverInfo = info
        let notification = RACPNotification(method: .initializedNotification, params: RACPEmptyParams())
        let data = try JSONEncoder().encode(notification)
        guard let text = String(data: data, encoding: .utf8), let socket else {
            throw RACPClientError.malformedFrame("初始化通知编码失败")
        }
        try await socket.send(text: text)
        state = .online
        await emit(.ready(info))
    }

    private func teardown(reason: String?) async {
        socket = nil
        subscriptionId = nil
        pendingSessionSubscriptionAttempt = nil
        pendingSessionSubscriptionSessionId = nil
        pendingSessionSubscriptionGeneration = nil
        pendingSessionAckDuringSubscribe = nil
        isHostSubscriptionPending = false
        pendingHostAckDuringSubscribe = nil
        hostSubscription.prepareForReconnect()
        pendingHostAck = nil
        isDrainingHostAcks = false
        pendingSessionAck = nil
        isDrainingSessionAcks = false
        if let transport {
            await transport.close()
        }
        transport = nil
        serverInfo = nil
        failAllPending(with: RACPClientError.notConnected)
        if !state.isOnline || reason != nil {
            await emit(.state(.offline(reason: reason)))
        }
    }

    /// One-shot bootstrap calls must leave the SSH connection open so the
    /// runner can continue polling and then use the same transport to verify
    /// the device token.
    private func closeWebSocketPreservingTransport() async {
        let socket = self.socket
        self.socket = nil
        subscriptionId = nil
        subscribedSessionId = nil
        pendingSessionSubscriptionAttempt = nil
        pendingSessionSubscriptionSessionId = nil
        pendingSessionSubscriptionGeneration = nil
        pendingSessionAckDuringSubscribe = nil
        isHostSubscriptionPending = false
        pendingHostAckDuringSubscribe = nil
        hostSubscription.prepareForReconnect()
        pendingHostAck = nil
        isDrainingHostAcks = false
        pendingSessionAck = nil
        isDrainingSessionAcks = false
        serverInfo = nil
        state = .offline(reason: nil)
        await socket?.close()
        failAllPending(with: RACPClientError.notConnected)
    }

    private func failAllPending(with error: Error) {
        let waiters = pending
        pending.removeAll()
        for (_, waiter) in waiters {
            waiter.resolve(.failure(error))
        }
    }

    // MARK: 入站帧

    private func receive(_ data: Data, from socket: any RACPSocket) async {
        // 旧 socket 的尾部帧不能在新连接上触发订阅、ack 或会话归约。
        guard self.socket === socket else { return }
        guard let envelope = try? JSONDecoder().decode(RACPInboundEnvelope.self, from: data) else {
            return
        }
        if let id = envelope.id, envelope.method == nil {
            guard let waiter = pending.removeValue(forKey: id) else { return }
            if let error = envelope.error {
                let code = error.normalizedCode
                waiter.resolve(.failure(RACPClientError.server(code: code, message: error.message)))
                await emit(.error(code: code, message: error.message))
            } else {
                waiter.resolve(.success(envelope.result ?? .null))
            }
            return
        }
        // 通知帧：契约没有冻结事件通知的方法名，因此不按前缀判定；
        // 只要求「无 id + 载荷能解出整数 sequence」——这是契约 §3.2 归约的必需字段。
        guard envelope.id == nil, let method = envelope.method else { return }
        if let error = envelope.error {
            await emit(.error(code: error.normalizedCode, message: error.message))
            return
        }
        let payload = envelope.params ?? envelope.result
        if method == "events/closed",
           let payload,
           let notice = try? RACPSubscriptionClosedNotice.decoded(from: payload) {
            Task { [weak self] in
                await self?.handleSubscriptionClosed(notice, from: socket)
            }
            return
        }
        // v2 Host 把事件包成 `params.event`（见 golden 的 `events/event`）；旧 v1 Host
        // 直接把事件放在 `params`。两种都接受，避免实时事件被静默丢弃。
        let eventPayload = payload?.value(at: ["event"]) ?? payload
        guard let eventPayload, let event = try? RACPEvent.decoded(from: eventPayload) else {
            return
        }
        // Capture the subscription lease before any await. A delayed frame from
        // the previous subscription must never be acknowledged against a newer one.
        let sessionLease = subscriptionId
        let hostLease = hostSubscription.subscriptionID
        if sessionEventsSuspended,
           event.scope?.rawValue != RACPSubscriptionScope.host.rawValue {
            return
        }
        switch RACPEventRouter.route(
            event,
            currentSessionID: sessionEventsSuspended ? nil : subscribedSessionId
        ) {
        case .host:
            guard hostLease != nil || isHostSubscriptionPending else { return }
            if let observation = hostSubscription.observe(event),
               observation.requiresCatalogRefresh {
                await emit(.hostChanged(observation.change))
            }
            if let hostLease, let durableSequence = event.durableSequence {
                let ack = PendingEventAck(
                    subscriptionId: hostLease,
                    sequence: durableSequence
                )
                Task { [weak self] in
                    await self?.queueHostAck(ack, from: socket)
                }
            } else if isHostSubscriptionPending, let durableSequence = event.durableSequence {
                pendingHostAckDuringSubscribe = max(
                    pendingHostAckDuringSubscribe ?? 0,
                    durableSequence
                )
            }
        case .session:
            if isRebuildingSnapshot {
                bufferedSessionEventsDuringAttach.append(event)
                if let sessionLease, let durableSequence = event.durableSequence {
                    let ack = PendingEventAck(
                        subscriptionId: sessionLease,
                        sequence: durableSequence
                    )
                    Task { [weak self] in
                        await self?.queueSessionAck(ack, from: socket)
                    }
                }
                return
            }
            switch viewModel.applyEvents([event]) {
            case .applied:
                await emit(.event(event))
                await emit(.sessionChanged)
                if let sessionLease, let durableSequence = event.durableSequence {
                    let ack = PendingEventAck(
                        subscriptionId: sessionLease,
                        sequence: durableSequence
                    )
                    Task { [weak self] in
                        await self?.queueSessionAck(ack, from: socket)
                    }
                } else if let durableSequence = event.durableSequence,
                          pendingSessionSubscriptionAttempt != nil,
                          pendingSessionSubscriptionSessionId == subscribedSessionId,
                          pendingSessionSubscriptionGeneration == sessionAttachGeneration {
                    pendingSessionAckDuringSubscribe = max(
                        pendingSessionAckDuringSubscribe ?? 0,
                        durableSequence
                    )
                }
            case .requiresSnapshotRebuild:
                // Freeze further session frames before yielding to the rebuild
                // task; otherwise a stale event could be applied between the
                // reducer decision and `session/attach`.
                sessionEventsSuspended = true
                Task { [weak self] in
                    guard let self else { return }
                    if await self.rebuildFromSnapshot(from: socket) == .failed {
                        await socket.close()
                    }
                }
            }
        case .ignored:
            return
        }
    }

    private func queueSessionAck(_ ack: PendingEventAck, from socket: any RACPSocket) async {
        guard self.socket === socket, subscriptionId == ack.subscriptionId else { return }
        if let pending = pendingSessionAck,
           pending.subscriptionId == ack.subscriptionId {
            pendingSessionAck = PendingEventAck(
                subscriptionId: ack.subscriptionId,
                sequence: max(pending.sequence, ack.sequence)
            )
        } else {
            pendingSessionAck = ack
        }
        await drainSessionAcks(from: socket)
    }

    /// Serialize ACKs so a later event cannot overtake an earlier durable
    /// sequence. While an ACK is in flight the receive loop can still consume
    /// its response; later events simply raise the pending watermark.
    private func drainSessionAcks(from socket: any RACPSocket) async {
        guard !isDrainingSessionAcks else { return }
        isDrainingSessionAcks = true
        defer { isDrainingSessionAcks = false }

        while let ack = pendingSessionAck, self.socket === socket {
            pendingSessionAck = nil
            // A delayed task for an old subscription must never acknowledge
            // events from the replacement subscription.
            guard subscriptionId == ack.subscriptionId else { continue }
            let params = RACPEventsAckParams(
                subscriptionId: ack.subscriptionId,
                sequence: ack.sequence
            )
            do {
                let _: JSONValue? = try await requestJSON(
                    .eventsAck,
                    params: params,
                    timeout: 10,
                    recoveryScope: .session
                )
            } catch {
                guard self.socket === socket else { break }
                // The subscription changed while the request was in flight;
                // this result cannot poison the replacement subscription.
                guard subscriptionId == ack.subscriptionId else { continue }
                guard Self.requiresCursorReset(error) else {
                    if case let RACPClientError.server(code, message) = error,
                       !code.isRetryable {
                        let reason = RACPClientError.server(code: code, message: message).description
                        subscriptionTerminalReason = reason
                        await emit(.error(code: code, message: message))
                    }
                    await socket.close()
                    break
                }
                if await rebuildFromSnapshot(from: socket) == .failed {
                    await socket.close()
                }
                break
            }
        }
    }

    /// `events/closed` 是订阅级的终态通知；必须只作用于原 socket，并按 lastSafeCursor 恢复，
    /// 不能把旧连接关闭时收到的通知拿来操作新连接。
    private func handleSubscriptionClosed(
        _ notice: RACPSubscriptionClosedNotice,
        from socket: any RACPSocket
    ) async {
        guard self.socket === socket else { return }
        let closesHost = notice.subscriptionId == hostSubscription.subscriptionID
        let closesSession = notice.subscriptionId == subscriptionId
        guard closesHost || closesSession else { return }
        if let subscriptionError = notice.error {
            let code = subscriptionError.normalizedCode
            if code.isRetryable {
                await emit(.error(code: code, message: subscriptionError.message))
                await socket.close()
                return
            }
            guard Self.canRecoverClosedSubscription(code) else {
                await terminateForClosedSubscription(subscriptionError, from: socket)
                return
            }
        }

        if closesHost {
            hostSubscription.prepareForReconnect()
            if let cursor = notice.lastSafeCursor {
                hostSubscription.restoreCursor(cursor)
            }
            pendingHostAck = nil
            await emit(.hostChanged(
                RACPHostChange(
                    reason: .resyncRequired,
                    kind: nil,
                    sessionId: nil,
                    revision: nil,
                    cursor: hostSubscription.cursor,
                    payload: .null
                )
            ))
            guard self.socket === socket else { return }
            do {
                try await subscribeHost()
            } catch {
                await socket.close()
            }
            return
        }

        subscriptionId = nil
        pendingSessionAck = nil
        guard let sessionId = subscribedSessionId else { return }
        let after = notice.lastSafeCursor ?? viewModel.cursor
        do {
            try await subscribeSession(sessionId: sessionId, after: after)
        } catch {
            await socket.close()
        }
    }

    private static func canRecoverClosedSubscription(_ code: RACPErrorCode) -> Bool {
        code == .cursorExpired || code == .clientTooSlow
    }

    private func terminateForClosedSubscription(
        _ error: RACPErrorBody,
        from socket: any RACPSocket
    ) async {
        let code = error.normalizedCode
        let reason = RACPClientError.server(code: code, message: error.message).description
        subscriptionTerminalReason = reason
        await emit(.error(code: code, message: error.message))
        runTask?.cancel()
        await socket.close()
    }

    private func queueHostAck(_ ack: PendingEventAck, from socket: any RACPSocket) async {
        guard self.socket === socket,
              hostSubscription.subscriptionID == ack.subscriptionId
        else { return }
        if let pending = pendingHostAck,
           pending.subscriptionId == ack.subscriptionId {
            pendingHostAck = PendingEventAck(
                subscriptionId: ack.subscriptionId,
                sequence: max(pending.sequence, ack.sequence)
            )
        } else {
            pendingHostAck = ack
        }
        await drainHostAcks(from: socket)
    }

    /// 一批重放事件只发一次 `events/ack`，避免每条事件都制造一次请求风暴。
    private func drainHostAcks(from socket: any RACPSocket) async {
        guard !isDrainingHostAcks else { return }
        isDrainingHostAcks = true
        defer { isDrainingHostAcks = false }

        while let ack = pendingHostAck, self.socket === socket {
            pendingHostAck = nil
            guard hostSubscription.subscriptionID == ack.subscriptionId else { continue }
            let params = RACPEventsAckParams(
                subscriptionId: ack.subscriptionId,
                sequence: ack.sequence
            )
            do {
                let _: JSONValue? = try await requestJSON(
                    .eventsAck,
                    params: params,
                    timeout: 10,
                    recoveryScope: .host
                )
            } catch {
                guard self.socket === socket else { break }
                guard hostSubscription.subscriptionID == ack.subscriptionId else { continue }
                guard Self.requiresCursorReset(error) else {
                    if case let RACPClientError.server(code, message) = error,
                       !code.isRetryable {
                        let reason = RACPClientError.server(code: code, message: message).description
                        subscriptionTerminalReason = reason
                        await emit(.error(code: code, message: message))
                    }
                    await socket.close()
                    break
                }
                hostSubscription.resetAfterCursorExpired()
                pendingHostAck = nil
                await emit(.hostChanged(
                    RACPHostChange(
                        reason: .replayIncomplete,
                        kind: nil,
                        sessionId: nil,
                        revision: nil,
                        cursor: nil,
                        payload: .null
                    )
                ))
                do {
                    try await subscribeHost()
                } catch {
                    await socket.close()
                }
                break
            }
        }
    }

    /// `CURSOR_EXPIRED` / `CLIENT_TOO_SLOW` / epoch 变化 → 重新 attach 拿快照整体替换。
    ///
    /// 注意不要在此处捕获 `sessionAttachGeneration` 再与返回值比较：`attach`
    /// 自身会先递增该值，比较必然失败，导致正常的重建与失败都被误判为
    /// `.superseded`。`attach` 已经内建了 generation 校验（被取代时返回
    /// `nil`），这里改用 socket/会话身份与返回值判断。
    private func rebuildFromSnapshot(from socket: any RACPSocket) async -> SnapshotRebuildOutcome {
        guard self.socket === socket, let sessionId else { return .failed }
        // Keyed by session so concurrent rebuilds for the same session collapse,
        // while a switch to another session does not block its own rebuild.
        guard rebuildingSnapshots.insert(sessionId).inserted else { return .inProgress }
        defer { rebuildingSnapshots.remove(sessionId) }
        viewModel.discardCursorForSnapshotRebuild()
        do {
            let includedSnapshot = try await attach(sessionId: sessionId, subscribe: true)
            guard self.socket === socket, self.sessionId == sessionId else { return .superseded }
            guard let includedSnapshot else { return .superseded }
            return includedSnapshot ? .rebuilt : .failed
        } catch {
            guard self.socket === socket, self.sessionId == sessionId else { return .superseded }
            return .failed
        }
    }

    nonisolated static func requiresCursorReset(_ error: Error) -> Bool {
        guard case let RACPClientError.server(code, _) = error else { return false }
        return code == .cursorExpired || code == .clientTooSlow
    }

    private func emit(_ update: RACPClientUpdate) async {
        if case let .state(newState) = update {
            state = newState
        }
        continuation.yield(update)
    }

    private func isFatal(_ error: Error) -> Bool {
        switch error {
        case RACPClientError.protocolMismatch:
            return true
        case RACPClientError.server(let code, _):
            return !code.isRetryable
        case SSHTransportError.hostKeyRejected, SSHTransportError.invalidPrivateKey:
            return true
        default:
            return false
        }
    }

    private static func describe(_ error: Error) -> String {
        if let error = error as? RACPClientError { return error.description }
        if let error = error as? SSHTransportError { return error.description }
        if let error = error as? SSHPrivateKeyError { return error.description }
        if let error = error as? RACPWebSocketError { return error.description }
        return error.localizedDescription
    }
}

// MARK: - 帧与结果形状

/// 入站帧：在 `RACPIncomingFrame` 之外还需 `params`（事件帧的有效载荷），
/// 因此这里单独解一层；响应部分与 `RACPIncomingFrame` 的语义一致。
struct RACPInboundEnvelope: Decodable {
    var id: RACPIdentifier?
    var method: String?
    var result: JSONValue?
    var error: RACPErrorBody?
    var params: JSONValue?
}

/// `events/closed` 通知体。
///
/// v2 契约（`docs/api/pi-adaptor.md`）冻结为扁平 `{ "subscriptionId": …, "code": "UNAUTHORIZED" }`；
/// 早期 v1 形状把错误包在 `error` 对象里。两种都接受，否则严格按 v2 发来的终态码
/// （如设备被撤销的 `UNAUTHORIZED`）会被当成 `error == nil` 的可恢复关闭，导致无限重订阅而非进入终态。
struct RACPSubscriptionClosedNotice: Decodable, Equatable {
    var subscriptionId: String
    var error: RACPErrorBody?
    var lastSafeCursor: RACPCursor?

    private enum CodingKeys: String, CodingKey {
        case subscriptionId, error, lastSafeCursor, code, message
    }

    init(subscriptionId: String, error: RACPErrorBody?, lastSafeCursor: RACPCursor?) {
        self.subscriptionId = subscriptionId
        self.error = error
        self.lastSafeCursor = lastSafeCursor
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.subscriptionId = try container.decode(String.self, forKey: .subscriptionId)
        self.lastSafeCursor = try container.decodeIfPresent(RACPCursor.self, forKey: .lastSafeCursor)
        if let nested = try container.decodeIfPresent(RACPErrorBody.self, forKey: .error) {
            self.error = nested
        } else if let code = try container.decodeIfPresent(String.self, forKey: .code) {
            let message = try container.decodeIfPresent(String.self, forKey: .message)
            self.error = RACPErrorBody(code: code, message: message)
        } else {
            self.error = nil
        }
    }
}

/// `session/attach` 的参数与返回（契约 §3.1 / §3.2）。
struct RACPSessionAttachParams: Encodable, Sendable {
    var sessionId: String
    var includeSnapshot = true
    var role: String?
    var after: RACPCursor?

    enum CodingKeys: String, CodingKey {
        case sessionId, includeSnapshot, role, after
    }
}

struct RACPSessionAttachResult: Decodable {
    var session: RACPSessionSummary
    var role: String?
    var replayComplete: Bool?
    var snapshot: RACPSnapshot?
}

struct RACPInitializeResult: Decodable {
    struct Server: Decodable {
        var name: String?
        var version: String?
        var hostId: String?
    }

    struct Principal: Decodable {
        var subject: String?
        var roles: [String]?
    }

    struct Policy: Decodable {
        var remoteMaxPermissionMode: String?
        var applyCeilingToPairedDevices: Bool?
    }

    var protocolVersion: String
    var server: Server?
    var connectionId: String?
    var principal: Principal?
    var policy: Policy?
    var capabilities: JSONValue?

    func serverInfo() -> RACPServerInfo {
        RACPServerInfo(
            protocolVersion: protocolVersion,
            serverName: server?.name ?? "",
            serverVersion: server?.version ?? "",
            hostId: server?.hostId,
            connectionId: connectionId ?? "",
            roles: principal?.roles ?? [],
            remoteMaxPermissionMode: policy?.remoteMaxPermissionMode,
            applyCeilingToPairedDevices: policy?.applyCeilingToPairedDevices,
            capabilities: capabilities
        )
    }
}

private struct RACPV2AttachmentCreateResult: Decodable {
    var attachmentId: String
    var chunkSize: Int
    var expiresAt: String
}

private struct RACPV2AttachmentChunkResult: Decodable {
    var receivedBytes: Int
}

private struct RACPV2AttachmentEnvelope: Decodable {
    var attachment: RACPV2Attachment
}

/// `connection/ping` 的返回（`{ok, serverTime}`）。
struct RACPJSONObject: Decodable, Sendable {
    var ok: Bool?
    var serverTime: String?
}

// MARK: - 辅助

private func withTimeoutValue<T: Sendable>(
    seconds: TimeInterval,
    phase: String,
    _ body: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw RACPClientError.timedOut(phase)
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

/// 一次请求-响应的等待者：按 JSON-RPC `id` 关联，不按到达顺序（契约 §3 请求-响应关联）。
final class PendingRequest: @unchecked Sendable {
    fileprivate let recoveryScope: RequestRecoveryScope?
    private let lock = NSLock()
    private var continuation: CheckedContinuation<JSONValue, Error>?
    private var settled: Result<JSONValue, Error>?
    private var timeoutTask: Task<Void, Never>?

    fileprivate init(recoveryScope: RequestRecoveryScope? = nil) {
        self.recoveryScope = recoveryScope
    }

    func resolve(_ result: Result<JSONValue, Error>) {
        lock.lock()
        timeoutTask?.cancel()
        timeoutTask = nil
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(with: result)
            return
        }
        if settled == nil {
            settled = result
        }
        lock.unlock()
    }

    func wait(timeout: TimeInterval, method: String) async throws -> JSONValue {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let settled {
                lock.unlock()
                continuation.resume(with: settled)
                return
            }
            self.continuation = continuation
            lock.unlock()
            let task = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.resolve(.failure(RACPClientError.timedOut(method)))
            }
            lock.lock()
            timeoutTask = task
            lock.unlock()
        }
    }
}

/// `turn/interrupt` / `turn/cancel` 按 `turnId` 寻址（契约 §3.1）。
/// v2 契约（`docs/api/pi-adaptor.md` §2）要求所有写操作携带 `context`，因此这里带上
/// `requestId`（每次唯一），与其它写操作一致，便于去重与链路追踪。
struct RACPTurnIDParams: Encodable, Sendable {
    var turnId: String
    var context: RACPContext
}
