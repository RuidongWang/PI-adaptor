import SwiftUI
import PIiOSCore

struct HostProvidersScreen: View {
    @EnvironmentObject private var connection: ConnectionModel
    @EnvironmentObject private var model: AppModel

    @State private var providers: [RACPV2Provider] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var name = ""
    @State private var baseURL = ""
    @State private var apiKey = ""
    @State private var modelID = ""
    @State private var pendingDelete: RACPV2Provider?
    @State private var editingProvider: RACPV2Provider?
    @State private var editName = ""
    @State private var editBaseURL = ""
    @State private var editApiKey = ""
    @State private var editModelID = ""
    @State private var isCreating = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PISpacing.s16) {
                if !connection.state.isOnline {
                    PIStatusBanner(kind: .warning, text: "Host 未连接", detail: "连接后可管理服务器 provider。")
                }
                if let error {
                    PIStatusBanner(kind: .danger, text: "Provider 操作失败", detail: error)
                }
                PIGroup("服务器 provider", footer: "API Key 只写入 Host；本机不保存明文。") {
                    if isLoading {
                        PIListRow(title: "正在读取…", isEnabled: false, showsDivider: false)
                    } else if providers.isEmpty {
                        PIListRow(title: "还没有 provider", isEnabled: false, showsDivider: false)
                    } else {
                        ForEach(Array(providers.enumerated()), id: \.element.id) { index, provider in
                            PIListRow(
                                title: provider.name,
                                subtitle: "\(provider.baseUrl) · \(provider.models.count) 个模型 · \(provider.apiKeyMask ?? "无密钥")",
                                showsDivider: index < providers.count - 1
                            ) {
                                HStack(spacing: PISpacing.s8) {
                                    Button("编辑") { startEditing(provider) }
                                        .font(PIFont.captionStrong)
                                    Button("删除", role: .destructive) { pendingDelete = provider }
                                        .font(PIFont.captionStrong)
                                }
                            }
                        }
                    }
                }
                PIGroup("新增 provider") {
                    PIFormField(label: "名称") {
                        TextField("DeepSeek", text: $name)
                    }
                    PIFormField(label: "Base URL") {
                        TextField("https://api.example.com/v1", text: $baseURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    PIFormField(label: "API Key") {
                        SecureField("sk-…", text: $apiKey)
                    }
                    PIFormField(label: "模型 ID") {
                        TextField("deepseek-chat", text: $modelID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    Button("保存到 Host") { Task { await create() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(isCreating || !connection.state.isOnline || name.isEmpty || baseURL.isEmpty || apiKey.isEmpty || modelID.isEmpty)
                }
            }
            .padding(.horizontal, PIMetrics.pageMargin)
            .padding(.vertical, PISpacing.s16)
        }
        .piPageBackground()
        .navigationTitle("Host Provider")
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .refreshable { await reload() }
        .onChange(of: model.currentHost?.id) { _ in
            Task { await reload() }
        }
        .confirmationDialog(
            "删除 provider？",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let provider = pendingDelete { Task { await delete(provider) } }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将从 Host 清除该 provider 与密钥；不会自动把默认项切到其他 provider。")
        }
        .sheet(item: $editingProvider) { provider in
            NavigationStack {
                Form {
                    Section("Provider 配置") {
                        TextField("名称", text: $editName)
                        TextField("Base URL", text: $editBaseURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("新 API Key（留空保持不变）", text: $editApiKey)
                        TextField("模型 ID", text: $editModelID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }
                .navigationTitle("编辑 Provider")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { editingProvider = nil }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") { Task { await saveEdit(id: provider.id) } }
                            .disabled(editName.isEmpty || editBaseURL.isEmpty || editModelID.isEmpty)
                    }
                }
            }
        }
    }

    private func startEditing(_ provider: RACPV2Provider) {
        editName = provider.name
        editBaseURL = provider.baseUrl
        editApiKey = ""
        editModelID = provider.models.first?.id ?? ""
        editingProvider = provider
    }

    private func saveEdit(id: String) async {
        // Bind the request to the Host it was started on: the network call goes
        // through the live tunnel, so a switch mid-flight must not be recorded as
        // if it happened on the new Host.
        guard let host = model.currentHost,
              let context = model.providerOperationContext(for: host)
        else {
            self.error = "当前 Host 不可用或已切换：请在当前 Host 上重试。"
            return
        }
        do {
            let provider = try await connection.updateHostProvider(
                id: id,
                name: editName,
                baseURL: editBaseURL,
                apiKey: editApiKey.isEmpty ? nil : editApiKey,
                modelID: editModelID
            )
            guard model.canApplyProviderOperation(context) else {
                self.error = "Host 在保存过程中已切换：本次修改可能已写入原 Host，请到该 Host 上核对。"
                return
            }
            recordLocalBinding(provider)
            if !editApiKey.isEmpty {
                _ = KeychainStore.saveProviderKey(editApiKey, hostID: host.id, providerId: id)
            }
            editingProvider = nil
            await reload()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func reload() async {
        guard let host = model.currentHost,
              let context = model.providerOperationContext(for: host)
        else {
            providers = []
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let fetched = try await connection.listHostProviders()
            guard model.canApplyProviderOperation(context) else { return }
            providers = fetched
            error = nil
        } catch {
            guard model.canApplyProviderOperation(context) else { return }
            self.error = error.localizedDescription
        }
    }

    private func create() async {
        guard !isCreating else { return }
        guard let host = model.currentHost,
              let context = model.providerOperationContext(for: host)
        else {
            self.error = "当前 Host 不可用或已切换：请在当前 Host 上重试。"
            return
        }
        isCreating = true
        defer { isCreating = false }
        do {
            let provider = try await connection.createHostProvider(
                name: name,
                baseURL: baseURL,
                apiKey: apiKey,
                modelID: modelID
            )
            guard model.canApplyProviderOperation(context) else {
                self.error = "Host 在创建过程中已切换：该 provider 可能已写入原 Host，请到该 Host 上核对。"
                return
            }
            recordLocalBinding(provider)
            _ = KeychainStore.saveProviderKey(apiKey, hostID: host.id, providerId: provider.id)
            name = ""
            baseURL = ""
            apiKey = ""
            modelID = ""
            await reload()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Host v2 stores the provider server-side; sessions still bind through the
    /// local model catalog, so mirror the created/updated provider into it.
    private func recordLocalBinding(_ provider: RACPV2Provider) {
        guard let host = model.currentHost,
              let context = model.providerOperationContext(for: host)
        else { return }
        let input = ProviderCreateInput(
            name: provider.name,
            vendorKey: provider.vendorKey,
            type: provider.type,
            protocol: provider.protocolName,
            authKind: provider.authKind,
            baseUrl: provider.baseUrl,
            models: provider.models.map { spec in
                ProviderModelSpec(
                    id: spec.id,
                    contextWindow: spec.contextWindow,
                    maxTokens: spec.maxTokens,
                    thinkingLevels: spec.thinkingLevels,
                    defaultThinkingLevel: spec.defaultThinkingLevel,
                    alias: spec.displayName == spec.id ? nil : spec.displayName,
                    supportsImages: spec.supportsImages
                )
            },
            defaultModelId: provider.models.first?.id
        )
        // Carry forward the legacy mapping: editing a mirror imported over SSH must
        // not orphan the legacy provider (and its key) on the server.
        let existing = model.storedProvider(hostID: host.id, providerId: provider.id)
        model.recordImportedProvider(
            context: context,
            input: input,
            providerId: provider.id,
            serverDefaultSet: true,
            legacyProviderId: existing?.legacyProviderId,
            hostV2Mirror: true
        )
    }

    private func delete(_ provider: RACPV2Provider) async {
        guard let host = model.currentHost,
              let context = model.providerOperationContext(for: host)
        else {
            self.error = "当前 Host 不可用或已切换：请在当前 Host 上重试删除。"
            return
        }
        // Capture the legacy mapping before removing the local record.
        let existing = model.storedProvider(hostID: host.id, providerId: provider.id)
        do {
            try await connection.deleteHostProvider(id: provider.id)
            guard model.canApplyProviderOperation(context) else { return }
            // A provider mirrored from a legacy SSH import also lives in the legacy
            // store; deleting only the v2 record would leave the legacy service and
            // its secret on the server.
            var legacyError: Error?
            if let legacyProviderId = existing?.legacyProviderId {
                do {
                    _ = try await connection.removeProvider(record: host, providerId: legacyProviderId)
                } catch {
                    legacyError = error
                }
                guard model.canApplyProviderOperation(context) else { return }
            }
            if let legacyError {
                self.error = "v2 Provider 已删除，但 legacy 服务清理失败：\(legacyError.localizedDescription)。本地映射已保留以便重试。"
                await reload()
                return
            }
            _ = model.removeLocalProvider(
                id: "\(host.id.uuidString):\(provider.id)",
                context: context
            )
            _ = KeychainStore.deleteProviderKey(hostID: host.id, providerId: provider.id)
            await reload()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
