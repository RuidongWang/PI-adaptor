import Foundation

/// 进入后台时的通知基线。会话 revision 使用 `-1` 表示尚未取得 revision。
public struct BackgroundNotificationBaseline: Equatable, Sendable {
    public var hostID: UUID?
    public var sessionRevisions: [String: Int]
    public var pendingApprovalIDs: Set<String>

    public init(
        hostID: UUID?,
        sessionRevisions: [String: Int],
        pendingApprovalIDs: Set<String>
    ) {
        self.hostID = hostID
        self.sessionRevisions = sessionRevisions
        self.pendingApprovalIDs = pendingApprovalIDs
    }
}

/// 回到前台并完成刷新后的当前快照。
public struct BackgroundNotificationSnapshot: Equatable, Sendable {
    public var hostID: UUID?
    public var sessionRevisions: [String: Int]
    public var pendingApprovalIDs: Set<String>

    public init(
        hostID: UUID?,
        sessionRevisions: [String: Int],
        pendingApprovalIDs: Set<String>
    ) {
        self.hostID = hostID
        self.sessionRevisions = sessionRevisions
        self.pendingApprovalIDs = pendingApprovalIDs
    }
}

public enum BackgroundNotificationIgnoreReason: Equatable, Sendable {
    case missingBaseline
    case hostChanged
}

public enum BackgroundNotificationDecision: Equatable, Sendable {
    case ignore(BackgroundNotificationIgnoreReason)
    case noChanges
    case notify(updatedSessionCount: Int, newApprovalCount: Int)
    case alreadyHandled

    /// 一次前台补偿最多发一条通知；有新审批但没有 revision 变化时仍计为一个更新。
    public var notificationCount: Int {
        guard case let .notify(updatedSessionCount, newApprovalCount) = self else {
            return 0
        }
        return max(updatedSessionCount, newApprovalCount > 0 ? 1 : 0)
    }
}

public enum BackgroundNotificationPolicy {
    public static func evaluate(
        baseline: BackgroundNotificationBaseline,
        current: BackgroundNotificationSnapshot
    ) -> BackgroundNotificationDecision {
        guard let baselineHostID = baseline.hostID else {
            return .ignore(.missingBaseline)
        }
        guard current.hostID == baselineHostID else {
            return .ignore(.hostChanged)
        }

        let updatedSessionCount = current.sessionRevisions.reduce(into: 0) { count, entry in
            let previousRevision = baseline.sessionRevisions[entry.key] ?? -1
            if previousRevision != entry.value {
                count += 1
            }
        }
        let newApprovalCount = current.pendingApprovalIDs
            .subtracting(baseline.pendingApprovalIDs)
            .count

        guard updatedSessionCount > 0 || newApprovalCount > 0 else {
            return .noChanges
        }
        return .notify(
            updatedSessionCount: updatedSessionCount,
            newApprovalCount: newApprovalCount
        )
    }
}

/// 同一后台→前台 transition 只允许解析一次。值语义便于单测，也可直接由协调器持有。
public struct ForegroundNotificationTracker: Sendable {
    private struct ActiveTransition: Sendable {
        var id: UUID
        var baseline: BackgroundNotificationBaseline
    }

    private var activeTransition: ActiveTransition?
    private var lastHandledTransitionID: UUID?

    public init() {}

    public var hasActiveTransition: Bool {
        activeTransition != nil
    }

    public mutating func begin(
        transitionID: UUID,
        baseline: BackgroundNotificationBaseline
    ) {
        activeTransition = ActiveTransition(id: transitionID, baseline: baseline)
    }

    public mutating func resolve(
        transitionID: UUID,
        current: BackgroundNotificationSnapshot
    ) -> BackgroundNotificationDecision {
        if lastHandledTransitionID == transitionID {
            return .alreadyHandled
        }
        guard let activeTransition,
              activeTransition.id == transitionID
        else {
            return .alreadyHandled
        }

        lastHandledTransitionID = transitionID
        self.activeTransition = nil
        return BackgroundNotificationPolicy.evaluate(
            baseline: activeTransition.baseline,
            current: current
        )
    }
}

public enum LocalNotificationAuthorizationStatus: Equatable, Sendable {
    case notDetermined
    case denied
    case authorized
    case provisional
    case ephemeral
}

public enum LocalNotificationAuthorizationPolicy {
    /// 只在系统尚未询问且本进程尚未尝试过时请求；拒绝或请求失败都不重试。
    public static func shouldRequest(
        status: LocalNotificationAuthorizationStatus,
        alreadyAttempted: Bool
    ) -> Bool {
        status == .notDetermined && !alreadyAttempted
    }

    public static func canDeliver(status: LocalNotificationAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined, .denied:
            return false
        }
    }
}
