import Foundation

/// 首屏落地规则（information-architecture.md §1 / gaps.md Q-6）。
///
/// Q-6 的四个分支：
/// - 无主机 → 设置页空态
/// - 有主机但未配对 → 设置页（给出「重新配对」）
/// - 已配对但离线 → 设置页离线视图
/// - 已配对且在线 → 项目页
///
/// 规则集中在此处，首次启动只按本机记录恢复目标页；实时隧道状态由设置页展示。
enum LandingRule {
    static func initialRoot(hosts: [HostRecord]) -> AppModel.Root {
        guard let current = hosts.first(where: { $0.isCurrent }) ?? hosts.first else {
            return .settings // 无主机 → 设置页空态
        }
        guard current.pairedAt != nil else {
            return .settings // 未配对 → 设置页
        }
        guard current.tunnelUpAt != nil else {
            return .settings // 已配对但离线 → 设置页离线视图
        }
        return .projects // 已配对且在线 → 项目页
    }
}
