import Foundation

// MARK: - 待处理决策的可提交性（AC-10.x / AC-11.x / AC-14.5 / AC-14.6）

/// 一张审批/提问卡在当前快照下的可提交状态。
public enum DecisionAvailability: Equatable, Sendable {
    /// 可提交；`revision` 来自快照里该卡自己的 `revision`（作为 `context.expectedRevision`）。
    case actionable(revision: Int?)
    /// 曾出现但已不在快照里：界面标为失效，不能提交（AC-14.5）。
    case expired
    /// 快照里从来没有这张卡（例如被删除的会话）：按未知处理，不能提交。
    case missing

    public var isActionable: Bool {
        if case .actionable = self { return true }
        return false
    }

    /// 卡片右侧的说明文案；`nil` 表示无需额外提示。
    public var statusText: String? {
        switch self {
        case .actionable: return nil
        case .expired: return "已失效"
        case .missing: return "请求已不存在"
        }
    }
}

/// 审批与提问的可提交性判定。
///
/// 核心规则（AC-14.6）：提交时必须用**快照里该卡自己的** revision；
/// 卡片不在快照里时一律不可提交，绝不拿会话 revision 顶替。
public enum DecisionPolicy {
    public static func approvalAvailability(
        id: String,
        pending: [RACPApprovalRequest],
        expiredIds: Set<String>
    ) -> DecisionAvailability {
        if expiredIds.contains(id) { return .expired }
        if let card = pending.first(where: { $0.id == id }) {
            return .actionable(revision: card.revision)
        }
        return .missing
    }

    public enum ContractError: Error, LocalizedError {
        case noAllowedPermissionMode

        public var errorDescription: String? { "审批未提供可用的权限模式：请刷新后重试" }
    }

    public static func contractAction(
        for card: RACPApprovalRequest,
        decision: RACPContractDecision,
        currentMode: RACPPermissionMode
    ) throws -> SessionRequestAction {
        guard let values = card.payload.value(at: ["allowedPermissionModes"])?.arrayValue,
              !values.isEmpty else { throw ContractError.noAllowedPermissionMode }
        let allowed = values.compactMap { $0.stringValue.flatMap(RACPPermissionMode.init(rawValue:)) }
        guard allowed.count == values.count else { throw ContractError.noAllowedPermissionMode }
        return .contract(decision: decision, permissionMode: allowed.contains(currentMode) ? currentMode : allowed[0])
    }

    public static func inputAvailability(
        id: String,
        pending: [RACPInputRequest]
    ) -> DecisionAvailability {
        guard let card = pending.first(where: { $0.id == id }) else { return .missing }
        return .actionable(revision: card.revision)
    }

    /// 审批失败后是否应把卡片标为失效：只有这两种错误码能证明该请求已经不能被处理。
    public static func marksCardStale(after error: RACPErrorCode) -> Bool {
        error == .approvalExpired || error == .approvalStale || error == .notFound
    }
}

// MARK: - 排队补充指令（AC-13.1 / AC-13.2）

/// 一条排队中的 turn。`queuedTurns` 元素内部形状未冻结，只读 `id` 与可选的文本摘要。
public struct QueuedTurn: Equatable, Sendable, Identifiable {
    public let id: String
    public let text: String?

    public init(id: String, text: String? = nil) {
        self.id = id
        self.text = text
    }

    /// 从快照 `queuedTurns[]` 解析；缺字符串 `id` 的元素无法取消，直接丢弃而不是猜一个 id。
    public static func parse(_ payloads: [JSONValue]) -> [QueuedTurn] {
        var seen = Set<String>()
        var result: [QueuedTurn] = []
        for payload in payloads {
            guard let id = payload.value(at: ["id"])?.stringValue, !id.isEmpty else { continue }
            guard seen.insert(id).inserted else { continue }
            let text = payload.value(at: ["text"])?.stringValue
                ?? payload.value(at: ["input", "text"])?.stringValue
            result.append(QueuedTurn(id: id, text: text))
        }
        return result
    }
}

/// 发送动作的准入结论：决定 `turn/start` 用哪种 `admission`。
public enum SendAdmission: Equatable, Sendable {
    /// 空闲：直接开始新一轮。
    case start
    /// 有 turn 在跑：以 `admission: queue` 排队（AC-13.1）。
    case queue(runningTurnId: String?)
    /// 不在线：禁止发送（AC-15.2 / AC-G1）。
    case blockedOffline

    public var turnAdmission: RACPTurnAdmission? {
        switch self {
        case .start, .blockedOffline: return nil
        case .queue: return .queue
        }
    }

    public var isAllowed: Bool { self != .blockedOffline }
}

public enum TurnQueuePolicy {
    /// 会话是否正在运行：快照 `activeItems` 非空或显式给了运行中的 turn id。
    public static func isRunning(activeItemCount: Int, runningTurnId: String?) -> Bool {
        activeItemCount > 0 || runningTurnId != nil
    }

    public static func admission(online: Bool, activeItemCount: Int, runningTurnId: String?) -> SendAdmission {
        guard online else { return .blockedOffline }
        guard isRunning(activeItemCount: activeItemCount, runningTurnId: runningTurnId) else { return .start }
        return .queue(runningTurnId: runningTurnId)
    }

    /// `turn/start` 返回排队项时，当前运行 turn 不能被排队项 ID 覆盖。
    public static func runningTurnIdAfterStart(
        current: String?,
        startedTurnId: String,
        admission: RACPTurnAdmission?
    ) -> String? {
        admission == .queue ? current : startedTurnId
    }

    /// 中止按钮可用条件：在线且确有 turn 在跑（AC-09.1）。
    public static func canInterrupt(online: Bool, runningTurnId: String?) -> Bool {
        canInterrupt(
            online: online,
            activeItemCount: runningTurnId == nil ? 0 : 1,
            runningTurnId: runningTurnId
        )
    }

    /// `activeItems` 非空时即使本地尚无 turn id，也必须允许点击中止；
    /// 点击后会通过 `session/get.activeTurnId` 解析实际的 turn。
    public static func canInterrupt(
        online: Bool,
        activeItemCount: Int,
        runningTurnId: String?
    ) -> Bool {
        online && (runningTurnId != nil || activeItemCount > 0)
    }

    /// 取消排队项的可用条件：在线且该 id 仍在队列里（AC-13.2）。
    public static func canCancel(queued: [QueuedTurn], id: String) -> Bool {
        queued.contains { $0.id == id }
    }
}
