import Foundation

public struct ProviderRemovePayload: Codable, Equatable, Sendable {
    public var version: Int
    public var providerId: String

    public init(providerId: String, version: Int = 1) {
        self.version = version
        self.providerId = providerId
    }
}

public enum ProviderRemoveEffect: String, Equatable, Sendable {
    case deleted
    case absent
}

public enum ProviderDefaultMove: Equatable, Sendable {
    case moved(providerId: String, modelId: String)
    case notMoved(reason: String)
}

public struct ProviderRemoveSummary: Equatable, Sendable {
    public var providerId: String
    public var effect: ProviderRemoveEffect
    public var secretCleared: Bool
    public var defaultMoved: ProviderDefaultMove?
    public var remaining: Int
    public var remainingEligible: Int

    public init(
        providerId: String,
        effect: ProviderRemoveEffect,
        secretCleared: Bool,
        defaultMoved: ProviderDefaultMove? = nil,
        remaining: Int,
        remainingEligible: Int
    ) {
        self.providerId = providerId
        self.effect = effect
        self.secretCleared = secretCleared
        self.defaultMoved = defaultMoved
        self.remaining = remaining
        self.remainingEligible = remainingEligible
    }
}

public enum ProviderRemoveParseError: Error, Equatable, Sendable {
    case invalidJSON
    case invalidShape
}

public enum ProviderRemoveParser {
    private static let providerIDPattern = #"^[a-fA-F0-9-]{36}$"#

    public static func parseSummary(_ data: Data) throws -> ProviderRemoveSummary {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any]
        else { throw ProviderRemoveParseError.invalidJSON }

        let allowed = Set([
            "providerId", "effect", "secretCleared", "defaultMoved", "remaining", "remainingEligible",
        ])
        guard Set(root.keys).isSubset(of: allowed),
              let providerId = root["providerId"] as? String,
              providerId.range(of: providerIDPattern, options: .regularExpression) != nil,
              let effectRaw = root["effect"] as? String,
              let effect = ProviderRemoveEffect(rawValue: effectRaw),
              root["secretCleared"] as? Bool == true,
              let remaining = nonNegativeInteger(root["remaining"]),
              let remainingEligible = nonNegativeInteger(root["remainingEligible"])
        else { throw ProviderRemoveParseError.invalidShape }

        var defaultMoved: ProviderDefaultMove?
        if let value = root["defaultMoved"] {
            guard effect != .absent else { throw ProviderRemoveParseError.invalidShape }
            defaultMoved = try parseDefaultMoved(value)
        }
        return ProviderRemoveSummary(
            providerId: providerId,
            effect: effect,
            secretCleared: true,
            defaultMoved: defaultMoved,
            remaining: remaining,
            remainingEligible: remainingEligible
        )
    }

    private static func parseDefaultMoved(_ value: Any) throws -> ProviderDefaultMove {
        guard let object = value as? [String: Any],
              let orderingBasis = object["orderingBasis"] as? String
        else { throw ProviderRemoveParseError.invalidShape }

        if object["to"] is NSNull {
            let allowed = Set(["to", "reason", "orderingBasis"])
            guard Set(object.keys) == allowed,
                  orderingBasis == "none",
                  let reason = object["reason"] as? String,
                  ["no_remaining", "no_eligible_candidate"].contains(reason)
            else { throw ProviderRemoveParseError.invalidShape }
            return .notMoved(reason: reason)
        }

        let allowed = Set(["to", "orderingBasis"])
        guard Set(object.keys) == allowed,
              orderingBasis == "createdAt",
              let target = object["to"] as? [String: Any],
              Set(target.keys) == Set(["providerId", "modelId"]),
              let providerId = target["providerId"] as? String,
              providerId.range(of: providerIDPattern, options: .regularExpression) != nil,
              let modelId = target["modelId"] as? String,
              !modelId.isEmpty
        else { throw ProviderRemoveParseError.invalidShape }
        return .moved(providerId: providerId, modelId: modelId)
    }

    private static func nonNegativeInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              number.doubleValue.rounded() == number.doubleValue,
              number.doubleValue >= 0,
              number.doubleValue <= Double(Int.max)
        else { return nil }
        return number.intValue
    }
}

/// `PI_HOST_FAILED {"code":"…"}` 的失败码。删除增量的管理通道会返回 21 个码
/// （服务端 `FAILURE_CODES`：import 的 6 个 + 删除类新增 15 个）。识别全部 21 个，
/// 否则客户端会把一个合法失败码显示成「未识别的失败码」，无法给出可执行的下一步
/// （契约 §8；分类固定、文案属实现期）。
public enum ProviderRemoveFailureCode: Equatable, Sendable {
    // 既有 6 个（与 provider-import 共用字面量）
    case invalidRequest
    case payloadTooLarge
    case adminUnavailable
    case adminBusy
    case timeout
    case importFailed
    // 删除增量新增 15 个
    case notFound
    case resultUnknown
    case removeFailed
    case secretNotCleared
    case defaultTransferFailed
    case defaultTransferUnknown
    case defaultOrderUndecidable
    case defaultTransferOrderUnknown
    case pluginOwned
    case snapshotUnstable
    case forgetFailed
    case targetStillExists
    case unsupportedOp
    case responseTooLarge
    case responseInvalid
    case unknown(String)

    public init(raw: String) {
        switch raw {
        case "INVALID_REQUEST": self = .invalidRequest
        case "PAYLOAD_TOO_LARGE": self = .payloadTooLarge
        case "ADMIN_UNAVAILABLE": self = .adminUnavailable
        case "ADMIN_BUSY": self = .adminBusy
        case "TIMEOUT": self = .timeout
        case "IMPORT_FAILED": self = .importFailed
        case "NOT_FOUND": self = .notFound
        case "RESULT_UNKNOWN": self = .resultUnknown
        case "REMOVE_FAILED": self = .removeFailed
        case "SECRET_NOT_CLEARED": self = .secretNotCleared
        case "DEFAULT_TRANSFER_FAILED": self = .defaultTransferFailed
        case "DEFAULT_TRANSFER_UNKNOWN": self = .defaultTransferUnknown
        case "DEFAULT_ORDER_UNDECIDABLE": self = .defaultOrderUndecidable
        case "DEFAULT_TRANSFER_ORDER_UNKNOWN": self = .defaultTransferOrderUnknown
        case "PLUGIN_OWNED": self = .pluginOwned
        case "SNAPSHOT_UNSTABLE": self = .snapshotUnstable
        case "FORGET_FAILED": self = .forgetFailed
        case "TARGET_STILL_EXISTS": self = .targetStillExists
        case "UNSUPPORTED_OP": self = .unsupportedOp
        case "RESPONSE_TOO_LARGE": self = .responseTooLarge
        case "RESPONSE_INVALID": self = .responseInvalid
        default: self = .unknown(raw)
        }
    }

    public var rawValue: String {
        switch self {
        case .invalidRequest: return "INVALID_REQUEST"
        case .payloadTooLarge: return "PAYLOAD_TOO_LARGE"
        case .adminUnavailable: return "ADMIN_UNAVAILABLE"
        case .adminBusy: return "ADMIN_BUSY"
        case .timeout: return "TIMEOUT"
        case .importFailed: return "IMPORT_FAILED"
        case .notFound: return "NOT_FOUND"
        case .resultUnknown: return "RESULT_UNKNOWN"
        case .removeFailed: return "REMOVE_FAILED"
        case .secretNotCleared: return "SECRET_NOT_CLEARED"
        case .defaultTransferFailed: return "DEFAULT_TRANSFER_FAILED"
        case .defaultTransferUnknown: return "DEFAULT_TRANSFER_UNKNOWN"
        case .defaultOrderUndecidable: return "DEFAULT_ORDER_UNDECIDABLE"
        case .defaultTransferOrderUnknown: return "DEFAULT_TRANSFER_ORDER_UNKNOWN"
        case .pluginOwned: return "PLUGIN_OWNED"
        case .snapshotUnstable: return "SNAPSHOT_UNSTABLE"
        case .forgetFailed: return "FORGET_FAILED"
        case .targetStillExists: return "TARGET_STILL_EXISTS"
        case .unsupportedOp: return "UNSUPPORTED_OP"
        case .responseTooLarge: return "RESPONSE_TOO_LARGE"
        case .responseInvalid: return "RESPONSE_INVALID"
        case let .unknown(raw): return raw
        }
    }

    /// 中文说明：写清「执行到了哪一步、结果是否确定、下一步做什么」（契约 §8 的三态语义）。
    public var displayMessage: String {
        switch self {
        case .invalidRequest:
            return "Host 认为删除载荷不合法（providerId 或信封不符合契约），未执行删除"
        case .payloadTooLarge:
            return "载荷超过上限，未执行删除"
        case .adminUnavailable:
            return "Host 未运行或 admin.sock 不可用，字节未写出，删除未执行；修复隧道/服务后重试"
        case .adminBusy:
            return "Host 正忙（与另一次导入或删除互斥），未执行删除，请稍后重试"
        case .timeout:
            return "请求超时，删除结果不确定：请先在服务器上人工确认，勿直接重复删除"
        case .importFailed:
            return "Host 侧操作失败，请查看 Host 日志后再决定"
        case .notFound:
            return "目标模型服务不存在（可能已被删除），本机记录可清理"
        case .resultUnknown:
            return "删除结果不确定：请求已发出但未收到确认，请在服务器上人工确认，勿重复删除"
        case .removeFailed:
            return "删除未完成（Host 明确失败），本机记录保留"
        case .secretNotCleared:
            return "服务已删除但密钥未清除，请在服务器上人工清理残留密钥"
        case .defaultTransferFailed:
            return "服务已删除，但默认模型未转移，请重新选择默认模型"
        case .defaultTransferUnknown:
            return "服务已删除；默认模型是否转移不确定，请重新选择默认模型"
        case .defaultOrderUndecidable:
            return "无法判定默认项顺序，未执行删除（0 次写）"
        case .defaultTransferOrderUnknown:
            return "服务已删除，但默认项因创建时间不可比未转移，请重新选择默认模型"
        case .pluginOwned:
            return "该模型服务由插件管理，不能在这里删除"
        case .snapshotUnstable:
            return "服务端快照在两次读取间发生变化，无法确认结果，请点击重新检查"
        case .forgetFailed:
            return "清除导入回执失败，回执仍然保留"
        case .targetStillExists:
            return "目标模型服务仍然存在，未清除其导入回执"
        case .unsupportedOp:
            return "当前 PI-adaptor 不支持该操作（能力缺失），请升级服务器上的 PI-adaptor 2.0.1"
        case .responseTooLarge:
            return "Host 响应超过上限，结果不确定，请在服务器上人工确认"
        case .responseInvalid:
            return "Host 响应不符合契约，结果不确定，请在服务器上人工确认"
        case let .unknown(raw):
            return "未识别的失败码：\(raw)"
        }
    }
}

public enum ProviderRemoveReceipt: Equatable, Sendable {
    case success(ProviderRemoveSummary)
    case failure(ProviderRemoveFailureCode)
    /// `DEFAULT_TRANSFER_ORDER_UNKNOWN` 的四键形态（契约 §4.2/§8 的明确例外）：
    /// 记录与密钥已删除，但默认项因创建时间不可比而未转移；`removed`/`defaultTransfer`
    /// 详情必须呈现，否则用户看不到「已删但默认项未定」的两半结论。
    case defaultTransferOrderUnknown(removedProviderId: String, secretCleared: Bool)
    case unparseable(reason: String)
}

public enum ProviderRemoveReceiptParser {
    public static let successPrefix = "PI_HOST_REMOVED"
    public static let failurePrefix = "PI_HOST_FAILED"

    public static func parse(stdout: String, exitCode: Int32? = nil) -> ProviderRemoveReceipt {
        let lines = stdout.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
        for line in lines {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix(failurePrefix) {
                let payload = text.dropFirst(failurePrefix.count).trimmingCharacters(in: .whitespaces)
                guard let data = payload.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data),
                      let root = object as? [String: Any],
                      let code = root["code"] as? String
                else { return .unparseable(reason: "PI_HOST_FAILED 的 JSON 无法解析") }
                if code == "DEFAULT_TRANSFER_ORDER_UNKNOWN" {
                    // 四键形态：ok/code/removed/defaultTransfer。缺字段即协议错误，不能降级成普通 failure。
                    guard let removed = root["removed"] as? [String: Any],
                          let removedProviderId = removed["providerId"] as? String,
                          let secretCleared = removed["secretCleared"] as? Bool
                    else { return .unparseable(reason: "DEFAULT_TRANSFER_ORDER_UNKNOWN 缺少 removed 详情") }
                    return .defaultTransferOrderUnknown(
                        removedProviderId: removedProviderId,
                        secretCleared: secretCleared
                    )
                }
                return .failure(ProviderRemoveFailureCode(raw: code))
            }
            if text.hasPrefix(successPrefix) {
                if let exitCode, exitCode != 0 {
                    return .unparseable(reason: "成功标记出现在非零退出码 \(exitCode) 的输出里")
                }
                let payload = text.dropFirst(successPrefix.count).trimmingCharacters(in: .whitespaces)
                guard let data = payload.data(using: .utf8) else {
                    return .unparseable(reason: "PI_HOST_REMOVED 不是 UTF-8")
                }
                do {
                    return .success(try ProviderRemoveParser.parseSummary(data))
                } catch {
                    return .unparseable(reason: "PI_HOST_REMOVED 的 JSON 无法解析：\(error)")
                }
            }
        }
        return .unparseable(reason: "输出里没有 PI_HOST_REMOVED / PI_HOST_FAILED 标记")
    }
}
