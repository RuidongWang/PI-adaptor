import Foundation

// MARK: - 派生视图的数据源

/// 一个模型记录（契约 §4.8.4 的 `ModelRecord`）。
///
/// 用 **class** 而不是 struct 是契约要求的：分组结果里的 `models` 元素必须是**原对象引用**，
/// 不产生副本字段，调用方可直接用 `===` 断言引用不变（§4.8.5 不变量 4）。
public final class ModelRecord: Equatable, Sendable {
    public let providerId: String?
    public let modelId: String
    public let alias: String?
    public let contextWindow: Int?
    public let maxTokens: Int?
    public let thinkingLevels: [String]
    public let defaultThinkingLevel: String?
    /// 会话当前绑定的默认模型（用于「含默认模型的组置顶」）。
    public let isDefault: Bool

    public init(
        providerId: String?,
        modelId: String,
        alias: String? = nil,
        contextWindow: Int? = nil,
        maxTokens: Int? = nil,
        thinkingLevels: [String] = [],
        defaultThinkingLevel: String? = nil,
        isDefault: Bool = false
    ) {
        self.providerId = providerId
        self.modelId = modelId
        self.alias = alias
        self.contextWindow = contextWindow
        self.maxTokens = maxTokens
        self.thinkingLevels = thinkingLevels
        self.defaultThinkingLevel = defaultThinkingLevel
        self.isDefault = isDefault
    }

    /// 展示名：有 alias 用 alias，否则用 modelId。
    public var displayName: String { alias ?? modelId }

    /// 组内顺序与引用都由对象身份决定，因此相等性按引用判定。
    public static func == (lhs: ModelRecord, rhs: ModelRecord) -> Bool {
        lhs === rhs
    }
}

/// 一条 provider 记录（客户端本地记录，契约 §4.8.1）。
/// `providerId` 来自 `provider-import` 回执；`nil` 表示尚未确认（例如 `import_incomplete` 的残留）。
public struct ProviderRecord: Equatable, Sendable {
    public var providerId: String?
    public var name: String
    public var models: [ModelRecord]

    public init(providerId: String?, name: String, models: [ModelRecord]) {
        self.providerId = providerId
        self.name = name
        self.models = models
    }
}

// MARK: - 派生结果

/// 分组结果（契约 §4.8.4）。
public struct ProviderModelGroup: Equatable, Sendable {
    /// `nil` = 「未确认」组（记录没有 `providerId`），固定排在最后。
    public let providerId: String?
    /// 已消歧的显示名（同名 provider 追加 `providerId` 末 6 位）。
    public let name: String
    public let isDefaultGroup: Bool
    /// 原对象引用，不复制、不重写字段。
    public let models: [ModelRecord]

    public init(providerId: String?, name: String, isDefaultGroup: Bool, models: [ModelRecord]) {
        self.providerId = providerId
        self.name = name
        self.isDefaultGroup = isDefaultGroup
        self.models = models
    }

    public var isUnconfirmed: Bool { providerId == nil }
}

/// `duplicate-model` 诊断：同组内重复 `modelId` 只保留首条并上报，不阻塞导入（契约 §4.8.3）。
public struct ModelGroupingDiagnostic: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case duplicateModel = "duplicate-model"
    }

    public let kind: Kind
    public let providerId: String?
    public let modelId: String

    public init(kind: Kind, providerId: String?, modelId: String) {
        self.kind = kind
        self.providerId = providerId
        self.modelId = modelId
    }

    public var message: String {
        switch kind {
        case .duplicateModel:
            return "provider \(providerId ?? "未确认") 内模型 id「\(modelId)」重复，已保留首次出现的那条"
        }
    }
}

/// 分组结果 + 诊断。
public struct ModelGroupingResult: Equatable, Sendable {
    public let groups: [ProviderModelGroup]
    public let diagnostics: [ModelGroupingDiagnostic]

    public init(groups: [ProviderModelGroup], diagnostics: [ModelGroupingDiagnostic]) {
        self.groups = groups
        self.diagnostics = diagnostics
    }
}

// MARK: - 分组

/// 「未确认」组的标题（契约 §4.8.1：无 `providerId` 的记录归入该标题，但**每条记录各自成桶**）。
public let unconfirmedProviderGroupName = "未确认"

/// provider 名为空时的稳定回退标题（同名时仍按 §4.8.5 追加 `providerId` 末 6 位消歧）。
public let unnamedProviderGroupName = "未命名服务"

/// 按 `providerId` 分组（契约 §4.8.1 ~ §4.8.4；spec AC-05.4 ~ AC-05.6）。
///
/// 规则：
/// - 分组键是 `providerId`，不是 `name`（名称可重复）；
/// - `models` 为空的 provider 不渲染；
/// - 无 `providerId` 的记录**每条各自成桶**（同一 `modelId` 不跨「未确认」记录去重），
///   标题统一显示「未确认」，固定排最后；
/// - 组顺序：含默认模型的组置顶 → 其余按 `name`（zh）→ 再按 `providerId`；
/// - 组内按声明顺序，`modelId` 去重保首次并上报 `duplicate-model`；跨组不去重。
public func groupModelsByProvider(_ providers: [ProviderRecord]) -> [ProviderModelGroup] {
    groupModelsByProviderDetailed(providers).groups
}

/// 同 `groupModelsByProvider`，但额外返回 `duplicate-model` 诊断。
public func groupModelsByProviderDetailed(_ providers: [ProviderRecord]) -> ModelGroupingResult {
    var order: [ProviderBucketKey] = []
    var buckets: [ProviderBucketKey: Bucket] = [:]
    var diagnostics: [ModelGroupingDiagnostic] = []

    for (index, provider) in providers.enumerated() {
        // AC-05.5：未确认记录（`providerId == nil`）按记录下标各自成桶，
        // 否则不同「未确认」provider 之间的同一 `modelId` 会被跨 provider 去重。
        let key: ProviderBucketKey = provider.providerId.map { .confirmed($0) } ?? .unconfirmed(index)
        // 纯空白名称等同空名称：否则组标题会渲染成一片空白。
        let trimmedName = provider.name.trimmingCharacters(in: .whitespacesAndNewlines)
        var bucket: Bucket
        if let existing = buckets[key] {
            bucket = existing
        } else {
            bucket = Bucket(providerId: provider.providerId, name: trimmedName, models: [], seenModelIds: [])
            order.append(key)
        }

        if bucket.name.isEmpty, !trimmedName.isEmpty {
            bucket.name = trimmedName
        }

        var seen = Set(bucket.seenModelIds)
        for model in provider.models {
            if seen.contains(model.modelId) {
                diagnostics.append(
                    ModelGroupingDiagnostic(kind: .duplicateModel, providerId: provider.providerId, modelId: model.modelId)
                )
                continue
            }
            seen.insert(model.modelId)
            bucket.models.append(model)
            bucket.seenModelIds.append(model.modelId)
        }
        buckets[key] = bucket
    }

    // 空 models 的 provider 不渲染。
    let rendered = order.compactMap { buckets[$0] }.filter { !$0.models.isEmpty }

    // 标题：同名 provider 追加 providerId 末 6 位，并对最终标题集合做不动点判定
    // （契约 §4.8.5 不变量 2：对结果再分组一次必须不变）。
    let displayNames = resolvedDisplayNames(for: rendered)
    let groups: [ProviderModelGroup] = zip(rendered, displayNames).map { bucket, displayName in
        ProviderModelGroup(
            providerId: bucket.providerId,
            name: displayName,
            isDefaultGroup: bucket.models.contains(where: \.isDefault),
            models: bucket.models
        )
    }

    return ModelGroupingResult(groups: sortedGroups(groups), diagnostics: diagnostics)
}

/// 把分组结果摊平成模型列表；元素身份与原记录一致（契约 §4.8.4）。
public func flatten(_ groups: [ProviderModelGroup]) -> [ModelRecord] {
    groups.flatMap(\.models)
}

// MARK: - 排序与消歧

/// 分组键：已确认记录按 `providerId`；未确认记录按记录下标各自成桶。
private enum ProviderBucketKey: Hashable {
    case confirmed(String)
    case unconfirmed(Int)
}

private struct Bucket {
    let providerId: String?
    var name: String
    var models: [ModelRecord]
    var seenModelIds: [String]
}

private let zhLocale = Locale(identifier: "zh_Hans_CN")

private func zhCompare(_ lhs: String, _ rhs: String) -> ComparisonResult {
    lhs.compare(rhs, options: [], range: nil, locale: zhLocale)
}

private func disambiguated(name: String, providerId: String?) -> String {
    guard let providerId, !providerId.isEmpty else { return name }
    let suffix = String(providerId.suffix(6))
    // 已带同一后缀时不再追加：保证对结果再分组一次仍然幂等（§4.8.5 不变量 2）。
    if name.hasSuffix(" · \(suffix)") { return name }
    return "\(name) · \(suffix)"
}

/// 按「最终标题集合」计算显示名，直到再分组不再变化。
///
/// 只做一轮「按原始名称计数加后缀」不幂等：两个同名 `X` 的 provider 加上一个名称
/// 字面量正好是 `X · aaa111` 的 provider 时，首轮会产出两个同名标题，再分组一次又会
/// 继续追加后缀。这里从当前标题出发反复施加同一条规则，取不动点；每轮至少有一个桶
/// 追加后缀，而一个桶最多追加一次（追加后已带自己的后缀），故循环次数上界是桶数 + 1。
///
/// 「未确认」桶的标题固定为 `unconfirmedProviderGroupName`，其原始 `name` 不参与同名
/// 计数（否则同名计数会被未确认记录抬高，正常 provider 被无谓加后缀）。
private func resolvedDisplayNames(for buckets: [Bucket]) -> [String] {
    let unconfirmedCount = buckets.filter { $0.providerId == nil }.count
    var unconfirmedSeen = 0
    var names = buckets.map { bucket -> String in
        guard bucket.providerId != nil else {
            unconfirmedSeen += 1
            // 单条残留沿用契约口径的「未确认」；多条时各自成桶，标题必须可区分——
            // 否则面板上会出现两个同名组，用户无法判断自己在看/删哪一条。
            guard unconfirmedCount > 1 else { return unconfirmedProviderGroupName }
            let label = bucket.name.isEmpty ? "记录 \(unconfirmedSeen)" : "\(bucket.name) · \(unconfirmedSeen)"
            return "\(unconfirmedProviderGroupName) · \(label)"
        }
        return bucket.name.isEmpty ? unnamedProviderGroupName : bucket.name
    }

    for _ in 0...buckets.count {
        var counts: [String: Int] = [:]
        for (bucket, name) in zip(buckets, names) where bucket.providerId != nil {
            counts[name, default: 0] += 1
        }
        var next = names
        for (index, bucket) in buckets.enumerated() where bucket.providerId != nil {
            if (counts[names[index]] ?? 0) > 1 {
                next[index] = disambiguated(name: names[index], providerId: bucket.providerId)
            }
        }
        if next == names { return names }
        names = next
    }
    return names
}

/// 组顺序：默认组置顶 → 名称（zh）→ providerId；「未确认」组恒排最后；
/// 末位用输入下标兜底，保证同一输入两次调用顺序完全一致（§4.8.5 不变量 3）。
private func sortedGroups(_ groups: [ProviderModelGroup]) -> [ProviderModelGroup] {
    groups.enumerated()
        .sorted { lhs, rhs in
            if lhs.element.isDefaultGroup != rhs.element.isDefaultGroup {
                return lhs.element.isDefaultGroup
            }
            if lhs.element.isUnconfirmed != rhs.element.isUnconfirmed {
                return !lhs.element.isUnconfirmed
            }
            let comparison = zhCompare(lhs.element.name, rhs.element.name)
            if comparison != .orderedSame {
                return comparison == .orderedAscending
            }
            let lhsId = lhs.element.providerId ?? ""
            let rhsId = rhs.element.providerId ?? ""
            if lhsId != rhsId {
                return lhsId < rhsId
            }
            return lhs.offset < rhs.offset
        }
        .map(\.element)
}
