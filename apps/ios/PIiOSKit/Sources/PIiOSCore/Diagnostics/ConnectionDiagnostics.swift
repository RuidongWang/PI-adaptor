import Foundation

// MARK: - systemd unit 状态

/// The three `systemctl --user show` properties used by the Host status page.
public struct HostUnitSnapshot: Equatable, Sendable {
    public let loadState: String
    public let activeState: String
    public let unitFileState: String

    public init(loadState: String, activeState: String, unitFileState: String) {
        self.loadState = loadState
        self.activeState = activeState
        self.unitFileState = unitFileState
    }

    public var isActive: Bool { activeState == "active" }
}

public enum HostUnitParseError: Error, Equatable, LocalizedError {
    case missingField(String)

    public var errorDescription: String? {
        switch self {
        case .missingField(let field):
            return "Host unit 状态缺少必需字段：\(field)"
        }
    }
}

/// Parses `Key=Value` output without depending on line order or surrounding SSH noise.
public enum HostUnitSnapshotParser {
    public static let requiredFields = [
        "LoadState",
        "ActiveState",
        "UnitFileState",
    ]

    public static func parse(_ output: String) throws -> HostUnitSnapshot {
        var values: [String: String] = [:]

        for rawLine in output.split(whereSeparator: { $0.isNewline }) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty,
                  let separator = line.firstIndex(of: "=")
            else {
                continue
            }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            guard requiredFields.contains(key) else { continue }
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                values[key] = value
            }
        }

        for field in requiredFields where values[field] == nil {
            throw HostUnitParseError.missingField(field)
        }
        return HostUnitSnapshot(
            loadState: values["LoadState"]!,
            activeState: values["ActiveState"]!,
            unitFileState: values["UnitFileState"]!
        )
    }
}

// MARK: - 连接失败分类

/// A stable, user-facing category for SSH, RACP, WebSocket, and HTTP failures.
///
/// Raw transport details are used only to choose a category. They are never embedded
/// in the returned message, so server responses cannot reflect credentials into the UI.
public enum ConnectionFailureKind: String, Equatable, Sendable {
    case dns
    case tls
    case authentication
    case rateLimit
    case insufficientBalance
    case timeout
    case offline
    case hostKey
    case remoteUnavailable
    case protocolViolation
    case unknown

    public var userMessage: String {
        switch self {
        case .dns:
            return "无法解析服务器地址（DNS）：请检查地址拼写、手机网络或 VPN。"
        case .tls:
            return "TLS 安全连接失败：请检查证书、系统时间、代理或网络中间设备。"
        case .authentication:
            return "认证失败（401）：请检查用户名、密码、私钥、口令或设备令牌。"
        case .rateLimit:
            return "请求被限流（429）：请等待后重试，避免连续重连。"
        case .insufficientBalance:
            return "账户余额或调用额度不足（402）：请在模型服务侧补充额度后重试。"
        case .timeout:
            return "连接超时：请检查网络、服务器防火墙和 Host 状态后重试。"
        case .offline:
            return "当前处于离线状态：恢复手机网络或 VPN 后再试。"
        case .hostKey:
            return "主机密钥校验失败：服务器指纹与已固定记录不一致，可能存在中间人风险；本机不会自动忽略指纹变化。若确为你自己重装服务器导致，请先在服务器设置里移除旧指纹，再重新核对新指纹。"
        case .remoteUnavailable:
            return "服务器或 PI-adaptor 暂不可用：请检查 PI-adaptor 服务、端口与防火墙。"
        case .protocolViolation:
            return "连接协议异常或版本不兼容：请核对客户端与 Host 版本。"
        case .unknown:
            return "连接失败：请检查服务器地址、网络与 Host 状态后重试。"
        }
    }

    public var isRetryable: Bool {
        switch self {
        case .rateLimit, .timeout, .offline, .remoteUnavailable:
            return true
        case .dns, .tls, .authentication, .insufficientBalance, .hostKey, .protocolViolation, .unknown:
            return false
        }
    }
}

public enum ConnectionFailureClassifier {
    /// Unknown codes may contain arbitrary server text, so never display their raw value.
    public static func userMessage(forRACPCode code: RACPErrorCode) -> String {
        switch code {
        case .unauthorized, .forbidden:
            return ConnectionFailureKind.authentication.userMessage
        case .agentUnavailable, .serverInternal:
            return ConnectionFailureKind.remoteUnavailable.userMessage
        case .rateLimited:
            return ConnectionFailureKind.rateLimit.userMessage
        case .protocolMismatch:
            return ConnectionFailureKind.protocolViolation.userMessage
        case .unknown:
            return ConnectionFailureKind.unknown.userMessage
        case .invalidArgument: return "参数不合法"
        case .notFound: return "对象不存在，列表已刷新"
        case .methodNotFound: return "这台服务器不支持该操作"
        case .agentBusy: return "Host 正忙"
        case .conflict: return "状态已变化，重新拉取后再试"
        case .idempotencyConflict: return "同一幂等键对应了不同内容，需要人工确认"
        case .cursorExpired: return "事件游标已过期，已按快照重建"
        case .clientTooSlow: return "客户端处理过慢，已丢弃订阅并按快照重建"
        case .approvalExpired: return "审批已过期"
        case .approvalStale: return "审批已失效"
        case .payloadTooLarge: return "内容超过上限，请压缩后重试"
        case .pairingFailed: return "配对失败"
        case .pairingTokenExpired: return "配对令牌已过期，需要重启 Host 取新令牌"
        case .capabilityUnavailable: return "服务器未提供该能力"
        }
    }

    /// Classifies one failure. `isOffline` wins because no remote diagnosis is
    /// trustworthy while the local device has no usable network.
    public static func classify(
        code: String? = nil,
        httpStatus: Int? = nil,
        isOffline: Bool = false,
        message: String? = nil
    ) -> ConnectionFailureKind {
        if isOffline { return .offline }

        if let httpStatus {
            switch httpStatus {
            case 401, 403:
                return .authentication
            case 402:
                return .insufficientBalance
            case 408, 504:
                return .timeout
            case 429:
                return .rateLimit
            case 500...599:
                return .remoteUnavailable
            default:
                break
            }
        }

        let normalizedCode = (code ?? "")
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
        if !normalizedCode.isEmpty {
            if normalizedCode.contains("dns") || normalizedCode.contains("nameresolution") {
                return .dns
            }
            if normalizedCode.contains("tls") || normalizedCode.contains("ssl") {
                return .tls
            }
            if normalizedCode.contains("ratelimit")
                || normalizedCode.contains("toomanyrequests")
                || normalizedCode.contains("throttled")
            {
                return .rateLimit
            }
            if normalizedCode.contains("insufficientbalance")
                || normalizedCode.contains("insufficientquota")
                || normalizedCode.contains("quotaexceeded")
            {
                return .insufficientBalance
            }
            if normalizedCode.contains("timeout") || normalizedCode.contains("timedout") {
                return .timeout
            }
            if normalizedCode.contains("authentication")
                || normalizedCode.contains("unauthorized")
                || normalizedCode.contains("forbidden")
                || normalizedCode.contains("invalidprivatekey")
            {
                return .authentication
            }
            if normalizedCode.contains("offline")
                || normalizedCode.contains("notconnected")
                || normalizedCode.contains("channelclosed")
                || normalizedCode.contains("closedbypeer")
                || normalizedCode.contains("websocketclosed")
            {
                return .offline
            }
            if normalizedCode.contains("hostkey") {
                return .hostKey
            }
            if normalizedCode.contains("tunnelrefused")
                || normalizedCode.contains("agentunavailable")
                || normalizedCode.contains("serverinternal")
            {
                return .remoteUnavailable
            }
            if normalizedCode.contains("protocol")
                || normalizedCode.contains("malformedframe")
                || normalizedCode.contains("protocolviolation")
            {
                return .protocolViolation
            }
        }

        if let message {
            let text = message.lowercased()
            if let range = text.range(
                of: #"\bhttp(?:/\d(?:\.\d)?)?\s+(?:status\s+)?[45]\d{2}\b"#,
                options: .regularExpression
            ), let status = Int(text[range].suffix(3)) {
                let kind = classify(httpStatus: status)
                if kind != .unknown { return kind }
            }
            if contains(text, anyOf: [
                "dns", "could not resolve host", "name or service not known",
                "nodename nor servname", "temporary failure in name resolution",
                "no such host", "could not find host", "hostname could not be found",
                "getaddrinfo", "域名解析", "名称解析",
            ]) {
                return .dns
            }
            if contains(text, anyOf: [
                "tls", "ssl", "certificate", "cert verify", "x509",
                "unknown ca", "self-signed", "证书", "安全握手",
            ]) {
                return .tls
            }
            if contains(text, anyOf: ["429", "too many requests", "rate limit", "throttled"]) {
                return .rateLimit
            }
            if contains(text, anyOf: ["402", "insufficient balance", "insufficient quota", "余额不足", "额度不足"]) {
                return .insufficientBalance
            }
            if contains(text, anyOf: ["timeout", "timed out", "etimedout", "超时"]) {
                return .timeout
            }
            if contains(text, anyOf: ["401", "403", "unauthorized", "forbidden", "authentication failed", "认证失败"]) {
                return .authentication
            }
            if contains(text, anyOf: [
                "offline", "not connected to the internet", "network connection was lost",
                "internet connection appears to be offline", "当前离线",
            ]) {
                return .offline
            }
            if contains(text, anyOf: [
                "host key", "hostkey", "主机密钥", "指纹",
            ]) {
                return .hostKey
            }
            if contains(text, anyOf: [
                "protocol", "malformed frame", "无法解析的帧", "版本不兼容", "协议异常",
            ]) {
                return .protocolViolation
            }
            if contains(text, anyOf: [
                "connection refused", "econnrefused", "connection reset",
                "econnreset", "network is unreachable", "host is unreachable",
                "no route to host", "tunnel refused",
            ]) {
                return .remoteUnavailable
            }
        }

        return .unknown
    }

    private static func contains(_ text: String, anyOf markers: [String]) -> Bool {
        markers.contains { text.contains($0) }
    }
}

/// Removes common secret shapes before diagnostic text reaches logs or the UI.
public enum ConnectionDiagnosticRedactor {
    private struct Rule {
        let pattern: String
        let options: NSRegularExpression.Options
        let replacement: String
    }

    private static let rules: [Rule] = [
        Rule(
            pattern: #"(?is)-----BEGIN [^-\r\n]*PRIVATE KEY-----.*?-----END [^-\r\n]*PRIVATE KEY-----"#,
            options: [],
            replacement: "[已隐藏私钥]"
        ),
        Rule(
            pattern: #"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{6,}"#,
            options: [],
            replacement: "Bearer [已隐藏]"
        ),
        Rule(
            pattern: #"(?i)\b(api[_-]?key|device[_-]?token|token|password|passphrase|secret|authorization)\s*[:=]\s*[^\s,;]+"#,
            options: [],
            replacement: "$1=[已隐藏]"
        ),
        Rule(
            pattern: #"\bppt[12]\.[A-Za-z0-9._~-]+"#,
            options: [],
            replacement: "[已隐藏配对令牌]"
        ),
        Rule(
            pattern: #"\bpdt[12]\.[A-Za-z0-9._~-]+"#,
            options: [],
            replacement: "[已隐藏设备令牌]"
        ),
        Rule(
            pattern: #"\bsk-[A-Za-z0-9_-]{8,}"#,
            options: [],
            replacement: "[已隐藏 API Key]"
        ),
    ]

    public static func redact(_ text: String) -> String {
        rules.reduce(text) { current, rule in
            guard let expression = try? NSRegularExpression(
                pattern: rule.pattern,
                options: rule.options
            ) else {
                return current
            }
            let range = NSRange(current.startIndex..<current.endIndex, in: current)
            return expression.stringByReplacingMatches(
                in: current,
                options: [],
                range: range,
                withTemplate: rule.replacement
            )
        }
    }
}
