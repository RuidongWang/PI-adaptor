import CryptoKit
import Foundation

// MARK: - ECMAScript 文本规范化

/// JavaScript `String.prototype.trim()` 的等价实现。
///
/// Host 使用 JS `trim()` 校验文本字段；Foundation 的
/// `whitespacesAndNewlines` 不含 U+FEFF，却会去掉 JS 不处理的 U+200B/U+0085。
/// 两端必须使用同一字符集合，否则会出现客户端预检通过、Host 返回
/// `INVALID_REQUEST` 的不可见差异。
public enum ECMAScriptString {
    public static func trim(_ value: String) -> String {
        let scalars = value.unicodeScalars
        var lower = scalars.startIndex
        let upper = scalars.endIndex
        while lower < upper, isWhitespace(scalars[lower]) {
            lower = scalars.index(after: lower)
        }
        guard lower < upper else { return "" }

        var last = scalars.index(before: upper)
        while last > lower, isWhitespace(scalars[last]) {
            last = scalars.index(before: last)
        }
        return String(scalars[lower...last])
    }

    public static func isTrimmed(_ value: String) -> Bool {
        trim(value) == value
    }

    /// ECMAScript WhiteSpace 与 LineTerminator 的并集。
    static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0009...0x000D, 0x0020, 0x00A0, 0x1680,
             0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
            return true
        default:
            return false
        }
    }
}

// MARK: - 上游字段取值表

/// 契约 §4.3 / §4.4 冻结的取值集合。客户端只使用这里列出的取值，其余一律判为非法。
public enum ProviderVendorSchema {
    public static let types: [String] = ["native", "openai_compatible", "custom"]
    public static let protocols: [String] = ["openai", "anthropic", "google", "openai_compatible", "custom_http"]
    /// P0 只开放三种（spec D-07）；`none` / `azure_api_key` 不在 P0 范围，
    /// 因此 `secretValue` 恒为必填（AC-04.2）。
    public static let p0AuthKinds: [String] = ["api_key", "api_key_and_base_url", "bearer"]
    public static let apiStyles: [String] = [
        "auto", "chat_completions", "responses", "anthropic_messages",
        "google_generative_ai", "opencode_go", "pi_messages",
    ]
    /// 档位集合与 RACP 的思考档位一致（契约 §4.3）。
    public static let thinkingLevels: [String] = RACPThinkingLevel.allCases.map(\.rawValue)
    /// `defaultThinkingLevel` 额外的合法取值（契约 §4.4）。
    public static let defaultThinkingLevelOmit = "omit"
    /// 上游 `provider-sync.ts` 的 `RESERVED_HEADERS`；比较时忽略大小写。
    public static let reservedHeaderNames: Set<String> = [
        "authorization", "proxy-authorization", "x-api-key", "api-key", "x-goog-api-key",
        "cookie", "set-cookie", "host", "content-type", "content-length", "connection",
        "transfer-encoding", "te", "trailer", "upgrade", "keep-alive", "chatgpt-account-id",
        "x-opencode-session",
    ]
    public static let maxProviders = 32
    public static let maxModels = 512
    public static let minModels = 1
    public static let maxSecretBytes = 16_384
    /// 契约 §4.1：整份 stdin 载荷上限 1 MiB（超限即 `PAYLOAD_TOO_LARGE`）。
    public static let maxPayloadBytes = 1_048_576
    public static let maxBaseURLLength = 4_096
    /// 上游 `text()` 的默认上限（契约字段 name / vendorKey / protocol / authKind /
    /// sourceId / model.id）。
    public static let maxTextLength = 256
    /// 上游 `validateModel()` 对 alias 的独立上限。
    public static let maxAliasLength = 60
    /// 上游 `validateModel()` 只接受这两个 `thinkingProtocol` 取值。
    public static let thinkingProtocols: [String] = ["legacy", "adaptive"]
    public static let maxHeaders = 32
    /// 上游按 UTF-8 字节数限制单个请求头的值。
    public static let maxHeaderValueBytes = 4_096
    /// 上游 `ModelLimitSource` 仅允许 `catalog` / `user`；显式 `null` 也非法。
    public static let modelLimitSources: [String] = ["catalog", "user"]
    /// `contextWindow` / `maxTokens` 的上界：JavaScript 安全整数。
    public static let maxSafeInteger = 9_007_199_254_740_991
}

// MARK: - 载荷结构（契约 §4.2 / §4.3 / §4.4）

/// `ProviderCreateInput` 的 `models[]` 元素。字段与契约 §4.4 一一对应，顺序即声明顺序
/// （§4.2：数组两侧都不排序，顺序变化会导致上游复用哈希漂移）。
public struct ProviderModelSpec: Codable, Equatable, Sendable {
    public var id: String
    public var contextWindow: Int
    public var maxTokens: Int
    public var thinkingLevels: [String]
    /// `defaultThinkingLevel` 必须是本模型自己的档位之一，或 `omit`（契约 §4.4）。
    public var defaultThinkingLevel: String?
    public var alias: String?
    public var contextWindowSource: String?
    public var maxTokensSource: String?
    public var thinkingProtocol: String?
    public var supportsReasoningEffort: Bool?
    public var supportsImages: Bool?
    public var supportsDocuments: Bool?
    public var availableForSubagents: Bool?
    public var nativeWebSearch: Bool?

    public init(
        id: String,
        contextWindow: Int,
        maxTokens: Int,
        thinkingLevels: [String],
        defaultThinkingLevel: String? = nil,
        alias: String? = nil,
        contextWindowSource: String? = nil,
        maxTokensSource: String? = nil,
        thinkingProtocol: String? = nil,
        supportsReasoningEffort: Bool? = nil,
        supportsImages: Bool? = nil,
        supportsDocuments: Bool? = nil,
        availableForSubagents: Bool? = nil,
        nativeWebSearch: Bool? = nil
    ) {
        self.id = id
        self.contextWindow = contextWindow
        self.maxTokens = maxTokens
        self.thinkingLevels = thinkingLevels
        self.defaultThinkingLevel = defaultThinkingLevel
        self.alias = alias
        self.contextWindowSource = contextWindowSource
        self.maxTokensSource = maxTokensSource
        self.thinkingProtocol = thinkingProtocol
        self.supportsReasoningEffort = supportsReasoningEffort
        self.supportsImages = supportsImages
        self.supportsDocuments = supportsDocuments
        self.availableForSubagents = availableForSubagents
        self.nativeWebSearch = nativeWebSearch
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case contextWindow
        case maxTokens
        case thinkingLevels
        case defaultThinkingLevel
        case alias
        case contextWindowSource
        case maxTokensSource
        case thinkingProtocol
        case supportsReasoningEffort
        case supportsImages
        case supportsDocuments
        case availableForSubagents
        case nativeWebSearch
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        contextWindow = try container.decode(Int.self, forKey: .contextWindow)
        maxTokens = try container.decode(Int.self, forKey: .maxTokens)
        thinkingLevels = try container.decode([String].self, forKey: .thinkingLevels)
        defaultThinkingLevel = try container.decodeIfPresent(String.self, forKey: .defaultThinkingLevel)
        alias = try container.decodeIfPresent(String.self, forKey: .alias)
        // Upstream treats an explicit null as invalid, while `decodeIfPresent` would
        // silently turn it into "field absent".
        contextWindowSource = try Self.decodeSource(container, forKey: .contextWindowSource)
        maxTokensSource = try Self.decodeSource(container, forKey: .maxTokensSource)
        thinkingProtocol = try container.decodeIfPresent(String.self, forKey: .thinkingProtocol)
        supportsReasoningEffort = try container.decodeIfPresent(Bool.self, forKey: .supportsReasoningEffort)
        supportsImages = try container.decodeIfPresent(Bool.self, forKey: .supportsImages)
        supportsDocuments = try container.decodeIfPresent(Bool.self, forKey: .supportsDocuments)
        availableForSubagents = try container.decodeIfPresent(Bool.self, forKey: .availableForSubagents)
        nativeWebSearch = try container.decodeIfPresent(Bool.self, forKey: .nativeWebSearch)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(contextWindow, forKey: .contextWindow)
        try container.encode(maxTokens, forKey: .maxTokens)
        try container.encode(thinkingLevels, forKey: .thinkingLevels)
        // The host requires this key to exist and accepts JSON null.
        if let defaultThinkingLevel {
            try container.encode(defaultThinkingLevel, forKey: .defaultThinkingLevel)
        } else {
            try container.encodeNil(forKey: .defaultThinkingLevel)
        }
        try container.encodeIfPresent(alias, forKey: .alias)
        try container.encodeIfPresent(contextWindowSource, forKey: .contextWindowSource)
        try container.encodeIfPresent(maxTokensSource, forKey: .maxTokensSource)
        try container.encodeIfPresent(thinkingProtocol, forKey: .thinkingProtocol)
        try container.encodeIfPresent(supportsReasoningEffort, forKey: .supportsReasoningEffort)
        try container.encodeIfPresent(supportsImages, forKey: .supportsImages)
        try container.encodeIfPresent(supportsDocuments, forKey: .supportsDocuments)
        try container.encodeIfPresent(availableForSubagents, forKey: .availableForSubagents)
        try container.encodeIfPresent(nativeWebSearch, forKey: .nativeWebSearch)
    }

    private static func decodeSource(
        _ container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> String? {
        guard container.contains(key) else { return nil }
        guard !(try container.decodeNil(forKey: key)) else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "\(key.stringValue) must be catalog or user when present"
            )
        }
        return try container.decode(String.self, forKey: key)
    }

    /// 已声明的档位（过滤掉非法取值后给 UI 用；非法取值本身由校验器拦截）。
    public var declaredThinkingLevels: [RACPThinkingLevel] {
        thinkingLevels.compactMap(RACPThinkingLevel.init(rawValue:))
    }
}

/// 契约 §4.3 的 `ProviderCreateInput`。字段名与上游 camelCase 一致；
/// 可选字段缺省时不编码，`headers` 按上游的字符串字典形状编码。
public struct ProviderCreateInput: Codable, Equatable, Sendable {
    public var name: String
    public var vendorKey: String
    public var type: String
    public var `protocol`: String
    public var authKind: String
    public var baseUrl: String?
    public var models: [ProviderModelSpec]
    public var secretValue: String?
    public var apiStyle: String?
    public var defaultModelId: String?
    public var supportsReasoning: Bool?
    public var supportedThinkingLevels: [String]?
    public var contextWindow: Int?
    public var maxOutputTokens: Int?
    public var temperature: Double?
    /// 上游 `ProviderCreateInput.headers` 是 `Record<string, string>`。
    /// P0 没有请求头编辑 UI，因此默认保持 `nil`，不会改变现有导入载荷。
    public var headers: [String: String]?

    public init(
        name: String,
        vendorKey: String,
        type: String,
        protocol: String,
        authKind: String,
        baseUrl: String? = nil,
        models: [ProviderModelSpec],
        secretValue: String? = nil,
        apiStyle: String? = nil,
        defaultModelId: String? = nil,
        supportsReasoning: Bool? = nil,
        supportedThinkingLevels: [String]? = nil,
        contextWindow: Int? = nil,
        maxOutputTokens: Int? = nil,
        temperature: Double? = nil,
        headers: [String: String]? = nil
    ) {
        self.name = name
        self.vendorKey = vendorKey
        self.type = type
        self.`protocol` = `protocol`
        self.authKind = authKind
        self.baseUrl = baseUrl
        self.models = models
        self.secretValue = secretValue
        self.apiStyle = apiStyle
        self.defaultModelId = defaultModelId
        self.supportsReasoning = supportsReasoning
        self.supportedThinkingLevels = supportedThinkingLevels
        self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens
        self.temperature = temperature
        self.headers = headers
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case vendorKey
        case type
        case `protocol`
        case authKind
        case baseUrl
        case models
        case secretValue
        case apiStyle
        case defaultModelId
        case supportsReasoning
        case supportedThinkingLevels
        case contextWindow
        case maxOutputTokens
        case temperature
        case headers
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        vendorKey = try container.decode(String.self, forKey: .vendorKey)
        type = try container.decode(String.self, forKey: .type)
        `protocol` = try container.decode(String.self, forKey: .`protocol`)
        authKind = try container.decode(String.self, forKey: .authKind)
        baseUrl = try container.decodeIfPresent(String.self, forKey: .baseUrl)
        models = try container.decode([ProviderModelSpec].self, forKey: .models)
        secretValue = try container.decodeIfPresent(String.self, forKey: .secretValue)
        apiStyle = try container.decodeIfPresent(String.self, forKey: .apiStyle)
        defaultModelId = try container.decodeIfPresent(String.self, forKey: .defaultModelId)
        supportsReasoning = try container.decodeIfPresent(Bool.self, forKey: .supportsReasoning)
        supportedThinkingLevels = try container.decodeIfPresent([String].self, forKey: .supportedThinkingLevels)
        contextWindow = try container.decodeIfPresent(Int.self, forKey: .contextWindow)
        maxOutputTokens = try container.decodeIfPresent(Int.self, forKey: .maxOutputTokens)
        temperature = try container.decodeIfPresent(Double.self, forKey: .temperature)

        if container.contains(.headers) {
            guard !(try container.decodeNil(forKey: .headers)) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .headers,
                    in: container,
                    debugDescription: "headers must be an object when present"
                )
            }
            headers = try container.decode([String: String].self, forKey: .headers)
        } else {
            headers = nil
        }
    }

    /// `sourceId` 的确定性来源：vendorKey + baseUrl + 排序后的模型 id 列表（契约 §4.2）。
    public var computedSourceId: String {
        ProviderSourceID.make(vendorKey: vendorKey, baseUrl: baseUrl, modelIds: models.map(\.id))
    }
}

/// 一个 provider 的导入条目。
public struct ProviderImportEntry: Codable, Equatable, Sendable {
    public var sourceId: String
    public var input: ProviderCreateInput

    public init(sourceId: String, input: ProviderCreateInput) {
        self.sourceId = sourceId
        self.input = input
    }

    /// 由 input 确定性推导 `sourceId`，禁止随机 UUID（契约 §4.2）。
    public static func make(input: ProviderCreateInput) -> ProviderImportEntry {
        ProviderImportEntry(sourceId: input.computedSourceId, input: input)
    }
}

/// `defaultModel` 引用（契约 §4.2）。
public struct ProviderImportDefaultModel: Codable, Equatable, Sendable {
    public var sourceId: String
    public var modelId: String

    public init(sourceId: String, modelId: String) {
        self.sourceId = sourceId
        self.modelId = modelId
    }
}

/// 调用方想设为默认的模型（provider 用批次内下标指定，编码时换成确定性 `sourceId`）。
public struct ProviderImportDefaultSelection: Equatable, Sendable {
    public var providerIndex: Int
    public var modelId: String

    public init(providerIndex: Int, modelId: String) {
        self.providerIndex = providerIndex
        self.modelId = modelId
    }
}

/// stdin 载荷（契约 §4.2）。
public struct ProviderImportPayload: Codable, Equatable, Sendable {
    public static let supportedVersion = 1

    public var version: Int
    public var providers: [ProviderImportEntry]
    public var defaultModel: ProviderImportDefaultModel?

    public init(
        version: Int = ProviderImportPayload.supportedVersion,
        providers: [ProviderImportEntry],
        defaultModel: ProviderImportDefaultModel? = nil
    ) {
        self.version = version
        self.providers = providers
        self.defaultModel = defaultModel
    }

    /// 由一组 input 组装载荷：`sourceId` 全部确定性生成，`defaultSelection` 按下标解析成
    /// 对应 provider 的 `sourceId`。
    public static func make(
        inputs: [ProviderCreateInput],
        defaultSelection: ProviderImportDefaultSelection? = nil
    ) -> ProviderImportPayload {
        let entries = inputs.map(ProviderImportEntry.make(input:))
        var defaultModel: ProviderImportDefaultModel?
        if let selection = defaultSelection, inputs.indices.contains(selection.providerIndex) {
            defaultModel = ProviderImportDefaultModel(
                sourceId: entries[selection.providerIndex].sourceId,
                modelId: selection.modelId
            )
        }
        return ProviderImportPayload(providers: entries, defaultModel: defaultModel)
    }
}

// MARK: - sourceId

/// `sourceId` 的确定性构造（契约 §4.2 推荐做法）：`sha256(vendorKey + baseUrl + 排序后的模型 id 列表)`
/// 取前 16 字节十六进制。
///
/// 三段用**长度前缀**编码（`<字节数>:<内容>`）拼接，模型 id 先排序：契约只要求「稳定且同一配置得同一值」，
/// 具体分隔符是客户端自己的规范化，必须在 App 重装后仍然一致（AC-05.3 依赖它复用 providerId）。
/// 用长度前缀而不是逗号/换行直接拼接，是因为 `["a,b"]` 与 `["a","b"]` 必须得到不同 `sourceId`。
public enum ProviderSourceID {
    public static let byteCount = 16

    public static func make(vendorKey: String, baseUrl: String?, modelIds: [String]) -> String {
        let digest = SHA256.hash(data: Data(canonicalString(vendorKey: vendorKey, baseUrl: baseUrl, modelIds: modelIds).utf8))
        return digest.prefix(byteCount).map { String(format: "%02x", $0) }.joined()
    }

    static func canonicalString(vendorKey: String, baseUrl: String?, modelIds: [String]) -> String {
        let base = baseUrl ?? ""
        let sortedModels = modelIds.sorted()
        var fields: [String] = [
            "pi-source-id-v1",
            "vendorKey=\(lengthPrefixed(vendorKey))",
            "baseUrl=\(lengthPrefixed(base))",
            "models.count=\(sortedModels.count)",
        ]
        fields.append(contentsOf: sortedModels.map { "models.element=\(lengthPrefixed($0))" })
        return fields.joined(separator: "\n")
    }

    /// 无歧义编码：`<UTF-8 字节数>:<内容>`，使分隔符本身不参与歧义。
    static func lengthPrefixed(_ value: String) -> String {
        "\(value.utf8.count):\(value)"
    }
}

// MARK: - 编码器

/// 把载荷编码成单行 JSON（键排序，保证同一输入两次编码字节一致）。
public enum ProviderImportEncoder {
    public static func encode(_ payload: ProviderImportPayload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(payload)
    }

    public static func encodeToString(_ payload: ProviderImportPayload) throws -> String {
        let data = try encode(payload)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ProviderImportCodingError.notUTF8
        }
        return text
    }

    public static func decode(_ data: Data) throws -> ProviderImportPayload {
        try JSONDecoder().decode(ProviderImportPayload.self, from: data)
    }
}

public enum ProviderImportCodingError: Error, Equatable {
    case notUTF8
}

// MARK: - 校验

/// 一条校验问题。`message` 是给用户看的中文原因（契约 §7 `INVALID_ARGUMENT` 要显示字段级错误）。
public struct ProviderImportIssue: Equatable, Sendable, CustomStringConvertible {
    public enum Kind: String, Equatable, Sendable {
        case versionMismatch
        case tooManyProviders
        case tooFewProviders
        case unknownField
        case missingRequiredField
        case emptyField
        case invalidEnumValue
        case tooLong
        case outOfRange
        case duplicateValue
        case invalidTextValue
        case notSafeInteger
        case negativeNumber
        case defaultNotInList
        case endpointRejected
        case sourceIdNotDeterministic
        case invalidHeaderName
        case invalidHeaderValue
        case reservedHeaderName
        case secretNotAllowed
        case undecodablePayload
        case payloadTooLarge
    }

    public let kind: Kind
    /// 例如 `providers[0].input.models[1].thinkingLevels`。
    public let path: String
    public let message: String

    public init(kind: Kind, path: String, message: String) {
        self.kind = kind
        self.path = path
        self.message = message
    }

    public var description: String { "\(path): \(message)" }
}

/// 校验失败（聚合全部问题，界面可逐字段显示）。
public struct ProviderImportValidationFailure: Error, Equatable, Sendable, CustomStringConvertible {
    public let issues: [ProviderImportIssue]

    public init(issues: [ProviderImportIssue]) {
        self.issues = issues
    }

    public var description: String {
        issues.map(\.description).joined(separator: "; ")
    }
}

/// 契约 §4.2/§4.3/§4.4/§4.6 的载荷校验：所有规则在**提交前**本地执行（AC-04.2 / AC-04.7）。
public enum ProviderImportValidation {
    // MARK: 入口

    /// 校验已构建的载荷。
    public static func issues(in payload: ProviderImportPayload) -> [ProviderImportIssue] {
        var issues: [ProviderImportIssue] = []

        if payload.version != ProviderImportPayload.supportedVersion {
            issues.append(
                .init(
                    kind: .versionMismatch,
                    path: "version",
                    message: "载荷 version 必须严格等于 \(ProviderImportPayload.supportedVersion)，当前是 \(payload.version)"
                )
            )
        }
        if payload.providers.isEmpty {
            issues.append(.init(kind: .tooFewProviders, path: "providers", message: "载荷里至少需要一个 provider"))
        }
        if payload.providers.count > ProviderVendorSchema.maxProviders {
            issues.append(
                .init(
                    kind: .tooManyProviders,
                    path: "providers",
                    message: "一次最多导入 \(ProviderVendorSchema.maxProviders) 个 provider，当前 \(payload.providers.count) 个"
                )
            )
        }
        issues.append(contentsOf: payloadSizeIssues(payload))
        var seenSourceIds = Set<String>()
        for (index, entry) in payload.providers.enumerated() {
            let path = "providers[\(index)]"
            issues.append(contentsOf: textIssues(
                entry.sourceId,
                path: "\(path).sourceId",
                label: "sourceId"
            ))
            if !entry.sourceId.isEmpty, !seenSourceIds.insert(entry.sourceId).inserted {
                issues.append(
                    .init(kind: .duplicateValue, path: "\(path).sourceId", message: "sourceId 在批次内重复：\(entry.sourceId)")
                )
            }
            let expected = entry.input.computedSourceId
            if !entry.sourceId.isEmpty, entry.sourceId != expected {
                issues.append(
                    .init(
                        kind: .sourceIdNotDeterministic,
                        path: "\(path).sourceId",
                        message: "sourceId 必须由 vendorKey + baseUrl + 排序后的模型 id 确定性生成（期望 \(expected)，实际 \(entry.sourceId)）；禁止随机值，否则重装后无法复用 providerId"
                    )
                )
            }
            issues.append(contentsOf: inputIssues(entry.input, path: "\(path).input"))
        }

        if let defaultModel = payload.defaultModel {
            if !payload.providers.contains(where: { $0.sourceId == defaultModel.sourceId }) {
                issues.append(
                    .init(
                        kind: .defaultNotInList,
                        path: "defaultModel.sourceId",
                        message: "defaultModel.sourceId 不在本次 providers 中：\(defaultModel.sourceId)"
                    )
                )
            } else if let provider = payload.providers.first(where: { $0.sourceId == defaultModel.sourceId }),
                      !provider.input.models.contains(where: { $0.id == defaultModel.modelId }) {
                issues.append(
                    .init(
                        kind: .defaultNotInList,
                        path: "defaultModel.modelId",
                        message: "defaultModel.modelId 不属于该 provider 的模型列表：\(defaultModel.modelId)"
                    )
                )
            }
        }

        return issues
    }

    /// 校验原始 JSON：先按契约 §4.3「严格模式」拦截未列出的字段，再解码后按同一套规则校验。
    public static func issues(in raw: JSONValue) -> [ProviderImportIssue] {
        var issues = unknownFieldIssues(in: raw)
        do {
            let payload = try ProviderImportPayload.decoded(from: raw)
            issues.append(contentsOf: Self.issues(in: payload))
        } catch {
            issues.append(
                .init(
                    kind: .undecodablePayload,
                    path: "$",
                    message: "载荷无法解码为 provider-import 结构（缺少必填字段或类型不符）：\(error)"
                )
            )
        }
        return issues
    }

    /// 契约 §4.1：整份 stdin 载荷 ≤ 1 MiB，超限给字段级错误（不等到 Host 返回 `PAYLOAD_TOO_LARGE`）。
    static func payloadSizeIssues(_ payload: ProviderImportPayload) -> [ProviderImportIssue] {
        let limit = ProviderVendorSchema.maxPayloadBytes
        guard let encoded = try? ProviderImportEncoder.encode(payload), encoded.count > limit else { return [] }
        return [
            .init(
                kind: .payloadTooLarge,
                path: "providers",
                message: "载荷 \(encoded.count) 字节，超过契约 §4.1 的 \(limit) 字节（1 MiB）上限，请减少 provider 或模型数量"
            )
        ]
    }

    /// 校验并抛错；无问题时返回载荷本身。
    @discardableResult
    public static func validate(_ payload: ProviderImportPayload) throws -> ProviderImportPayload {
        let issues = issues(in: payload)
        if !issues.isEmpty {
            throw ProviderImportValidationFailure(issues: issues)
        }
        return payload
    }

    // MARK: input 级规则

    static func inputIssues(_ input: ProviderCreateInput, path: String) -> [ProviderImportIssue] {
        var issues: [ProviderImportIssue] = []
        let providerPath = path

        issues.append(contentsOf: textIssues(input.name, path: "\(providerPath).name", label: "name"))
        issues.append(contentsOf: textIssues(input.vendorKey, path: "\(providerPath).vendorKey", label: "vendorKey"))
        issues.append(contentsOf: textIssues(input.`protocol`, path: "\(providerPath).protocol", label: "protocol"))
        issues.append(contentsOf: textIssues(input.authKind, path: "\(providerPath).authKind", label: "authKind"))
        if !ProviderVendorSchema.types.contains(input.type) {
            issues.append(
                .init(
                    kind: .invalidEnumValue,
                    path: "\(providerPath).type",
                    message: "type 只能取 \(ProviderVendorSchema.types.joined(separator: " / "))，当前是「\(input.type)」"
                )
            )
        }
        if !ProviderVendorSchema.protocols.contains(input.`protocol`) {
            issues.append(
                .init(
                    kind: .invalidEnumValue,
                    path: "\(providerPath).protocol",
                    message: "protocol 只能取 \(ProviderVendorSchema.protocols.joined(separator: " / "))，当前是「\(input.`protocol`)」"
                )
            )
        }
        if !ProviderVendorSchema.p0AuthKinds.contains(input.authKind) {
            issues.append(
                .init(
                    kind: .invalidEnumValue,
                    path: "\(providerPath).authKind",
                    message: "authKind 首版只支持 \(ProviderVendorSchema.p0AuthKinds.joined(separator: " / "))（订阅账号与 none 不在 P0 范围），当前是「\(input.authKind)」"
                )
            )
        }

        // secretValue：P0 恒必填，≤16384 字节（契约 §4.1 / §4.3，AC-04.2）。
        let secret = input.secretValue ?? ""
        if input.authKind == "none" {
            if input.secretValue != nil {
                issues.append(
                    .init(
                        kind: .secretNotAllowed,
                        path: "\(providerPath).secretValue",
                        message: "authKind=none 时不得传 secretValue"
                    )
                )
            }
        } else if ECMAScriptString.trim(secret).isEmpty {
            issues.append(
                .init(kind: .missingRequiredField, path: "\(providerPath).secretValue", message: "secretValue（API Key）必填")
            )
        } else {
            issues.append(contentsOf: textIssues(
                secret,
                path: "\(providerPath).secretValue",
                label: "secretValue",
                maxLength: nil
            ))
            if secret.utf8.count > ProviderVendorSchema.maxSecretBytes {
                issues.append(
                    .init(
                        kind: .tooLong,
                        path: "\(providerPath).secretValue",
                        message: "secretValue 上限 \(ProviderVendorSchema.maxSecretBytes) 字节，当前 \(secret.utf8.count) 字节"
                    )
                )
            }
        }

        if let baseUrl = input.baseUrl {
            issues.append(contentsOf: textIssues(
                baseUrl,
                path: "\(providerPath).baseUrl",
                label: "baseUrl",
                maxLength: ProviderVendorSchema.maxBaseURLLength
            ))
        }

        // 端点策略（契约 §4.5）：命中即拒绝并给出中文原因，不发起导入。
        let endpoint = EndpointPolicy.validate(baseUrl: input.baseUrl, vendorKey: input.vendorKey)
        if let rejection = endpoint.rejection {
            issues.append(
                .init(kind: .endpointRejected, path: "\(providerPath).baseUrl", message: rejection.message)
            )
        }

        if let apiStyle = input.apiStyle, !ProviderVendorSchema.apiStyles.contains(apiStyle) {
            issues.append(
                .init(
                    kind: .invalidEnumValue,
                    path: "\(providerPath).apiStyle",
                    message: "apiStyle 只能取 \(ProviderVendorSchema.apiStyles.joined(separator: " / "))，当前是「\(apiStyle)」"
                )
            )
        }

        if let levels = input.supportedThinkingLevels {
            for (offset, level) in levels.enumerated() where !ProviderVendorSchema.thinkingLevels.contains(level) {
                issues.append(
                    .init(
                        kind: .invalidEnumValue,
                        path: "\(providerPath).supportedThinkingLevels[\(offset)]",
                        message: "档位「\(level)」不在 \(ProviderVendorSchema.thinkingLevels.joined(separator: "/")) 中"
                    )
                )
            }
            if Set(levels).count != levels.count {
                issues.append(
                    .init(
                        kind: .duplicateValue,
                        path: "\(providerPath).supportedThinkingLevels",
                        message: "supportedThinkingLevels 不能重复"
                    )
                )
            }
        }

        issues.append(contentsOf: nonNegativeIntegerIssues(input.contextWindow, path: "\(providerPath).contextWindow", label: "contextWindow"))
        issues.append(contentsOf: nonNegativeIntegerIssues(input.maxOutputTokens, path: "\(providerPath).maxOutputTokens", label: "maxOutputTokens"))

        if let temperature = input.temperature, temperature < 0 {
            issues.append(
                .init(kind: .negativeNumber, path: "\(providerPath).temperature", message: "temperature 不能为负（允许 0）")
            )
        }

        if let headers = input.headers {
            issues.append(contentsOf: headerIssues(headers, path: "\(providerPath).headers"))
        }

        // models
        if input.models.count < ProviderVendorSchema.minModels {
            issues.append(
                .init(kind: .outOfRange, path: "\(providerPath).models", message: "至少需要 1 个模型")
            )
        }
        if input.models.count > ProviderVendorSchema.maxModels {
            issues.append(
                .init(
                    kind: .outOfRange,
                    path: "\(providerPath).models",
                    message: "模型数量上限 \(ProviderVendorSchema.maxModels)，当前 \(input.models.count) 个"
                )
            )
        }

        var seenModelIds = Set<String>()
        for (offset, model) in input.models.enumerated() {
            let modelPath = "\(providerPath).models[\(offset)]"
            issues.append(contentsOf: textIssues(
                model.id,
                path: "\(modelPath).id",
                label: "模型 id"
            ))
            if !model.id.isEmpty, !seenModelIds.insert(model.id).inserted {
                issues.append(
                    .init(kind: .duplicateValue, path: "\(modelPath).id", message: "模型 id 在批次内重复：\(model.id)")
                )
            }
            if let alias = model.alias {
                issues.append(contentsOf: textIssues(
                    alias,
                    path: "\(modelPath).alias",
                    label: "alias",
                    maxLength: ProviderVendorSchema.maxAliasLength
                ))
            }
            issues.append(contentsOf: nonNegativeIntegerIssues(model.contextWindow, path: "\(modelPath).contextWindow", label: "contextWindow"))
            issues.append(contentsOf: nonNegativeIntegerIssues(model.maxTokens, path: "\(modelPath).maxTokens", label: "maxTokens"))
            issues.append(contentsOf: modelLimitSourceIssues(
                model.contextWindowSource,
                path: "\(modelPath).contextWindowSource",
                label: "contextWindowSource"
            ))
            issues.append(contentsOf: modelLimitSourceIssues(
                model.maxTokensSource,
                path: "\(modelPath).maxTokensSource",
                label: "maxTokensSource"
            ))

            for (levelOffset, level) in model.thinkingLevels.enumerated()
            where !ProviderVendorSchema.thinkingLevels.contains(level) {
                issues.append(
                    .init(
                        kind: .invalidEnumValue,
                        path: "\(modelPath).thinkingLevels[\(levelOffset)]",
                        message: "档位「\(level)」不在 \(ProviderVendorSchema.thinkingLevels.joined(separator: "/")) 中"
                    )
                )
            }
            if Set(model.thinkingLevels).count != model.thinkingLevels.count {
                issues.append(
                    .init(kind: .duplicateValue, path: "\(modelPath).thinkingLevels", message: "thinkingLevels 必须去重")
                )
            }
            if let level = model.defaultThinkingLevel,
               level != ProviderVendorSchema.defaultThinkingLevelOmit,
               !model.thinkingLevels.contains(level) {
                issues.append(
                    .init(
                        kind: .defaultNotInList,
                        path: "\(modelPath).defaultThinkingLevel",
                        message: "defaultThinkingLevel「\(level)」不在该模型声明的档位 \(model.thinkingLevels) 中"
                    )
                )
            }
            if let thinkingProtocol = model.thinkingProtocol,
               !ProviderVendorSchema.thinkingProtocols.contains(thinkingProtocol) {
                issues.append(
                    .init(
                        kind: .invalidEnumValue,
                        path: "\(modelPath).thinkingProtocol",
                        message: "thinkingProtocol 只能取 \(ProviderVendorSchema.thinkingProtocols.joined(separator: " / "))，当前是「\(thinkingProtocol)」"
                    )
                )
            }
        }

        if let defaultModelId = input.defaultModelId,
           !input.models.contains(where: { $0.id == defaultModelId }) {
            issues.append(
                .init(
                    kind: .defaultNotInList,
                    path: "\(providerPath).defaultModelId",
                    message: "defaultModelId「\(defaultModelId)」不在 models 的 id 中"
                )
            )
        }

        return issues
    }

    // MARK: 细项

    /// 镜像上游 `text()`：必须非空、无首尾空白、无控制字符，并受长度上限约束。
    static func textIssues(
        _ value: String,
        path: String,
        label: String,
        maxLength: Int? = ProviderVendorSchema.maxTextLength
    ) -> [ProviderImportIssue] {
        var issues: [ProviderImportIssue] = []
        if ECMAScriptString.trim(value).isEmpty {
            issues.append(.init(kind: .emptyField, path: path, message: "\(label) 必须是非空文本"))
            return issues
        }
        if let maxLength, value.utf16.count > maxLength {
            issues.append(
                .init(
                    kind: .tooLong,
                    path: path,
                    message: "\(label) 上限 \(maxLength) 字符，当前 \(value.utf16.count) 字符"
                )
            )
        }
        if !ECMAScriptString.isTrimmed(value) {
            issues.append(
                .init(
                    kind: .invalidTextValue,
                    path: path,
                    message: "\(label) 不能以空白或换行开头/结尾"
                )
            )
        }
        if value.unicodeScalars.contains(where: { $0.value <= 0x1F || $0.value == 0x7F }) {
            issues.append(
                .init(
                    kind: .invalidTextValue,
                    path: path,
                    message: "\(label) 不能包含换行、制表符或其他控制字符"
                )
            )
        }
        return issues
    }

    static func nonNegativeIntegerIssues(_ value: Int?, path: String, label: String) -> [ProviderImportIssue] {
        guard let value else { return [] }
        var issues: [ProviderImportIssue] = []
        if value < 0 {
            issues.append(.init(kind: .negativeNumber, path: path, message: "\(label) 不能为负"))
        }
        if value > ProviderVendorSchema.maxSafeInteger {
            issues.append(
                .init(
                    kind: .notSafeInteger,
                    path: path,
                    message: "\(label) 必须是安全整数（≤ \(ProviderVendorSchema.maxSafeInteger)）"
                )
            )
        }
        return issues
    }

    static func modelLimitSourceIssues(_ source: String?, path: String, label: String) -> [ProviderImportIssue] {
        guard let source, !ProviderVendorSchema.modelLimitSources.contains(source) else { return [] }
        return [
            .init(
                kind: .invalidEnumValue,
                path: path,
                message: "\(label) 只能取 \(ProviderVendorSchema.modelLimitSources.joined(separator: " / "))，当前是「\(source)」"
            )
        ]
    }

    static func headerIssues(_ headers: [String: String], path: String) -> [ProviderImportIssue] {
        var issues: [ProviderImportIssue] = []
        if headers.count > ProviderVendorSchema.maxHeaders {
            issues.append(
                .init(
                    kind: .outOfRange,
                    path: path,
                    message: "headers 上限 \(ProviderVendorSchema.maxHeaders) 项，当前 \(headers.count) 项"
                )
            )
        }
        var seenNames = Set<String>()
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            let headerPath = "\(path)[\"\(name)\"]"
            let foldedName = name.lowercased()
            if !isValidHeaderName(name) {
                issues.append(
                    .init(
                        kind: .invalidHeaderName,
                        path: headerPath,
                        message: "请求头名称「\(name)」不合法（要求 [0-9A-Za-z][0-9A-Za-z-]{0,255}）"
                    )
                )
            }
            if !seenNames.insert(foldedName).inserted {
                issues.append(
                    .init(
                        kind: .duplicateValue,
                        path: headerPath,
                        message: "请求头名称「\(name)」忽略大小写后重复"
                    )
                )
            }
            if ProviderVendorSchema.reservedHeaderNames.contains(foldedName) {
                issues.append(
                    .init(
                        kind: .reservedHeaderName,
                        path: headerPath,
                        message: "请求头「\(name)」是保留名，不能自定义"
                    )
                )
            }
            if value.utf8.count > ProviderVendorSchema.maxHeaderValueBytes {
                issues.append(
                    .init(
                        kind: .tooLong,
                        path: headerPath,
                        message: "请求头「\(name)」的值上限 \(ProviderVendorSchema.maxHeaderValueBytes) 字节，当前 \(value.utf8.count) 字节"
                    )
                )
            }
            if !isValidHeaderValue(value) {
                issues.append(
                    .init(
                        kind: .invalidHeaderValue,
                        path: headerPath,
                        message: "请求头「\(name)」的值只能包含制表符、可打印 ASCII 或 Latin-1 字符，不能包含换行或其他控制字符"
                    )
                )
            }
        }
        return issues
    }

    static func isValidHeaderName(_ name: String) -> Bool {
        guard (1...256).contains(name.count) else { return false }
        let scalars = Array(name.unicodeScalars)
        guard let first = scalars.first, first.isASCIIAlphanumeric else { return false }
        return scalars.dropFirst().allSatisfy { $0.isASCIIAlphanumeric || $0 == "-" }
    }

    static func isValidHeaderValue(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { scalar in
            scalar.value == 0x09
                || (0x20...0x7E).contains(scalar.value)
                || (0x80...0xFF).contains(scalar.value)
        }
    }

    // MARK: 严格模式（未知字段）

    enum Keys {
        static let payload: Set<String> = ["version", "providers", "defaultModel"]
        static let entry: Set<String> = ["sourceId", "input"]
        static let input: Set<String> = [
            "name", "vendorKey", "type", "protocol", "authKind", "baseUrl", "models", "secretValue",
            "apiStyle", "defaultModelId", "supportsReasoning", "supportedThinkingLevels",
            "contextWindow", "maxOutputTokens", "temperature", "headers",
        ]
        static let model: Set<String> = [
            "id", "contextWindow", "maxTokens", "thinkingLevels", "alias", "contextWindowSource",
            "maxTokensSource", "defaultThinkingLevel", "thinkingProtocol", "supportsReasoningEffort",
            "supportsImages", "supportsDocuments", "availableForSubagents", "nativeWebSearch",
        ]
        static let defaultModel: Set<String> = ["sourceId", "modelId"]
    }

    /// 契约 §4.3「严格模式」：出现未列出的字段即 `INVALID_ARGUMENT`。
    static func unknownFieldIssues(in raw: JSONValue) -> [ProviderImportIssue] {
        var issues: [ProviderImportIssue] = []
        guard let root = raw.objectValue else {
            return [.init(kind: .undecodablePayload, path: "$", message: "载荷必须是 JSON 对象")]
        }
        for key in root.keys where !Keys.payload.contains(key) {
            issues.append(.init(kind: .unknownField, path: key, message: "载荷里出现了未定义的字段「\(key)」"))
        }
        for (index, entryValue) in (root["providers"]?.arrayValue ?? []).enumerated() {
            let path = "providers[\(index)]"
            guard let entry = entryValue.objectValue else {
                issues.append(.init(kind: .undecodablePayload, path: path, message: "provider 条目必须是 JSON 对象"))
                continue
            }
            for key in entry.keys where !Keys.entry.contains(key) {
                issues.append(.init(kind: .unknownField, path: "\(path).\(key)", message: "provider 条目里出现了未定义的字段「\(key)」"))
            }
            if let input = entry["input"]?.objectValue {
                for key in input.keys where !Keys.input.contains(key) {
                    issues.append(.init(kind: .unknownField, path: "\(path).input.\(key)", message: "input 里出现了未定义的字段「\(key)」"))
                }
                for (modelIndex, modelValue) in (input["models"]?.arrayValue ?? []).enumerated() {
                    let modelPath = "\(path).input.models[\(modelIndex)]"
                    guard let model = modelValue.objectValue else {
                        issues.append(.init(kind: .undecodablePayload, path: modelPath, message: "模型必须是 JSON 对象"))
                        continue
                    }
                    for key in model.keys where !Keys.model.contains(key) {
                        issues.append(.init(kind: .unknownField, path: "\(modelPath).\(key)", message: "模型里出现了未定义的字段「\(key)」"))
                    }
                }
            }
        }
        if let defaultModel = root["defaultModel"]?.objectValue {
            for key in defaultModel.keys where !Keys.defaultModel.contains(key) {
                issues.append(.init(kind: .unknownField, path: "defaultModel.\(key)", message: "defaultModel 里出现了未定义的字段「\(key)」"))
            }
        }
        return issues
    }
}

extension Unicode.Scalar {
    var isASCIIAlphanumeric: Bool {
        (self >= "0" && self <= "9") || (self >= "a" && self <= "z") || (self >= "A" && self <= "Z")
    }
}
