import Foundation

// MARK: - 端点预校验

/// 契约 §4.5 / spec AC-04.5：`provider-import` 会拒绝跑在服务器回环地址等处的代理端点。
/// 客户端必须在**提交前**用同一套规则本地预校验，并把**中文原因**直接展示给用户
/// （AC-04.5 要求「命中即拒绝并说明原因，不发起导入」）。
///
/// 本类型不返回布尔：每条拒绝都带可展示原因的 `EndpointRejection`。
public enum EndpointPolicy {
    /// `vendorKey` 属于被排除的本地推理服务（契约 §4.3 列出的取值）。
    public static let excludedVendorKeys: Set<String> = ["ollama", "lmstudio", "local"]

    /// 契约 §4.3：`vendorKey` ∈ {openai, anthropic, google} 时 `baseUrl` 可省略。
    public static let vendorsAllowingImplicitBaseURL: Set<String> = ["openai", "anthropic", "google"]

    /// 校验结果：要么通过，要么是带中文原因的拒绝。
    public struct Validation: Equatable, Sendable {
        public let rejection: EndpointRejection?

        public init(rejection: EndpointRejection?) {
            self.rejection = rejection
        }

        public var isValid: Bool { rejection == nil }
        /// 可直接展示在输入框下方的中文原因。
        public var displayReason: String? { rejection?.message }
    }

    /// 预校验入口。`baseUrl` 允许为 `nil`/空串（见 `vendorsAllowingImplicitBaseURL`）。
    public static func validate(baseUrl: String?, vendorKey: String) -> Validation {
        let key = vendorKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if excludedVendorKeys.contains(key) {
            return Validation(rejection: .excludedVendorKey(key))
        }

        let raw = (baseUrl ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty {
            if vendorsAllowingImplicitBaseURL.contains(key) {
                return Validation(rejection: nil)
            }
            return Validation(rejection: .missingBaseURL(vendorKey: key))
        }

        guard let components = URLComponents(string: raw) else {
            return Validation(rejection: .malformedURL(raw))
        }
        guard let scheme = components.scheme?.lowercased(), !scheme.isEmpty else {
            return Validation(rejection: .malformedURL(raw))
        }
        guard scheme == "http" || scheme == "https" else {
            return Validation(rejection: .unsupportedScheme(scheme))
        }
        if components.user != nil || components.password != nil {
            return Validation(rejection: .userInfoNotAllowed(raw))
        }
        if components.query != nil {
            return Validation(rejection: .queryNotAllowed(raw))
        }
        if components.fragment != nil {
            return Validation(rejection: .fragmentNotAllowed(raw))
        }
        guard var host = components.host?.lowercased(), !host.isEmpty else {
            return Validation(rejection: .malformedURL(raw))
        }

        host = normalize(host: host)
        if let rejection = hostRejection(host: host) {
            return Validation(rejection: rejection)
        }
        return Validation(rejection: nil)
    }

    /// 去掉 IPv6 方括号（`URLComponents.host` 会保留 `[` `]`）与 DNS 允许的结尾点。
    static func normalize(host: String) -> String {
        var value = host
        if value.hasPrefix("["), value.hasSuffix("]") {
            value = String(value.dropFirst().dropLast())
        }
        while value.hasSuffix(".") {
            value.removeLast()
        }
        return value
    }

    /// 主机名 / 字面量地址的拒绝判定（契约 §4.5 逐项）。
    ///
    /// 字面量地址必须先按规范形态解析再判定：`http://2130706433/v1`、`http://0x7f000001/v1`、
    /// `http://127.1/v1`、`http://0177.0.0.1/v1` 都是 `127.0.0.1` 的合法写法，
    /// `http://[0:0:0:0:0:0:0:1]/v1` 与 `http://[0:0:0:0:0:ffff:127.0.0.1]/v1` 是 `::1` /
    /// `::ffff:127.0.0.1` 的展开写法；按字面字符串匹配会被绕过。
    static func hostRejection(host: String) -> EndpointRejection? {
        if let groups = ipv6Groups(host) {
            return ipv6Rejection(groups: groups, host: host)
        }
        if host == "localhost" || host.hasSuffix(".localhost") {
            return .loopbackHost(host)
        }
        if host.hasSuffix(".local") {
            return .localHostname(host)
        }
        if let octets = ipv4Octets(host) {
            if octets[0] == 127 {
                return .loopbackHost(host)
            }
            if octets[0] == 0 {
                return .wildcardHost(host)
            }
            if octets[0] == 169 && octets[1] == 254 {
                return .linkLocalHost(host)
            }
        }
        return nil
    }

    /// IPv6 的拒绝判定在**展开成 8 组 16 位整数之后**做，见 `ipv6Groups`。
    static func ipv6Rejection(groups: [Int], host: String) -> EndpointRejection? {
        if groups.allSatisfy({ $0 == 0 }) {
            return .ipv6Unspecified(host)
        }
        if groups.prefix(7).allSatisfy({ $0 == 0 }), groups[7] == 1 {
            return .ipv6Loopback(host)
        }
        // `::ffff:a.b.c.d` / `::ffff:xxxx:yyyy`：任何 IPv4 映射都可能指向本机/链路本地，整体拒绝。
        if groups.prefix(5).allSatisfy({ $0 == 0 }), groups[5] == 0xFFFF {
            return .ipv4MappedIPv6(host)
        }
        return nil
    }

    /// 按 WHATWG 的 IPv4 规则解析：十进制整体值、`0x` 十六进制、以 `0` 开头的八进制、
    /// 省略段（`127.1`、`2130706433`）。
    ///
    /// 末段不是数字（`0.example.com` 的 `com`）或段数超过 4 时返回 `nil`，
    /// 避免把合法域名误判为字面量地址。
    static func ipv4Octets(_ host: String) -> [Int]? {
        var parts = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty else { return nil }
        if parts.count > 1, parts.last?.isEmpty == true {
            parts.removeLast()
        }
        guard (1...4).contains(parts.count), let lastPart = parts.last, isNumericIPv4Part(lastPart) else {
            return nil
        }

        var numbers: [Int] = []
        numbers.reserveCapacity(parts.count)
        for part in parts {
            guard let value = parseIPv4Part(part) else { return nil }
            numbers.append(value)
        }

        var octets = [0, 0, 0, 0]
        for index in 0..<(numbers.count - 1) {
            guard numbers[index] <= 255 else { return nil }
            octets[index] = numbers[index]
        }
        // 最后一段占用剩下所有字节：`127.1` → 127 / 0 / 0 / 1，`2130706433` → 127.0.0.1。
        let last = numbers[numbers.count - 1]
        let remainingBytes = 5 - numbers.count
        guard last >= 0, last < (1 << (8 * remainingBytes)) else { return nil }
        for offset in 0..<remainingBytes {
            octets[3 - offset] = (last >> (8 * offset)) & 0xFF
        }
        return octets
    }

    /// 末段是否是「数字」：十进制数字，或 `0x` 前缀的十六进制（WHATWG 的 ends-in-a-number 判定）。
    static func isNumericIPv4Part(_ part: String) -> Bool {
        guard !part.isEmpty else { return false }
        let lower = part.lowercased()
        if lower.hasPrefix("0x") {
            return lower.count > 2 && lower.dropFirst(2).allSatisfy(\.isHexDigit)
        }
        return part.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// 单段数值：`0x…` 十六进制、以 `0` 开头的八进制、其余十进制。
    static func parseIPv4Part(_ part: String) -> Int? {
        guard !part.isEmpty else { return nil }
        let lower = part.lowercased()
        if lower.hasPrefix("0x") {
            guard lower.count > 2 else { return nil }
            return Int(lower.dropFirst(2), radix: 16)
        }
        if part.count > 1, part.hasPrefix("0") {
            return Int(part.dropFirst(), radix: 8)
        }
        guard part.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(part)
    }

    /// 把 IPv6 字面量（方括号已由 `normalize` 去掉）展开成 8 组 16 位整数；
    /// 不是 IPv6 字面量时返回 `nil`（域名走域名分支）。
    static func ipv6Groups(_ host: String) -> [Int]? {
        guard host.contains(":") else { return nil }
        let halves = host.components(separatedBy: "::")
        guard halves.count <= 2 else { return nil }

        if halves.count == 1 {
            guard let groups = parseIPv6Segment(halves[0], allowsIPv4Tail: true), groups.count == 8 else {
                return nil
            }
            return groups
        }

        guard let head = parseIPv6Segment(halves[0], allowsIPv4Tail: false),
              let tail = parseIPv6Segment(halves[1], allowsIPv4Tail: true),
              head.count + tail.count <= 7
        else { return nil }
        return head + Array(repeating: 0, count: 8 - head.count - tail.count) + tail
    }

    /// 解析 `:` 分隔的若干组（末组可以是嵌入的 IPv4 点分十进制）。
    static func parseIPv6Segment(_ segment: String, allowsIPv4Tail: Bool) -> [Int]? {
        if segment.isEmpty { return [] }
        let parts = segment.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        var groups: [Int] = []
        groups.reserveCapacity(parts.count)
        for (index, part) in parts.enumerated() {
            if allowsIPv4Tail, index == parts.count - 1, part.contains(".") {
                guard let octets = dottedIPv4Octets(part) else { return nil }
                groups.append(octets[0] << 8 | octets[1])
                groups.append(octets[2] << 8 | octets[3])
            } else {
                guard (1...4).contains(part.count), let value = Int(part, radix: 16) else { return nil }
                groups.append(value)
            }
        }
        return groups
    }

    /// 严格点分十进制（IPv6 里嵌入的 IPv4 不接受 `0x` / 八进制写法）。
    static func dottedIPv4Octets(_ text: String) -> [Int]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [Int] = []
        octets.reserveCapacity(4)
        for part in parts {
            guard !part.isEmpty, part.count <= 3, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(part), value >= 0, value <= 255
            else { return nil }
            octets.append(value)
        }
        return octets
    }
}

// MARK: - 拒绝原因

/// 契约 §4.5 的每条拒绝分支；`message` 是给用户看的中文原因。
public enum EndpointRejection: Equatable, Sendable {
    case excludedVendorKey(String)
    case missingBaseURL(vendorKey: String)
    case malformedURL(String)
    case unsupportedScheme(String)
    case userInfoNotAllowed(String)
    case queryNotAllowed(String)
    case fragmentNotAllowed(String)
    case loopbackHost(String)
    case localHostname(String)
    case wildcardHost(String)
    case linkLocalHost(String)
    case ipv6Unspecified(String)
    case ipv6Loopback(String)
    case ipv4MappedIPv6(String)

    /// 稳定的机器可读标识（埋点/测试用，不随文案变化）。
    public var code: String {
        switch self {
        case .excludedVendorKey: return "excluded-vendor-key"
        case .missingBaseURL: return "missing-base-url"
        case .malformedURL: return "malformed-url"
        case .unsupportedScheme: return "unsupported-scheme"
        case .userInfoNotAllowed: return "userinfo-not-allowed"
        case .queryNotAllowed: return "query-not-allowed"
        case .fragmentNotAllowed: return "fragment-not-allowed"
        case .loopbackHost: return "loopback-host"
        case .localHostname: return "local-hostname"
        case .wildcardHost: return "wildcard-host"
        case .linkLocalHost: return "link-local-host"
        case .ipv6Unspecified: return "ipv6-unspecified"
        case .ipv6Loopback: return "ipv6-loopback"
        case .ipv4MappedIPv6: return "ipv4-mapped-ipv6"
        }
    }

    /// 中文原因。措辞按契约 §4.5 与 spec §4.1.1 的说明写：这类端点由 Host 侧的
    /// `provider-import` 拒绝，客户端在提交前就拦下，并解释为什么不能用。
    public var message: String {
        switch self {
        case let .excludedVendorKey(key):
            return "「\(key)」属于本地推理服务，Host 侧不接受这类 provider（P0 不支持本地模型）"
        case let .missingBaseURL(vendorKey):
            return "provider「\(vendorKey)」必须填写 Base URL"
        case let .malformedURL(raw):
            return "Base URL 不是合法地址：\(raw)（需要形如 https://host/v1，必须带 http(s):// 前缀）"
        case let .unsupportedScheme(scheme):
            return "Base URL 只支持 http 或 https，当前是「\(scheme)」"
        case .userInfoNotAllowed:
            return "Base URL 不能包含用户名或密码（userinfo），密钥请填在 API Key 字段"
        case .queryNotAllowed:
            return "Base URL 不能带查询参数（?…）"
        case .fragmentNotAllowed:
            return "Base URL 不能带片段标识（#…）"
        case let .loopbackHost(host):
            return "Base URL 指向回环地址「\(host)」：该地址在服务器上指向服务器自己，Host 会拒绝导入。请改成服务器能访问的域名或公网/内网地址"
        case let .localHostname(host):
            return "Base URL 使用「\(host)」这类 .local 局域网名，Host 会拒绝，请改成可解析的域名或 IP"
        case let .wildcardHost(host):
            return "Base URL 使用通配地址「\(host)」，无法作为上游端点，Host 会拒绝导入"
        case let .linkLocalHost(host):
            return "Base URL 指向链路本地地址「\(host)」，Host 会拒绝导入；请改成公网或内网可达地址"
        case .ipv6Unspecified:
            return "Base URL 使用未指定 IPv6 地址「[::]」，Host 会拒绝导入"
        case let .ipv6Loopback(host):
            return "Base URL 指向 IPv6 回环地址「[\(host)]」，在服务器上指向它自己，Host 会拒绝导入"
        case let .ipv4MappedIPv6(host):
            return "Base URL 使用 IPv4 映射的 IPv6 地址「[\(host)]」，Host 会拒绝导入"
        }
    }
}
