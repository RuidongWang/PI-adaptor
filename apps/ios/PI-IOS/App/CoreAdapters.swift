import SwiftUI
import PIiOSCore
import PIiOSNet

// MARK: - App ↔ PIiOSCore / PIiOSNet 的适配层

/// 权限徽标需要的展示信息。枚举本身来自 `PIiOSCore.RACPPermissionMode`，
/// App 里不再保留第二份 `PIPermissionMode`（避免两处枚举漂移）。
extension RACPPermissionMode {
    var title: String {
        switch self {
        case .ask: return "每次询问"
        case .acceptEdits: return "允许编辑"
        case .auto: return "全自动"
        }
    }

    /// 语义色：ask 灰、accept-edits 蓝、auto 橙（design-system.md §3）。
    var tint: Color {
        switch self {
        case .ask: return PIColor.text2
        case .acceptEdits: return PIColor.accent
        case .auto: return PIColor.warning
        }
    }
}

extension RACPSessionMode {
    var title: String {
        switch self {
        case .agent: return "Agent"
        case .plan: return "Plan"
        case .goal: return "Goal"
        }
    }
}

/// 契约 §7「客户端行为」对用户显示的文案。行为本身在 `RACPErrorCode.action` 里，
/// 这里只负责把它说成人话；未知码原样展示，不静默归为成功。
extension RACPErrorCode {
    var userMessage: String {
        switch self {
        case .unauthorized: return "设备令牌已失效：需要重新配对后再连"
        case .forbidden: return "当前设备没有这个操作的权限"
        case .protocolMismatch: return "服务器版本不兼容，已停止连接"
        case .invalidArgument: return "参数不合法"
        case .notFound: return "对象不存在，列表已刷新"
        case .methodNotFound: return "这台服务器不支持该操作"
        case .agentUnavailable: return "Host 暂不可用，正在退避重连"
        case .agentBusy: return "Host 正忙"
        case .conflict: return "状态已变化，重新拉取后再试"
        case .idempotencyConflict: return "同一幂等键对应了不同内容，需要人工确认"
        case .cursorExpired: return "事件游标已过期，已按快照重建"
        case .clientTooSlow: return "客户端处理过慢，已丢弃订阅并按快照重建"
        case .approvalExpired: return "审批已过期"
        case .approvalStale: return "审批已失效"
        case .payloadTooLarge: return "内容超过上限，请压缩后重试"
        case .rateLimited: return "请求过于频繁，稍后重试"
        case .pairingFailed: return "配对失败"
        case .pairingTokenExpired: return "配对令牌已过期，需要重启 Host 取新令牌"
        case .capabilityUnavailable: return "服务器未提供该能力"
        case .serverInternal: return "服务器内部错误"
        case .unknown(let raw): return raw
        }
    }
}

/// 隧道状态的展示信息（设置页与项目页共用，保证两处口径一致）。
extension RACPTunnelState {
    var bannerKind: PIStatusKind {
        switch self {
        case .online: return .success
        case .offline: return .info
        case .reconnecting, .verifyingHostKey: return .warning
        case .connecting, .authenticating, .handshaking: return .info
        }
    }

    /// 供列表行使用的详细说明；`nil` 表示无需额外解释。
    var detail: String? {
        switch self {
        case .offline(let reason): return reason
        case .reconnecting(let attempt, let delay, let reason):
            return "第 \(attempt) 次重连，\(Int(delay)) 秒后重试。上次原因：\(reason)"
        case .verifyingHostKey(_, let status):
            switch status {
            case .firstUse: return "首次连接：确认指纹后才会建立连接"
            case .changed(let pinned): return "指纹与固定记录不一致（原 \(pinned.fingerprint)），已拒绝连接"
            case .matches: return "与固定记录一致"
            }
        default:
            return nil
        }
    }
}
