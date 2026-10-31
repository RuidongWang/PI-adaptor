import CryptoKit
import SwiftUI
import PIiOSCore
import PIiOSNet

/// Settings → Models. Discovery and import run through the existing SSH
/// connection so the API key never leaves the encrypted SSH transport from the
/// phone's perspective.
struct ModelsScreen: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var connection: ConnectionModel

    @State private var serviceName = ""
    @State private var baseURL = ""
    @State private var apiKey = ""
    @State private var filter = ""
    @State private var modelDrafts: [EditableModelDraft] = []
    @State private var selectedDraftIDs = Set<UUID>()
    @State private var isFetching = false
    @State private var isImporting = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var selectedProvider: StoredModelProvider?
    @State private var authPreset: ProviderAuthPreset = .apiKey
    @State private var servicePreset: ProviderServicePreset = .openAICompatible
    @State private var discoveryFingerprint: String?
    @State private var discoveryOperation: ProviderOperationContext?
    @State private var discoveryRequestID: UUID?

    private enum ProviderAuthPreset: String, CaseIterable, Identifiable {
        case apiKey = "API Key + Base URL"
        case subscription = "订阅账号登录"

        var id: String { rawValue }
    }

    private enum ProviderServicePreset: String, CaseIterable, Identifiable {
        case openAICompatible = "OpenAI-Compatible"
        case deepSeek = "DeepSeek 官方"

        var id: String { rawValue }

        var defaultServiceName: String {
            switch self {
            case .openAICompatible: ""
            case .deepSeek: "DeepSeek"
            }
        }

        var defaultBaseURL: String {
            switch self {
            case .openAICompatible: ""
            case .deepSeek: "https://api.deepseek.com"
            }
        }

        var vendorKey: String {
            switch self {
            case .openAICompatible: "custom"
            case .deepSeek: "deepseek"
            }
        }
    }

    private var currentHost: HostRecord? { model.currentHost }

    private struct EditableModelDraft: Identifiable, Equatable {
        let id = UUID()
        var source: ResolvedModelCandidate
        var modelId: String
        var displayName: String
        var contextWindow: String
        var maxTokens: String
        var thinkingLevels: String
        var defaultThinkingLevel: String

        init(candidate: ResolvedModelCandidate) {
            source = candidate
            modelId = candidate.spec.id
            displayName = candidate.spec.alias ?? candidate.discovered.displayName
            contextWindow = String(candidate.spec.contextWindow)
            maxTokens = String(candidate.spec.maxTokens)
            thinkingLevels = candidate.spec.thinkingLevels.joined(separator: ", ")
            defaultThinkingLevel = candidate.spec.defaultThinkingLevel ?? ""
        }

        var editedSpec: ProviderModelSpec {
            ProviderImportComposer.modelSpec(from: ProviderModelDraftInput(
                base: source.spec,
                modelId: modelId,
                displayName: displayName,
                contextWindow: contextWindow,
                maxTokens: maxTokens,
                thinkingLevels: thinkingLevels,
                defaultThinkingLevel: defaultThinkingLevel
            ))
        }
    }

    private var visibleDrafts: [EditableModelDraft] {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return modelDrafts }
        return modelDrafts.filter {
            $0.modelId.lowercased().contains(query)
                || $0.displayName.lowercased().contains(query)
        }
    }

    private var selectedDrafts: [EditableModelDraft] {
        modelDrafts.filter { selectedDraftIDs.contains($0.id) }
    }

    private var configurationFingerprint: String {
        let fields = [ECMAScriptString.trim(baseURL), ECMAScriptString.trim(apiKey)]
        let data = fields.map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(data.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func invalidateDiscovery() {
        discoveryFingerprint = nil
        discoveryOperation = nil
        discoveryRequestID = nil
        modelDrafts = []
        selectedDraftIDs = []
        isFetching = false
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PISpacing.s24) {
                status
                configuredProviders
                addService
                if !modelDrafts.isEmpty {
                    discoveredModels
                }
            }
            .padding(.horizontal, PIMetrics.pageMargin)
            .padding(.top, PISpacing.s16)
            .padding(.bottom, PISpacing.s32)
        }
        .piPageBackground()
        .piDetailNavBar("模型服务")
        .onChange(of: configurationFingerprint) { _, _ in invalidateDiscovery() }
        .onChange(of: currentHost.flatMap { model.providerOperationContext(for: $0) }) { _, _ in
            invalidateDiscovery()
        }
        .onChange(of: authPreset) { _, _ in invalidateDiscovery() }
        .onChange(of: servicePreset) { _, preset in
            serviceName = preset.defaultServiceName
            baseURL = preset.defaultBaseURL
            apiKey = ""
            invalidateDiscovery()
        }
        .sheet(isPresented: Binding(
            get: { selectedProvider != nil },
            set: { if !$0 { selectedProvider = nil } }
        )) {
            if let provider = selectedProvider, let host = currentHost, provider.hostID == host.id {
                ModelProviderDetailSheet(
                    provider: provider,
                    host: host,
                    onDeleted: { notice in
                        switch notice {
                        case .success(let message):
                            errorMessage = nil
                            statusMessage = message
                        case .needsAttention(let message):
                            // Keep the warning visible after the sheet closes; a
                            // generic "已删除" would hide the required follow-up.
                            statusMessage = nil
                            errorMessage = message
                        }
                        selectedProvider = nil
                    }
                )
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        if isFetching {
            PIStatusBanner(kind: .info, text: "正在获取模型", detail: "请求由服务器发出，API Key 通过 SSH stdin 传递。")
        } else if isImporting {
            PIStatusBanner(kind: .info, text: "正在导入模型服务", detail: "正在调用服务器上的 provider-import。")
        } else if let errorMessage {
            PIStatusBanner(
                kind: .danger,
                text: "模型配置未完成",
                detail: errorMessage,
                actionTitle: "知道了",
                action: { self.errorMessage = nil }
            )
        } else if let statusMessage {
            PIStatusBanner(
                kind: .success,
                text: "模型配置",
                detail: statusMessage,
                actionTitle: "知道了",
                action: { self.statusMessage = nil }
            )
        } else {
            PIStatusBanner(
                kind: .info,
                text: "自动匹配标准配置",
                detail: "先读取服务自己的 /models，再按完整模型 ID 使用 models.dev 补全上下文、输出上限、思考档位与图片/PDF 能力。"
            )
        }
    }

    private var configuredProviders: some View {
        PIGroup(
            "本机模型清单",
            footer: "清单只保存 providerId、模型与标准参数，不保存 API Key。点一条服务可查看详情并删除。"
        ) {
            if model.currentModelProviders.isEmpty {
                PIListRow(
                    title: "尚未导入模型服务",
                    subtitle: "使用下方表单从模型服务读取模型",
                    isEnabled: false,
                    showsDivider: false
                )
            } else {
                ForEach(Array(model.currentModelProviders.enumerated()), id: \.element.id) { index, provider in
                    PIListRow(
                        title: provider.name,
                        subtitle: "\(provider.models.count) 个模型 · \(provider.baseURL)",
                        value: provider.defaultModelId.flatMap { id in
                            provider.models.first(where: { $0.id == id })?.displayName
                        },
                        isEnabled: true,
                        showsChevron: true,
                        showsDivider: index != model.currentModelProviders.count - 1,
                        action: { selectedProvider = provider }
                    )
                }
            }
        }
    }

    private var addService: some View {
        PIGroup(
            "添加模型服务",
            footer: "Base URL 填写模型请求根地址；发现接口会自动追加 /models。DeepSeek 官方预设使用 https://api.deepseek.com。"
        ) {
            VStack(alignment: .leading, spacing: PISpacing.s16) {
                PIFormField(label: "服务预设", hint: "选择官方服务会自动填入 Base URL") {
                    Picker("服务预设", selection: $servicePreset) {
                        ForEach(ProviderServicePreset.allCases) { preset in
                            Text(preset.rawValue).tag(preset)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("models.servicePreset")
                }
                PIFormField(label: "服务名称", hint: "用于模型选择器分组") {
                    TextField("Antigravity", text: $serviceName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("models.serviceName")
                }
                PIFormField(label: "认证方式", hint: "订阅账号型 provider 不在当前版本支持范围内") {
                    Picker("认证方式", selection: $authPreset) {
                        ForEach(ProviderAuthPreset.allCases) { preset in
                            Text(preset.rawValue).tag(preset)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("models.authPreset")
                }
                if authPreset == .subscription {
                    Text("暂不支持订阅账号登录；不会发起 OAuth 或访问账号授权页面。")
                        .font(PIFont.caption)
                        .foregroundStyle(PIColor.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                PIFormField(label: "Base URL", hint: "服务器必须能访问该地址") {
                    TextField("http://203.0.113.10:8080/antigravity", text: $baseURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(authPreset != .apiKey)
                        .accessibilityIdentifier("models.baseURL")
                }
                PIFormField(label: "API Key", hint: "只进入内存并经 SSH stdin 发送；不写入本机状态文件") {
                    SecureField("API Key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(authPreset != .apiKey)
                        .accessibilityIdentifier("models.apiKey")
                }
                PIPrimaryButton(title: isFetching ? "正在获取…" : "获取模型") {
                    fetchModels()
                }
                .disabled(
                    isFetching
                        || isImporting
                        || authPreset != .apiKey
                        || currentHost == nil
                        || apiKey.isEmpty
                )
                if currentHost == nil {
                    Text("先在设置 → 服务器中添加并连接服务器。")
                        .font(PIFont.caption)
                        .foregroundStyle(PIColor.text3)
                }
            }
            .padding(.horizontal, PISpacing.s16)
            .padding(.vertical, PISpacing.s12)
        }
    }

    private var discoveredModels: some View {
        PIGroup(
            "可用模型（\(modelDrafts.count)）",
            footer: "已选 \(selectedDraftIDs.count) 个。可逐条编辑模型参数；默认模型取列表中第一个选中项。"
        ) {
            VStack(alignment: .leading, spacing: PISpacing.s12) {
                TextField("搜索模型 ID 或名称", text: $filter)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("全选当前结果") {
                        selectedDraftIDs.formUnion(visibleDrafts.map(\.id))
                    }
                    .buttonStyle(.borderless)
                    Button("取消当前结果") {
                        selectedDraftIDs.subtract(visibleDrafts.map(\.id))
                    }
                    .buttonStyle(.borderless)
                    Spacer()
                }
                .font(PIFont.caption)

                ForEach(visibleDrafts) { draft in
                    modelRow(draft)
                    if draft.id != visibleDrafts.last?.id {
                        Divider()
                    }
                }

                PIPrimaryButton(title: isImporting ? "正在导入…" : "导入 \(selectedDraftIDs.count) 个模型") {
                    importModels()
                }
                .disabled(isImporting || isFetching || selectedDraftIDs.isEmpty || apiKey.isEmpty)
            }
            .padding(.horizontal, PISpacing.s16)
            .padding(.vertical, PISpacing.s12)
        }
    }

    private func modelRow(_ draft: EditableModelDraft) -> some View {
        let binding = draftBinding(for: draft.id)
        return VStack(alignment: .leading, spacing: PISpacing.s8) {
            Toggle(isOn: Binding(
                get: { selectedDraftIDs.contains(draft.id) },
                set: { enabled in
                    if enabled {
                        selectedDraftIDs.insert(draft.id)
                    } else {
                        selectedDraftIDs.remove(draft.id)
                    }
                }
            )) {
                VStack(alignment: .leading, spacing: PISpacing.s4) {
                    Text(draft.displayName.isEmpty ? draft.modelId : draft.displayName)
                        .font(PIFont.listTitle)
                        .foregroundStyle(PIColor.text)
                    Text(draft.modelId)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(PIColor.text2)
                    Text(summary(draft))
                        .font(PIFont.metaSmall)
                        .foregroundStyle(PIColor.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(PIColor.accent)

            if selectedDraftIDs.contains(draft.id) {
                DisclosureGroup("编辑模型参数") {
                    VStack(alignment: .leading, spacing: PISpacing.s8) {
                        TextField("模型 ID", text: binding.modelId)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textFieldStyle(.roundedBorder)
                        TextField("显示名称", text: binding.displayName)
                            .textFieldStyle(.roundedBorder)
                        HStack {
                            TextField("上下文上限", text: binding.contextWindow)
                                .keyboardType(.numberPad)
                                .textFieldStyle(.roundedBorder)
                            TextField("输出上限", text: binding.maxTokens)
                                .keyboardType(.numberPad)
                                .textFieldStyle(.roundedBorder)
                        }
                        TextField("思考档位，用逗号分隔", text: binding.thinkingLevels)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textFieldStyle(.roundedBorder)
                        TextField("默认档位（可留空）", text: binding.defaultThinkingLevel)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textFieldStyle(.roundedBorder)
                    }
                    .padding(.top, PISpacing.s8)
                }
                .font(PIFont.caption)
            }
        }
    }

    private func draftBinding(for id: UUID) -> Binding<EditableModelDraft> {
        Binding(
            get: {
                modelDrafts.first(where: { $0.id == id })
                    ?? EditableModelDraft(candidate: placeholderCandidate)
            },
            set: { updated in
                guard let index = modelDrafts.firstIndex(where: { $0.id == id }) else { return }
                modelDrafts[index] = updated
            }
        )
    }

    private var placeholderCandidate: ResolvedModelCandidate {
        ResolvedModelCandidate(
            discovered: DiscoveredModel(modelId: "", displayName: ""),
            spec: ProviderModelSpec(
                id: "",
                contextWindow: -1,
                maxTokens: -1,
                thinkingLevels: []
            ),
            metadataSource: .generic
        )
    }

    private func summary(_ draft: EditableModelDraft) -> String {
        let spec = draft.editedSpec
        var parts = [
            "\(compactTokens(spec.contextWindow)) ctx",
            "\(compactTokens(spec.maxTokens)) output",
        ]
        if !spec.thinkingLevels.isEmpty {
            parts.append("思考 \(spec.thinkingLevels.joined(separator: "/"))")
        }
        if spec.supportsImages == true { parts.append("图片") }
        if spec.supportsDocuments == true { parts.append("PDF") }
        switch draft.source.metadataSource {
        case .modelsDev(let provider):
            parts.append("models.dev · \(provider)")
        case .endpoint:
            parts.append("服务端容量")
        case .generic:
            parts.append("通用默认值")
        }
        return parts.joined(separator: " · ")
    }

    private func compactTokens(_ value: Int) -> String {
        if value >= 1_000_000, value % 1_000_000 == 0 { return "\(value / 1_000_000)M" }
        if value >= 1_000, value % 1_000 == 0 { return "\(value / 1_000)K" }
        return String(value)
    }

    private func fetchModels() {
        guard authPreset == .apiKey else {
            errorMessage = "暂不支持订阅账号登录，未发起任何 OAuth 请求"
            return
        }
        guard let host = currentHost,
              let operation = model.providerOperationContext(for: host) else { return }
        let normalizedBaseURL = ECMAScriptString.trim(baseURL)
        let validation = EndpointPolicy.validate(baseUrl: normalizedBaseURL, vendorKey: "custom")
        guard validation.isValid else {
            errorMessage = validation.displayReason
            return
        }
        let normalizedAPIKey = ECMAScriptString.trim(apiKey)
        guard !normalizedAPIKey.isEmpty else {
            errorMessage = "请填写 API Key"
            return
        }
        invalidateDiscovery()
        let requestID = UUID()
        let fingerprint = configurationFingerprint
        discoveryRequestID = requestID
        isFetching = true
        statusMessage = nil
        errorMessage = nil
        Task {
            do {
                let discovered = try await connection.discoverModels(
                    record: host,
                    baseURL: normalizedBaseURL,
                    apiKey: normalizedAPIKey
                )
                let normalizedModels = discovered.map { discovered in
                    var model = discovered
                    model.modelId = ECMAScriptString.trim(model.modelId)
                    return model
                }
                let resolved = ModelConfigurationResolver.resolve(normalizedModels)
                await MainActor.run {
                    guard discoveryRequestID == requestID else { return }
                    guard model.canApplyProviderOperation(operation),
                          configurationFingerprint == fingerprint else {
                        isFetching = false
                        return
                    }
                    discoveryFingerprint = fingerprint
                    discoveryOperation = operation
                    modelDrafts = resolved.map(EditableModelDraft.init(candidate:))
                    selectedDraftIDs = Set(modelDrafts.map(\.id))
                    if ECMAScriptString.trim(serviceName).isEmpty {
                        serviceName = ProviderImportComposer.defaultServiceName(for: normalizedBaseURL)
                    }
                    statusMessage = "已获取 \(resolved.count) 个模型"
                    isFetching = false
                }
            } catch {
                await MainActor.run {
                    guard discoveryRequestID == requestID else { return }
                    isFetching = false
                    guard model.canApplyProviderOperation(operation),
                          configurationFingerprint == fingerprint else { return }
                    errorMessage = ConnectionErrorText.describe(error)
                }
            }
        }
    }

    private func importModels() {
        guard authPreset == .apiKey else {
            errorMessage = "暂不支持订阅账号登录，未发起任何 OAuth 请求"
            return
        }
        guard let host = currentHost,
              let operation = model.providerOperationContext(for: host) else { return }
        guard discoveryFingerprint == configurationFingerprint,
              discoveryOperation == operation else {
            invalidateDiscovery()
            errorMessage = "服务配置已变化，请重新获取模型"
            return
        }
        let normalizedBaseURL = ECMAScriptString.trim(baseURL)
        let validation = EndpointPolicy.validate(baseUrl: normalizedBaseURL, vendorKey: "custom")
        guard validation.isValid else {
            errorMessage = validation.displayReason
            return
        }
        let selected = selectedDrafts
        guard !selected.isEmpty else {
            errorMessage = "请至少选择一个模型"
            return
        }
        let normalizedAPIKey = ECMAScriptString.trim(apiKey)
        guard !normalizedAPIKey.isEmpty else {
            errorMessage = "请填写 API Key"
            return
        }
        let selectedSpecs = selected.map(\.editedSpec)
        let isFirstProvider = model.currentModelProviders.isEmpty
        let composition = ProviderImportComposer.compose(
            serviceName: serviceName,
            baseURL: normalizedBaseURL,
            apiKey: normalizedAPIKey,
            models: selectedSpecs,
            setDefaultModel: isFirstProvider,
            vendorKey: servicePreset.vendorKey
        )
        guard composition.isValid else {
            errorMessage = composition.issues.map(\.description).joined(separator: "\n")
            return
        }
        let input = composition.input
        let payload = composition.payload
        let importFingerprint = configurationFingerprint
        guard let data = try? ProviderImportEncoder.encode(payload) else {
            errorMessage = "无法编码 provider-import 载荷"
            return
        }

        isImporting = true
        statusMessage = nil
        errorMessage = nil
        Task {
            do {
                let receipt = try await connection.importProvider(record: host, payload: data)
                let sourceId = payload.providers[0].sourceId
                // The v2 Host resolves a session's provider only from its own
                // store, but this import lands in the legacy SSH store. Mirror it
                // into the Host store and record the Host-side id so the model a
                // user picks here can actually run a turn.
                var effectiveProviderId: String?
                var legacyProviderId: String?
                var mirroredToV2 = false
                if case .success(let success) = receipt,
                   case .imported(let legacyId) = success.outcome(forSourceId: sourceId) {
                    legacyProviderId = legacyId
                    effectiveProviderId = legacyId
                    // Only mirror while the import still applies to the host the
                    // caller started on; switching hosts mid-import must not
                    // create the provider (and its secret) somewhere else.
                    if model.canApplyProviderOperation(operation),
                       let mirrored = try? await connection.registerHostProvider(
                        name: input.name,
                        vendorKey: "imported-\(UUID().uuidString)",
                        baseURL: input.baseUrl ?? "",
                        apiKey: normalizedAPIKey,
                        models: input.models
                       ) {
                        effectiveProviderId = mirrored.id
                        mirroredToV2 = true
                    }
                }
                await MainActor.run {
                    isImporting = false
                    guard model.canApplyProviderOperation(operation) else { return }
                    switch receipt {
                    case .success(let success):
                        switch success.outcome(forSourceId: sourceId) {
                        case .imported(let providerId):
                            guard model.recordImportedProvider(
                                context: operation,
                                input: input,
                                providerId: effectiveProviderId ?? providerId,
                                serverDefaultSet: success.defaultSet,
                                legacyProviderId: legacyProviderId,
                                hostV2Mirror: mirroredToV2
                            ) else { return }
                            // Keep the key locally (Keychain only) so this provider
                            // can be mirrored into the v2 store or re-imported later
                            // without the user retyping it.
                            _ = KeychainStore.saveProviderKey(
                                normalizedAPIKey,
                                hostID: operation.hostID,
                                providerId: effectiveProviderId ?? providerId
                            )
                            if configurationFingerprint == importFingerprint {
                                apiKey = ""
                            }
                            statusMessage = "已导入 \(input.models.count) 个模型"
                            if isFirstProvider, success.defaultSet, let firstModel = input.models.first {
                                statusMessage = "已导入 \(input.models.count) 个模型，默认模型为 \(firstModel.alias ?? firstModel.id)"
                            }
                            if !mirroredToV2 {
                                // The v2 Host resolves a session's model only from
                                // its own store, so a non-mirrored import is not
                                // runnable yet — say so instead of implying success.
                                errorMessage = connection.state.isOnline
                                    ? "已导入到服务器，但未能写入 PI-adaptor 的 provider 存储；该模型暂时无法使用，请重试导入。"
                                    : "已导入到服务器，但隧道未连接，未同步到 PI-adaptor；请连接后重新导入，否则该模型无法使用。"
                            }
                        case .skipped(let reason):
                            errorMessage = "模型服务已被服务器跳过：\(reason.clientGuidance)"
                        case .missing:
                            errorMessage = "服务器回执里没有这个模型的导入结果"
                        }
                    case .failure(let failure):
                        errorMessage = "导入失败：\(failure.displayMessage)"
                    case .unparseable(let reason):
                        errorMessage = "服务器回执无法解析：\(reason)"
                    }
                }
            } catch {
                await MainActor.run {
                    isImporting = false
                    guard model.canApplyProviderOperation(operation) else { return }
                    errorMessage = ConnectionErrorText.describe(error)
                }
            }
        }
    }

}
