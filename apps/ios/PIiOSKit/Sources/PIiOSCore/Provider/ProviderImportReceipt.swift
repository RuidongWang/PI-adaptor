import Foundation

// MARK: - 回执结构（契约 §4.6）

/// 成功回执里的一行导入结果。
public struct ProviderImportImported: Codable, Equatable, Sendable {
    public var sourceId: String
    public var providerId: String

    public init(sourceId: String, providerId: String) {
        self.sourceId = sourceId
        self.providerId = providerId
    }
}

/// `skipped[].reason`。契约 §4.6 冻结了三种取值，各自对应一句客户端文案；
/// 未列出的取值原样保留，不静默归类。
public enum ProviderImportSkipReason: Equatable, Sendable {
    case importIncomplete
    case remoteChanged
    case remoteMissing
    case unknown(String)

    public init(raw: String) {
        switch raw {
        case "import_incomplete": self = .importIncomplete
        case "remote_changed": self = .remoteChanged
        case "remote_missing": self = .remoteMissing
        default: self = .unknown(raw)
        }
    }

    public var rawValue: String {
        switch self {
        case .importIncomplete: return "import_incomplete"
        case .remoteChanged: return "remote_changed"
        case .remoteMissing: return "remote_missing"
        case let .unknown(raw): return raw
        }
    }

    /// 契约 §4.6 表格「客户端行为」列的中文含义，可直接展示（AC-04.6 要求分别解释且不自动重试）。
    public var clientGuidance: String {
        switch self {
        case .importIncomplete:
            return "上次创建的提交结果不确定：先检查 Host 侧状态，再决定重装或等 P1 支持删除，不要重试"
        case .remoteChanged:
            return "服务器侧记录已变更，本次不会覆盖；如需新配置请另建一条"
        case .remoteMissing:
            return "服务器侧记录已删除，可以重新导入（会新建一条）"
        case let .unknown(raw):
            return "未识别的跳过原因：\(raw)"
        }
    }

    /// 契约 §4.6：三种 skipped 都不得自动重试。
    public var allowsAutomaticRetry: Bool { false }

    /// 只有 `remote_missing` 允许用户手动重新导入。
    public var canReimport: Bool {
        if case .remoteMissing = self { return true }
        return false
    }
}

extension ProviderImportSkipReason: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(raw: try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// 成功回执里的 `skipped[]` 元素。
public struct ProviderImportSkipped: Codable, Equatable, Sendable {
    public var sourceId: String
    public var reason: ProviderImportSkipReason

    public init(sourceId: String, reason: ProviderImportSkipReason) {
        self.sourceId = sourceId
        self.reason = reason
    }
}

/// `PI_HOST_PROVIDERS {...}` 的主体。
///
/// 容错解码：`imported` / `skipped` / `defaultSet` 缺失时给默认值（空数组 / `false`）——
/// 三者缺一不该把一条成功回执判成 `unparseable`（契约 §4.6 只规定成功标记与主体形状）。
public struct ProviderImportSuccess: Codable, Equatable, Sendable {
    public var imported: [ProviderImportImported]
    public var skipped: [ProviderImportSkipped]
    public var defaultSet: Bool

    public init(
        imported: [ProviderImportImported] = [],
        skipped: [ProviderImportSkipped] = [],
        defaultSet: Bool = false
    ) {
        self.imported = imported
        self.skipped = skipped
        self.defaultSet = defaultSet
    }

    enum CodingKeys: String, CodingKey {
        case imported
        case skipped
        case defaultSet
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // 三个字段都可选（上游省略空数组时不至于把成功判成解析失败），
        // 但主体里一个已知字段都没有时必须按「回执不合契约」处理，
        // 否则 `PI_HOST_PROVIDERS {}` 会被当成零条目的成功。
        guard !container.allKeys.isEmpty else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "回执主体不含任何已知字段（imported / skipped / defaultSet）"
            ))
        }
        imported = try container.decodeIfPresent([ProviderImportImported].self, forKey: .imported) ?? []
        skipped = try container.decodeIfPresent([ProviderImportSkipped].self, forKey: .skipped) ?? []
        defaultSet = try container.decodeIfPresent(Bool.self, forKey: .defaultSet) ?? false
    }

    /// 某个 `sourceId` 的导入结果：成功时给出 `providerId`，否则给出跳过原因。
    public func outcome(forSourceId sourceId: String) -> ProviderImportSourceOutcome {
        if let imported = imported.first(where: { $0.sourceId == sourceId }) {
            return .imported(providerId: imported.providerId)
        }
        if let skipped = skipped.first(where: { $0.sourceId == sourceId }) {
            return .skipped(reason: skipped.reason)
        }
        return .missing
    }
}

/// 单个 `sourceId` 的结果。
public enum ProviderImportSourceOutcome: Equatable, Sendable {
    case imported(providerId: String)
    case skipped(reason: ProviderImportSkipReason)
    /// 回执里既没出现在 imported 也没出现在 skipped（不臆测成功）。
    case missing
}

/// `PI_HOST_FAILED {"code":"..."}` 的失败码。契约 §4.6 枚举 6 个，未列出的原样保留。
public enum ProviderImportFailureCode: Equatable, Sendable {
    case invalidRequest
    case payloadTooLarge
    case adminUnavailable
    case adminBusy
    case timeout
    case importFailed
    case unknown(String)

    public static let known: [ProviderImportFailureCode] = [
        .invalidRequest, .payloadTooLarge, .adminUnavailable, .adminBusy, .timeout, .importFailed,
    ]

    public init(raw: String) {
        switch raw {
        case "INVALID_REQUEST": self = .invalidRequest
        case "PAYLOAD_TOO_LARGE": self = .payloadTooLarge
        case "ADMIN_UNAVAILABLE": self = .adminUnavailable
        case "ADMIN_BUSY": self = .adminBusy
        case "TIMEOUT": self = .timeout
        case "IMPORT_FAILED": self = .importFailed
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
        case let .unknown(raw): return raw
        }
    }

    /// 中文说明（说明发生了什么、下一步做什么），不臆造上游未定义的行为。
    public var displayMessage: String {
        switch self {
        case .invalidRequest:
            return "Host 认为载荷不合法（字段不符合 provider-import 契约），请检查模型 ID、思考档位与 Base URL"
        case .payloadTooLarge:
            return "载荷超过 1 MiB 上限，请减少 provider 或模型数量"
        case .adminUnavailable:
            return "Host 未运行或 admin.sock 不可用，请先启动 pi-host 再重试"
        case .adminBusy:
            return "Host 正忙，稍后重试"
        case .timeout:
            return "整次导入超过 30 秒截止时间"
        case .importFailed:
            return "Host 侧导入失败，请查看 Host 日志"
        case let .unknown(raw):
            return "未识别的失败码：\(raw)"
        }
    }
}

/// `PI_HOST_FAILED` 的失败体。
public struct ProviderImportFailure: Equatable, Sendable {
    public let code: ProviderImportFailureCode

    public init(code: ProviderImportFailureCode) {
        self.code = code
    }

    public init(rawCode: String) {
        self.code = ProviderImportFailureCode(raw: rawCode)
    }

    public var rawCode: String { code.rawValue }
    public var displayMessage: String { code.displayMessage }
}

/// 回执解析结果。
public enum ProviderImportReceipt: Equatable, Sendable {
    case success(ProviderImportSuccess)
    case failure(ProviderImportFailure)
    /// 两种单行 stdout 标记都没找到（或 JSON 解不开）：原样上报原因，不当作成功。
    case unparseable(reason: String)

    /// 契约 §4.6：整次导入 30 秒截止。
    public static let timeLimitSeconds = 30
    public static let successMarkers = ["PI_HOST_PROVIDERS"]
    public static let failureMarker = "PI_HOST_FAILED"
}

/// `provider-import` 的单行 stdout 解析器（契约 §4.6）。
public enum ProviderImportReceiptParser {
    public static let successPrefix = "PI_HOST_PROVIDERS"
    public static let failurePrefix = "PI_HOST_FAILED"

    /// - Parameters:
    ///   - stdout: `provider-import` 的完整 stdout（可能含无关的告警行）。
    ///   - exitCode: 进程退出码。非 0 时不得判成功：Host 可能只打印了成功标记就异常退出，
    ///     因此成功标记会降级为 `unparseable` 并说明退出码，交由调用方按失败处理。
    public static func parse(stdout: String, exitCode: Int32? = nil) -> ProviderImportReceipt {
        let lines = stdout.split(whereSeparator: { $0 == "\n" || $0 == "\r" })

        for line in lines {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix(failurePrefix) {
                let payload = text.dropFirst(failurePrefix.count).trimmingCharacters(in: .whitespaces)
                return parseFailure(payload)
            }
            if text.hasPrefix(successPrefix) {
                if let exitCode, exitCode != 0 {
                    // 非零退出码 + 只有成功行：不能当成功（AC-04.6）。
                    return .unparseable(
                        reason: "\(successPrefix) 成功标记出现在非零退出码（\(exitCode)）的输出里，按失败处理，不当成功"
                    )
                }
                let payload = text.dropFirst(successPrefix.count).trimmingCharacters(in: .whitespaces)
                return parseSuccess(payload)
            }
        }

        let codeSuffix = exitCode.map { "，退出码 \($0)" } ?? ""
        return .unparseable(
            reason: "输出里没有 \(successPrefix) / \(failurePrefix) 标记\(codeSuffix)"
        )
    }

    static func parseSuccess(_ payload: String) -> ProviderImportReceipt {
        guard let data = payload.data(using: .utf8), !payload.isEmpty else {
            return .unparseable(reason: "\(successPrefix) 后面没有 JSON 主体")
        }
        do {
            let body = try JSONDecoder().decode(ProviderImportSuccess.self, from: data)
            return .success(body)
        } catch {
            return .unparseable(reason: "\(successPrefix) 的 JSON 无法解析：\(error)")
        }
    }

    static func parseFailure(_ payload: String) -> ProviderImportReceipt {
        guard let data = payload.data(using: .utf8), !payload.isEmpty else {
            return .unparseable(reason: "\(failurePrefix) 后面没有 JSON 主体")
        }
        do {
            let body = try JSONDecoder().decode(FailureBody.self, from: data)
            return .failure(ProviderImportFailure(rawCode: body.code))
        } catch {
            return .unparseable(reason: "\(failurePrefix) 的 JSON 无法解析：\(error)")
        }
    }

    private struct FailureBody: Decodable {
        let code: String
    }
}
