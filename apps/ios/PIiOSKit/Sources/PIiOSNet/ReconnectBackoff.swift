import Foundation

/// 重连退避（契约 §7 `AGENT_UNAVAILABLE`：1s/2s/4s/8s，上限 30s）。
public struct ReconnectBackoff: Equatable, Sendable {
    /// 契约写明的四档。
    public static let contractSchedule: [TimeInterval] = [1, 2, 4, 8]
    /// 契约写明的上限。
    public static let maximumDelay: TimeInterval = 30

    public let schedule: [TimeInterval]
    public let maximumDelay: TimeInterval

    public init(
        schedule: [TimeInterval] = ReconnectBackoff.contractSchedule,
        maximumDelay: TimeInterval = ReconnectBackoff.maximumDelay
    ) {
        self.schedule = schedule.isEmpty ? ReconnectBackoff.contractSchedule : schedule
        self.maximumDelay = maximumDelay
    }

    /// `attempt` 从 1 开始：1s → 2s → 4s → 8s → 16s → 30s → 30s…
    ///
    /// 契约只冻结了前四档与 30s 上限；中间按「每次翻倍、不超过上限」推进，
    /// 不做随机抖动（抖动会让 AC-14.1 的 30 秒重连窗口不可预期）。
    public func delay(forAttempt attempt: Int) -> TimeInterval {
        guard attempt > 0 else { return 0 }
        if attempt <= schedule.count {
            return schedule[attempt - 1]
        }
        var delay = schedule[schedule.count - 1]
        for _ in schedule.count..<attempt {
            delay = min(delay * 2, maximumDelay)
        }
        return min(delay, maximumDelay)
    }
}
