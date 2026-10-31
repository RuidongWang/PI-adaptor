import Foundation

private let modelThinkingLevelOrder = ["off", "minimal", "low", "medium", "high", "xhigh", "max"]

private func normalizedThinkingLevel(_ raw: String?) -> String? {
    guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
          !raw.isEmpty
    else { return nil }
    if raw == "none" || raw == "off" { return "off" }
    return modelThinkingLevelOrder.contains(raw) ? raw : nil
}

// MARK: - 服务端模型清单

/// One model row returned by a provider's own `GET /models` endpoint.
public struct DiscoveredModel: Equatable, Sendable {
    public var modelId: String
    public var displayName: String
    /// Capacity reported by the service itself. It outranks catalog metadata.
    public var contextWindow: Int?
    public var maxTokens: Int?
    /// Effort ladder published by the service. When present it outranks
    /// models.dev's generic reasoning-option projection.
    public var thinkingLevels: [String]?
    public var defaultThinkingLevel: String?

    public init(
        modelId: String,
        displayName: String,
        contextWindow: Int? = nil,
        maxTokens: Int? = nil,
        thinkingLevels: [String]? = nil,
        defaultThinkingLevel: String? = nil
    ) {
        self.modelId = modelId
        self.displayName = displayName
        self.contextWindow = contextWindow
        self.maxTokens = maxTokens
        self.thinkingLevels = thinkingLevels
        self.defaultThinkingLevel = defaultThinkingLevel
    }
}

public enum ModelListError: Error, Equatable, LocalizedError {
    case invalidEndpoint
    case invalidResponse
    case emptyList
    case network(ModelListNetworkFailure)
    case remote(status: Int, message: String)
    case malformedEnvelope(String)

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "模型请求地址不合法"
        case .invalidResponse:
            return "模型列表不是可识别的 JSON"
        case .emptyList:
            return "模型服务返回了空列表，请确认地址和 API Key"
        case let .network(failure):
            return failure.errorDescription
        case let .remote(status, _):
            switch status {
            case 401:
                return "模型服务认证失败（401）：请检查 API Key"
            case 402:
                return "模型服务账户余额不足（402）"
            case 403:
                return "模型服务拒绝访问（403）：请检查账户权限"
            case 404:
                return "模型列表地址不存在（404）：请检查 Base URL"
            case 408:
                return "模型服务请求超时（408）"
            case 409, 429:
                return "模型服务请求受限（HTTP \(status)）：请稍后重试"
            case 500...599:
                return "模型服务暂时不可用（HTTP \(status)）"
            default:
                return "模型列表请求失败（HTTP \(status)）"
            }
        case let .malformedEnvelope(detail):
            return "服务器模型发现结果无法解析：\(detail)"
        }
    }
}

public enum ModelListNetworkFailure: Equatable, Sendable {
    case dns
    case tls
    case timeout
    case refused
    case unknown

    public var errorDescription: String {
        switch self {
        case .dns:
            return "无法解析模型服务域名：请检查 DNS 或 Base URL"
        case .tls:
            return "模型服务 TLS 连接失败：请检查证书或代理"
        case .timeout:
            return "模型服务连接超时：请检查网络或代理"
        case .refused:
            return "模型服务拒绝连接：请检查端口或服务状态"
        case .unknown:
            return "无法连接模型服务：请检查网络、Base URL 或代理"
        }
    }

    public static func classify(_ detail: String?) -> Self {
        let value = detail?.lowercased() ?? ""
        if value.contains("name or service not known")
            || value.contains("nodename nor servname")
            || value.contains("temporary failure in name resolution")
            || value.contains("getaddrinfo") {
            return .dns
        }
        if value.contains("ssl")
            || value.contains("tls")
            || value.contains("certificate") {
            return .tls
        }
        if value.contains("timed out") || value.contains("timeout") {
            return .timeout
        }
        if value.contains("connection refused") || value.contains("errno 111") {
            return .refused
        }
        return .unknown
    }
}

/// Pure parser for the three common model-list shapes:
/// `{data:[…]}`, `{models:[…]}` (including Google `models/…` names), or a bare array.
public enum ModelListParser {
    public static let maxModels = 500

    public static func modelsURL(baseURL raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host != nil
        else {
            throw ModelListError.invalidEndpoint
        }

        var path = components.percentEncodedPath
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        for suffix in ["/chat/completions", "/responses", "/messages"] where path.hasSuffix(suffix) {
            path.removeLast(suffix.count)
            break
        }
        if !path.hasSuffix("/models") {
            path += "/models"
        }
        components.percentEncodedPath = path.isEmpty ? "/models" : path
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { throw ModelListError.invalidEndpoint }
        return url.absoluteString
    }

    public static func parse(data: Data) throws -> [DiscoveredModel] {
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ModelListError.invalidResponse
        }
        let rows: [Any]
        if let array = root as? [Any] {
            rows = array
        } else if let object = root as? [String: Any] {
            if let data = object["data"] as? [Any] {
                rows = data
            } else if let models = object["models"] as? [Any] {
                rows = models
            } else {
                rows = []
            }
        } else {
            throw ModelListError.invalidResponse
        }

        var result: [DiscoveredModel] = []
        for row in rows {
            guard let item = row as? [String: Any] else { continue }
            let rawId = string(item["id"]) ?? string(item["slug"]) ?? string(item["name"])
            let modelId = (rawId ?? "").replacingOccurrences(of: "models/", with: "")
            guard !modelId.isEmpty else { continue }
            let displayName =
                string(item["display_name"])
                ?? string(item["displayName"])
                ?? string(item["name"])
                ?? modelId
            let effort = item["effort"] as? [String: Any]
            let supportedLevels: Set<String>?
            if effort?.keys.contains("supported_levels") == true {
                supportedLevels = Set(
                    (effort?["supported_levels"] as? [Any] ?? [])
                        .compactMap { normalizedThinkingLevel(string($0)) }
                )
            } else {
                supportedLevels = nil
            }
            let defaultEffort = normalizedThinkingLevel(string(effort?["default_level"]))
            let thinkingLevels = supportedLevels.map {
                modelThinkingLevelOrder.filter($0.contains)
            }
            result.append(
                DiscoveredModel(
                    modelId: modelId,
                    displayName: displayName,
                    contextWindow: firstPositiveInteger(
                        item,
                        keys: ["context_window", "context_length", "inputTokenLimit", "contextWindow"]
                    ),
                    maxTokens: firstPositiveInteger(
                        item,
                        keys: ["max_output_tokens", "max_tokens", "outputTokenLimit", "maxTokens"]
                    ),
                    thinkingLevels: thinkingLevels,
                    defaultThinkingLevel: defaultEffort.flatMap {
                        supportedLevels?.contains($0) == true ? $0 : nil
                    }
                )
            )
            if result.count >= maxModels { break }
        }
        guard !result.isEmpty else { throw ModelListError.emptyList }
        return result.sorted { $0.modelId.localizedStandardCompare($1.modelId) == .orderedAscending }
    }

    private static func string(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func firstPositiveInteger(_ row: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            guard let number = row[key] as? NSNumber else { continue }
            let double = number.doubleValue
            let int = number.intValue
            guard double.isFinite, double > 0, Double(int) == double else { continue }
            return int
        }
        return nil
    }
}

/// Envelope printed by the SSH-side discovery helper.
public struct RemoteModelListEnvelope: Codable, Equatable, Sendable {
    public var status: Int
    public var url: String
    public var body: String
    public var error: String?

    public init(status: Int, url: String, body: String, error: String? = nil) {
        self.status = status
        self.url = url
        self.body = body
        self.error = error
    }

    public static let stdoutPrefix = "PI_MODELS_RESULT "

    public static func parse(stdout: String, exitStatus: Int32? = nil) throws -> [DiscoveredModel] {
        guard exitStatus == nil || exitStatus == 0 else {
            throw ModelListError.malformedEnvelope("远端命令退出码 \(exitStatus ?? -1)")
        }
        guard let line = stdout
            .split(whereSeparator: \.isNewline)
            .last(where: { $0.hasPrefix(stdoutPrefix) })
        else {
            throw ModelListError.malformedEnvelope("没有找到 \(stdoutPrefix.trimmingCharacters(in: .whitespaces)) 结果行")
        }
        let payload = String(line.dropFirst(stdoutPrefix.count))
        guard let data = payload.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(RemoteModelListEnvelope.self, from: data)
        else {
            throw ModelListError.malformedEnvelope("结果行不是合法 JSON")
        }
        if envelope.status == 0 {
            throw ModelListError.network(ModelListNetworkFailure.classify(envelope.error))
        }
        if let error = envelope.error, !error.isEmpty {
            throw ModelListError.remote(status: envelope.status, message: error)
        }
        guard (200..<300).contains(envelope.status) else {
            throw ModelListError.remote(status: envelope.status, message: envelope.body)
        }
        guard let body = envelope.body.data(using: .utf8) else {
            throw ModelListError.invalidResponse
        }
        return try ModelListParser.parse(data: body)
    }
}

// MARK: - models.dev 标准配置

public enum ModelMetadataSource: Equatable, Sendable {
    case modelsDev(provider: String)
    case endpoint
    case generic
}

public struct ResolvedModelCandidate: Equatable, Sendable {
    public var discovered: DiscoveredModel
    public var spec: ProviderModelSpec
    public var metadataSource: ModelMetadataSource

    public init(discovered: DiscoveredModel, spec: ProviderModelSpec, metadataSource: ModelMetadataSource) {
        self.discovered = discovered
        self.spec = spec
        self.metadataSource = metadataSource
    }
}

/// Read-only matcher over the same models.dev snapshot shipped by PI-Desktop.
public struct ModelsDevCatalog: Sendable {
    public static let defaultContextWindow = 128_000
    public static let defaultMaxTokens = 8_192

    private struct Entry: Sendable {
        var providerKey: String
        var profile: Profile
        var keys: Set<String>
    }

    private struct Profile: Sendable {
        var providerName: String
        var modelId: String
        var displayName: String
        var contextWindow: Int?
        var maxTokens: Int?
        var thinkingLevels: [String]
        var defaultThinkingLevel: String?
        var supportsReasoningEffort: Bool?
        var thinkingProtocol: String?
        var supportsImages: Bool
        var supportsDocuments: Bool
    }

    private var entries: [Entry]

    public static let shared: ModelsDevCatalog = {
        guard let url = Bundle.module.url(forResource: "models.dev.api", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? ModelsDevCatalog(data: data)
        else {
            return ModelsDevCatalog(entries: [])
        }
        return catalog
    }()

    public init(data: Data) throws {
        entries = []
        let root = try JSONSerialization.jsonObject(with: data)
        guard let providers = root as? [String: Any] else {
            throw ModelListError.invalidResponse
        }
        var parsed: [Entry] = []
        for (providerKey, rawProvider) in providers {
            guard let provider = rawProvider as? [String: Any],
                  let models = provider["models"] as? [String: Any]
            else { continue }
            let providerName = string(provider["name"]) ?? providerKey
            for (modelKey, rawModel) in models {
                guard let model = rawModel as? [String: Any] else { continue }
                let modelId = string(model["id"]) ?? modelKey
                guard !modelId.isEmpty else { continue }
                let reasoning = (model["reasoning"] as? Bool) == true
                let options = model["reasoning_options"]
                let modalities = model["modalities"] as? [String: Any]
                let inputs = stringArray(modalities?["input"])
                let limit = model["limit"] as? [String: Any]
                let levels = thinkingLevels(reasoning: reasoning, options: options)
                let profile = Profile(
                    providerName: providerName,
                    modelId: modelId,
                    displayName: string(model["name"]) ?? modelId,
                    contextWindow: firstPositiveInteger(limit, keys: ["context", "input"]),
                    maxTokens: firstPositiveInteger(limit, keys: ["output"]),
                    thinkingLevels: levels,
                    defaultThinkingLevel: levels.contains("medium") ? "medium" : levels.first,
                    supportsReasoningEffort: reasoning && options != nil ? true : nil,
                    thinkingProtocol: thinkingProtocol(providerKey: providerKey, reasoning: reasoning, options: options),
                    supportsImages: inputs.contains("image"),
                    supportsDocuments: inputs.contains("pdf")
                )
                parsed.append(
                    Entry(
                        providerKey: providerKey,
                        profile: profile,
                        keys: modelKeys(modelId)
                    )
                )
            }
        }
        entries = parsed.sorted {
            $0.providerKey == $1.providerKey
                ? $0.profile.modelId < $1.profile.modelId
                : $0.providerKey < $1.providerKey
        }
    }

    private init(entries: [Entry]) {
        self.entries = entries
    }

    public func match(modelId: String) -> (profile: ModelsDevProfile, providerKey: String)? {
        let requested = modelKeys(modelId)
        guard !requested.isEmpty else { return nil }
        let hint = vendorHint(modelId)
        var matches: [(entry: Entry, score: Int)] = []
        for entry in entries {
            guard !entry.keys.isDisjoint(with: requested) else { continue }
            let exact = requested.contains(normalizedModelId(entry.profile.modelId))
            var score = exact ? 100 : 60
            if let hint, providerAliases(hint).contains(normalizedProvider(entry.providerKey)) {
                score += 40
            }
            matches.append((entry, score))
        }
        matches.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.entry.providerKey != $1.entry.providerKey {
                return $0.entry.providerKey < $1.entry.providerKey
            }
            return $0.entry.profile.modelId < $1.entry.profile.modelId
        }
        guard let best = matches.first else { return nil }
        if matches.count > 1 {
            let tied = matches.prefix { $0.score == best.score }
            if tied.count > 1 {
                let signatures = Set(tied.map { signature($0.entry.profile) })
                // Ambiguous catalog copies with different capabilities must not seed
                // a standard configuration. A vendor hint or an exact id should
                // select one owner; otherwise the caller uses the endpoint values.
                guard signatures.count == 1 else { return nil }
            }
        }
        let profile = best.entry.profile
        return (
            ModelsDevProfile(
                providerName: profile.providerName,
                modelId: profile.modelId,
                displayName: profile.displayName,
                contextWindow: profile.contextWindow,
                maxTokens: profile.maxTokens,
                thinkingLevels: profile.thinkingLevels,
                defaultThinkingLevel: profile.defaultThinkingLevel,
                supportsReasoningEffort: profile.supportsReasoningEffort,
                thinkingProtocol: profile.thinkingProtocol,
                supportsImages: profile.supportsImages,
                supportsDocuments: profile.supportsDocuments
            ),
            best.entry.providerKey
        )
    }

    private func signature(_ profile: Profile) -> String {
        [
            profile.contextWindow.map(String.init) ?? "",
            profile.maxTokens.map(String.init) ?? "",
            profile.thinkingLevels.joined(separator: ","),
            profile.supportsImages ? "image" : "",
            profile.supportsDocuments ? "pdf" : "",
        ].joined(separator: "|")
    }

    private func normalizedProvider(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
    }

    private func providerAliases(_ value: String) -> Set<String> {
        let key = normalizedProvider(value)
        let aliases: [String: [String]] = [
            "google": ["google", "google-vertex", "gemini"],
            "anthropic": ["anthropic"],
            "openai": ["openai"],
            "deepseek": ["deepseek"],
            "xai": ["xai", "x-ai"],
            "alibaba-cn": ["alibaba-cn", "alibaba", "qwen"],
            "zhipuai": ["zhipuai", "zai"],
            "moonshotai-cn": ["moonshotai-cn", "moonshotai", "kimi-for-coding"],
            "minimax": ["minimax", "minimax-cn"],
            "meta": ["meta"],
            "mistral": ["mistral"],
        ]
        return Set([key] + (aliases[key] ?? []))
    }

    private func vendorHint(_ modelId: String) -> String? {
        let id = normalizedModelId(modelId)
        if id.contains("claude") || id.contains("sonnet") || id.contains("opus") || id.contains("haiku") {
            return "anthropic"
        }
        if id.contains("gemini") { return "google" }
        if id.contains("deepseek") { return "deepseek" }
        if id.contains("qwen") { return "alibaba-cn" }
        if id.contains("kimi") || id.contains("moonshot") { return "moonshotai-cn" }
        if id.contains("minimax") { return "minimax" }
        if id.contains("grok") { return "xai" }
        if id.contains("glm") || id.contains("zhipu") { return "zhipuai" }
        if id.contains("llama") { return "meta" }
        if id.contains("mistral") { return "mistral" }
        if id.contains("gpt") || id.contains("codex") || id.hasPrefix("o1") || id.hasPrefix("o3") || id.hasPrefix("o4") {
            return "openai"
        }
        return nil
    }

    private func normalizedModelId(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "models/", with: "")
    }

    private func modelKeys(_ value: String) -> Set<String> {
        var raw = normalizedModelId(value)
        var values = Set([raw])
        if let slash = raw.lastIndex(of: "/") {
            values.insert(String(raw[raw.index(after: slash)...]))
        }
        for marker in ["gemini", "claude", "gpt", "deepseek", "qwen", "kimi", "minimax", "grok", "glm", "llama"] {
            if let range = raw.range(of: marker), range.lowerBound != raw.startIndex {
                values.insert(String(raw[range.lowerBound...]))
            }
        }
        raw = stripSuffixes(raw)
        values.insert(raw)
        values.insert(raw.replacingOccurrences(of: ".", with: "-"))
        values.insert(raw.replacingOccurrences(of: "-", with: "."))
        return Set(values.filter { !$0.isEmpty })
    }

    private func stripSuffixes(_ value: String) -> String {
        var result = value
        let suffixes = ["-latest", "-agent", "-thinking", "-preview"]
        var changed = true
        while changed {
            changed = false
            for suffix in suffixes where result.hasSuffix(suffix) {
                result.removeLast(suffix.count)
                changed = true
                break
            }
        }
        return result
    }

    private func string(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func stringArray(_ value: Any?) -> [String] {
        (value as? [Any])?.compactMap(string) ?? []
    }

    private func firstPositiveInteger(_ row: [String: Any]?, keys: [String]) -> Int? {
        guard let row else { return nil }
        for key in keys {
            guard let number = row[key] as? NSNumber else { continue }
            let double = number.doubleValue
            let int = number.intValue
            guard double.isFinite, double > 0, Double(int) == double else { continue }
            return int
        }
        return nil
    }

    private func thinkingLevels(reasoning: Bool, options: Any?) -> [String] {
        guard reasoning else { return [] }
        var levels = Set<String>()
        if let options = options as? [[String: Any]] {
            for option in options {
                let type = string(option["type"])?.lowercased() ?? ""
                if type == "toggle" || type == "budget_tokens" {
                    levels.formUnion(["off", "medium"])
                }
                for value in option["values"] as? [Any] ?? [] {
                    let raw = string(value)?.lowercased()
                    if raw == "none" || raw == "off" {
                        levels.insert("off")
                    } else if modelThinkingLevelOrder.contains(raw ?? "") {
                        levels.insert(raw ?? "")
                    }
                }
            }
        }
        if levels.isEmpty {
            levels = ["low", "medium", "high"]
        }
        return modelThinkingLevelOrder.filter(levels.contains)
    }

    private func thinkingProtocol(providerKey: String, reasoning: Bool, options: Any?) -> String? {
        guard providerKey == "anthropic", reasoning,
              let options = options as? [[String: Any]]
        else { return nil }
        let types = options.compactMap { string($0["type"])?.lowercased() }
        return types.contains("effort") && !types.contains("budget_tokens") ? "adaptive" : nil
    }

}

/// Public projection used by the configuration screen.
public struct ModelsDevProfile: Equatable, Sendable {
    public var providerName: String
    public var modelId: String
    public var displayName: String
    public var contextWindow: Int?
    public var maxTokens: Int?
    public var thinkingLevels: [String]
    public var defaultThinkingLevel: String?
    public var supportsReasoningEffort: Bool?
    public var thinkingProtocol: String?
    public var supportsImages: Bool
    public var supportsDocuments: Bool

}

public enum ModelConfigurationResolver {
    public static func resolve(
        _ models: [DiscoveredModel],
        catalog: ModelsDevCatalog = .shared
    ) -> [ResolvedModelCandidate] {
        models.map { model in
            let match = catalog.match(modelId: model.modelId)
            let published = match?.profile
            let endpointHasCapacity = model.contextWindow != nil || model.maxTokens != nil
            let source: ModelMetadataSource
            if let match {
                source = .modelsDev(provider: match.providerKey)
            } else if endpointHasCapacity {
                source = .endpoint
            } else {
                source = .generic
            }
            let context = model.contextWindow
                ?? published?.contextWindow
                ?? ModelsDevCatalog.defaultContextWindow
            let maxTokens = model.maxTokens
                ?? published?.maxTokens
                ?? ModelsDevCatalog.defaultMaxTokens
            let levels: [String]
            if let endpointLevels = model.thinkingLevels {
                var merged = Set(endpointLevels)
                if !endpointLevels.isEmpty,
                   published?.thinkingLevels.contains("off") == true {
                    merged.insert("off")
                }
                levels = modelThinkingLevelOrder.filter(merged.contains)
            } else {
                levels = published?.thinkingLevels ?? []
            }
            let defaultLevel: String?
            if let endpointDefault = model.defaultThinkingLevel,
               levels.contains(endpointDefault) {
                defaultLevel = endpointDefault
            } else if let publishedDefault = published?.defaultThinkingLevel,
                      levels.contains(publishedDefault) {
                defaultLevel = publishedDefault
            } else if levels.contains("medium") {
                defaultLevel = "medium"
            } else {
                defaultLevel = levels.first
            }
            let alias = displayAlias(model.displayName, modelId: model.modelId)
            let spec = ProviderModelSpec(
                id: model.modelId,
                contextWindow: context,
                maxTokens: maxTokens,
                thinkingLevels: levels,
                defaultThinkingLevel: defaultLevel,
                alias: alias,
                thinkingProtocol: published?.thinkingProtocol,
                supportsReasoningEffort: published?.supportsReasoningEffort,
                supportsImages: published?.supportsImages,
                supportsDocuments: published?.supportsDocuments
            )
            return ResolvedModelCandidate(discovered: model, spec: spec, metadataSource: source)
        }
    }

    /// The upstream import parser accepts aliases only when they are trimmed,
    /// control-free text of at most 60 UTF-16 code units. Discovery metadata is
    /// untrusted, so keep a usable display name without making the form's
    /// default payload invalid.
    private static func displayAlias(_ displayName: String, modelId: String) -> String? {
        let sanitized = displayName.unicodeScalars.reduce(into: "") { result, scalar in
            if scalar.value <= 0x1F || scalar.value == 0x7F {
                result.append(" ")
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        let collapsed = sanitized
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !collapsed.isEmpty, collapsed != modelId else { return nil }

        var alias = ""
        var utf16Count = 0
        for character in collapsed {
            let width = String(character).utf16.count
            guard utf16Count + width <= ProviderVendorSchema.maxAliasLength else { break }
            alias.append(character)
            utf16Count += width
        }
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == modelId ? nil : trimmed
    }
}
