import SwiftUI
import PIiOSCore

/// Result of a provider deletion, forwarded to the presenting screen so a
/// partial outcome (secret kept, default model not moved) is shown after the
/// sheet closes instead of being replaced by a generic "已删除" banner.
enum ProviderDeletionNotice: Equatable {
    case success(String)
    case needsAttention(String)
}

struct ModelProviderDetailSheet: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var connection: ConnectionModel
    @Environment(\.dismiss) private var dismiss

    let provider: StoredModelProvider
    let host: HostRecord
    let onDeleted: (ProviderDeletionNotice) -> Void

    @State private var isDeleting = false
    @State private var showingDeleteConfirm = false
    @State private var errorMessage: String?
    @State private var resultMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: PISpacing.s24) {
                    if let errorMessage {
                        PIStatusBanner(
                            kind: .danger,
                            text: "删除未完成",
                            detail: errorMessage,
                            actionTitle: "知道了",
                            action: { self.errorMessage = nil }
                        )
                    }
                    if let resultMessage {
                        PIStatusBanner(
                            kind: .success,
                            text: "模型服务已清理",
                            detail: resultMessage,
                            actionTitle: "知道了",
                            action: { self.resultMessage = nil }
                        )
                    }

                    PICard {
                        Text(provider.name)
                            .font(PIFont.navTitle)
                            .foregroundStyle(PIColor.text)
                        Text(provider.baseURL)
                            .font(PIFont.caption)
                            .foregroundStyle(PIColor.text2)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("\(provider.models.count) 个模型 · 本机记录")
                            .font(PIFont.meta)
                            .foregroundStyle(PIColor.text3)
                    }

                    PIGroup("模型") {
                        ForEach(Array(provider.models.enumerated()), id: \.element.id) { index, item in
                            VStack(alignment: .leading, spacing: PISpacing.s4) {
                                HStack {
                                    Text(item.displayName)
                                        .font(PIFont.listTitle)
                                        .foregroundStyle(PIColor.text)
                                    Spacer()
                                    if provider.defaultModelId == item.id {
                                        Text("默认")
                                            .font(PIFont.metaSmall)
                                            .foregroundStyle(PIColor.accent)
                                    }
                                }
                                Text(item.id)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(PIColor.text2)
                                Text(
                                    "\(compact(item.contextWindow)) ctx"
                                        + " · \(compact(item.maxTokens)) output"
                                        + (item.thinkingLevels.isEmpty
                                            ? " · 无思考档位"
                                            : " · \(item.thinkingLevels.joined(separator: "/"))")
                                )
                                .font(PIFont.metaSmall)
                                .foregroundStyle(PIColor.text3)
                            }
                            .padding(.horizontal, PISpacing.s16)
                            .padding(.vertical, PISpacing.s12)
                            if index < provider.models.count - 1 { PIRowDivider() }
                        }
                    }

                    PIGroup(
                        "删除模型服务",
                        footer: "删除会移除服务器上的 provider 记录与密钥。正在运行的 turn 可能失败且不会被自动迁移；建议先中止运行中的轮次。"
                    ) {
                        PIDangerRow(
                            title: isDeleting ? "正在删除…" : "删除这条服务",
                            isEnabled: connection.state.isOnline && !isDeleting,
                            disabledReason: connection.state.isOnline ? nil : "服务器离线，无法确认删除结果",
                            action: { showingDeleteConfirm = true }
                        )
                    }
                }
                .padding(.horizontal, PIMetrics.pageMargin)
                .padding(.vertical, PISpacing.s16)
            }
            .piPageBackground()
            .piDetailNavBar("模型服务详情")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .alert("删除「\(provider.name)」？", isPresented: $showingDeleteConfirm) {
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) {
                    Task { await deleteProvider() }
                }
            } message: {
                Text("将从服务器删除该 provider 及其密钥，并清理本机记录。项目、文件和设备配对不受影响。")
            }
        }
    }

    private func deleteProvider() async {
        guard provider.hostID == host.id,
              let operation = model.providerOperationContext(for: host) else { return }
        isDeleting = true
        errorMessage = nil
        resultMessage = nil
        defer { isDeleting = false }
        do {
            guard model.canApplyProviderOperation(operation) else { return }
            var summaryText: String?
            // Set when the server reported an outcome the user must act on, so the
            // parent screen can surface it as a warning rather than a plain success.
            var needsAttention = false
            // 1) Drop the v2 Host mirror, if this record has one. Records written
            //    before `hostV2Mirror` existed have `nil`; probe the Host in that
            //    case so an old legacy record (whose id the Host does not know) is
            //    not misread as a mirror and its real legacy entry is still cleaned.
            var v2Removed = false
            if provider.hostV2Mirror ?? true {
                guard connection.state.isOnline else {
                    errorMessage = "服务器离线：无法确认删除 v2 Host 上的 provider 镜像，本机记录已保留。请连接后重试。"
                    return
                }
                do {
                    try await connection.deleteHostProvider(id: provider.providerId)
                    v2Removed = true
                } catch let error as RACPV2Error {
                    if case .server(let code, _) = error, code == "NOT_FOUND" {
                        // The id is not a v2 id: this is a legacy-only record.
                    } else {
                        errorMessage = ConnectionErrorText.describe(error)
                        return
                    }
                } catch {
                    errorMessage = ConnectionErrorText.describe(error)
                    return
                }
                guard model.canApplyProviderOperation(operation) else { return }
            }
            // 2) Drop the legacy SSH store entry when one exists (or is implied).
            var legacyId: String? = provider.legacyProviderId
            if legacyId == nil, provider.hostV2Mirror != true, !v2Removed {
                legacyId = provider.providerId
            }
            if let legacyProviderId = legacyId {
                let receipt = try await connection.removeProvider(
                    record: host,
                    providerId: legacyProviderId
                )
                guard model.canApplyProviderOperation(operation) else { return }
                switch receipt {
                case .success(let summary):
                    summaryText = deleteSummaryText(summary)
                case .defaultTransferOrderUnknown(_, let secretCleared):
                    // 契约 §4.2/§8 的四键例外：已删记录，但默认项因 createdAt 不可比未转移。
                    // 需要人工跟进，必须作为警告展示而不是通用「已删除」。
                    needsAttention = true
                    summaryText = secretCleared
                        ? "服务器已删除记录与密钥，但默认模型因创建时间不可比未转移，请重新选择默认模型。"
                        : "服务器已删除记录，但密钥未清除且默认模型未转移，请人工在服务器上处理。"
                case .failure(let failure):
                    errorMessage = failure.displayMessage
                    return
                case .unparseable(let reason):
                    errorMessage = "服务器回执无法解析：\(reason)。本机记录已保留。"
                    return
                }
            }
            guard model.removeLocalProvider(id: provider.id, context: operation) else { return }
            // Drop any locally stored key(s) for this provider — both the v2 id
            // and, when the record was mirrored from a legacy import, the legacy id.
            _ = KeychainStore.deleteProviderKey(hostID: provider.hostID, providerId: provider.providerId)
            if let legacyProviderId = provider.legacyProviderId, legacyProviderId != provider.providerId {
                _ = KeychainStore.deleteProviderKey(hostID: provider.hostID, providerId: legacyProviderId)
            }
            let detail = summaryText
                ?? (v2Removed ? "已从 v2 Host 删除该 provider 及其密钥。" : "已清理本机记录。")
            resultMessage = detail
            // Hand the outcome to the parent: it owns the post-dismiss banner, so a
            // partial result cannot be hidden behind a generic success message.
            onDeleted(
                needsAttention
                    ? .needsAttention("已删除模型服务「\(provider.name)」：\(detail)")
                    : .success("已删除模型服务「\(provider.name)」")
            )
        } catch {
            guard model.canApplyProviderOperation(operation) else { return }
            errorMessage = ConnectionErrorText.describe(error)
        }
    }

    /// 把删除成功摘要（AC-06.3）翻成用户可读结果：默认项转给了谁、是否已无可用服务。
    private func deleteSummaryText(_ summary: ProviderRemoveSummary) -> String {
        guard summary.effect == .deleted else {
            return "服务器上已不存在该记录；本机残留记录已清理，本次没有再次执行删除。"
        }
        var parts = ["服务器已删除记录与密钥。"]
        switch summary.defaultMoved {
        case .moved(let providerId, let modelId):
            parts.append("默认模型已转给 \(providerId.prefix(8))… / \(modelId)。")
        case .notMoved(let reason):
            parts.append(reason == "no_remaining"
                ? "已无剩余模型服务，请重新添加。"
                : "没有合格的候选模型，默认模型未转移，请重新选择。")
        case nil:
            break
        }
        if summary.remainingEligible == 0 {
            parts.append("当前已无可用模型服务。")
        }
        return parts.joined(separator: " ")
    }

    private func compact(_ value: Int) -> String {
        if value >= 1_000_000, value % 1_000_000 == 0 { return "\(value / 1_000_000)M" }
        if value >= 1_000, value % 1_000 == 0 { return "\(value / 1_000)K" }
        return String(value)
    }
}
