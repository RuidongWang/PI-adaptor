import SwiftUI

/// 设置子页路由（information-architecture.md §3：设置 → 服务器 / 安装 pi-host）。
enum SettingsRoute: Hashable {
    case addServer
    case editServer(UUID)
    case installHost(UUID)
    case models
    case hostProviders
    case skills
}

/// S-03 设置（根）。分组：服务器 / 模型 / 本机。
///
/// 本增量可真实使用的部分：主机列表与增删改、外观、离线缓存上限、删除 host 的二次确认。
/// 没有连接层，所以主机状态一律「未配对 · 未连接」，不出现在线标记。
struct SettingsScreen: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var connection: ConnectionModel
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw = AppearanceMode.system.rawValue

    @State private var path: [SettingsRoute] = []
    @State private var showingAppearanceSheet = false
    @State private var showingCacheLimitSheet = false
    @State private var pendingRevokeHostID: UUID?
    @State private var hostUnitSnapshot: HostUnitSnapshot?
    @State private var hostUnitError: String?
    @State private var isLoadingHostUnit = false
    @State private var hostUnitRequestID: UUID?

    private var appearance: AppearanceMode {
        AppearanceMode(rawValue: appearanceRaw) ?? .system
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: PISpacing.s24) {
                    banners
                    serversSection
                    tunnelSection
                    modelsSection
                    skillsSection
                    deviceSection
                    pushNotice
                }
                .padding(.horizontal, PIMetrics.pageMargin)
                .padding(.top, PISpacing.s8)
                .padding(.bottom, PISpacing.s32)
            }
            .piPageBackground()
            .piRootNavBar("设置", onMenu: model.openSidebar)
            .navigationDestination(for: SettingsRoute.self) { route in
                switch route {
                case .addServer:
                    ServersScreen(hostID: nil) { path.append($0) }
                case .editServer(let hostID):
                    ServersScreen(hostID: hostID) { path.append($0) }
                case .installHost(let hostID):
                    InstallHostScreen(hostID: hostID)
                case .models:
                    ModelsScreen()
                case .hostProviders:
                    HostProvidersScreen()
                case .skills:
                    SkillsScreen()
                }
            }
            .sheet(isPresented: $showingAppearanceSheet) {
                AppearanceSheet()
            }
            .sheet(isPresented: $showingCacheLimitSheet) {
                CacheLimitSheet(current: model.offlineCacheLimit) { limit in
                    model.setOfflineCacheLimit(limit)
                }
            }
            .confirmationDialog(
                "撤销本机配对？",
                isPresented: revokeDialogBinding,
                titleVisibility: .visible
            ) {
                Button("撤销配对", role: .destructive) {
                    if let hostID = pendingRevokeHostID {
                        Task { await model.revokePairing(hostID: hostID) }
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("将清除本机保存的配对记录与设备凭证；服务器上的 pi-host 安装、运行与会话不受影响。")
            }
            .task(id: model.currentHost?.id) {
                await refreshHostUnitStatus()
            }
        }
    }

    private var revokeDialogBinding: Binding<Bool> {
        Binding(
            get: { pendingRevokeHostID != nil },
            set: { if !$0 { pendingRevokeHostID = nil } }
        )
    }

    // MARK: - 状态条

    @ViewBuilder
    private var banners: some View {
        if let warning = model.loadWarning {
            PIStatusBanner(
                kind: .warning,
                text: "本机设置读取异常",
                detail: warning,
                actionTitle: "知道了",
                action: { model.dismissLoadWarning() }
            )
        }
        if let error = model.saveError {
            PIStatusBanner(
                kind: .danger,
                text: "本机记录未能写入",
                detail: error,
                actionTitle: "知道了",
                action: { model.dismissSaveError() }
            )
        }
    }

    // MARK: - 服务器

    private var serversSection: some View {
        VStack(alignment: .leading, spacing: PISpacing.s8) {
            PISectionHeader(text: "服务器")
            if model.hosts.isEmpty {
                PIEmptyState(
                    title: "还没有服务器",
                    message: "添加一台服务器后，才能在服务器页安装 pi-host 并完成配对。当前只保存本机记录。",
                    actionTitle: "＋ 添加服务器",
                    action: { path.append(.addServer) }
                )
            } else {
                PIGroup {
                    ForEach(Array(model.hosts.enumerated()), id: \.element.id) { index, host in
                        serverRow(host, showsDivider: true)
                    }
                    if let current = model.currentHost, current.pairedAt == nil {
                        PIListRow(
                            title: "重新配对",
                            subtitle: "打开服务器页，使用 pi-host 的一次性令牌完成配对",
                            showsChevron: true,
                            showsDivider: false,
                            action: { path.append(.editServer(current.id)) }
                        )
                    }
                }
                addServerButton
            }
        }
    }

    private func serverRow(_ host: HostRecord, showsDivider: Bool) -> some View {
        PIListRow(
            title: host.name,
            subtitle: "\(host.address) · \(host.statusText) · \(host.isCurrent ? connection.state.displayText : "未连接")",
            showsChevron: true,
            showsDivider: showsDivider,
            action: { path.append(.editServer(host.id)) }
        ) {
            if host.isCurrent {
                Text("当前")
                    .font(PIFont.metaSmall)
                    .foregroundStyle(PIColor.accent)
                    .padding(.horizontal, PISpacing.s8)
                    .padding(.vertical, 2)
                    .background(PIColor.accentSoft, in: Capsule())
            }
        }
    }

    private var addServerButton: some View {
        Button {
            path.append(.addServer)
        } label: {
            Text("＋ 添加服务器")
                .font(PIFont.button)
                .foregroundStyle(PIColor.accent)
                .frame(maxWidth: .infinity)
                .frame(minHeight: PIMetrics.minHitTarget)
                .background(PIColor.surface, in: RoundedRectangle(cornerRadius: PIRadius.group, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: PIRadius.group, style: .continuous)
                        .strokeBorder(PIColor.separator, lineWidth: PIMetrics.hairline)
                )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.addServer")
    }

    // MARK: - 隧道（真实状态）

    private var tunnelSection: some View {
        VStack(alignment: .leading, spacing: PISpacing.s8) {
            PISectionHeader(text: "隧道")
            if let host = model.currentHost {
                PIGroup(footer: tunnelFooter) {
                    PIListRow(
                        title: "连接状态",
                        subtitle: connection.state.detail,
                        value: connection.state.displayText,
                        isEnabled: false,
                        showsDivider: true
                    )
                    .accessibilityIdentifier("settings.connectionState")
                    if let info = connection.info {
                        PIListRow(
                            title: "Host 版本",
                            subtitle: "\(info.serverName) · 协议 \(info.protocolVersion)",
                            value: info.serverVersion,
                            isEnabled: false,
                            showsDivider: true
                        )
                        .accessibilityIdentifier("settings.hostVersion")
                    }
                    PIListRow(
                        title: "systemd 服务",
                        subtitle: hostUnitError,
                        value: isLoadingHostUnit
                            ? "查询中"
                            : hostUnitSnapshot?.activeState ?? "未查询",
                        isEnabled: true,
                        showsChevron: true,
                        showsDivider: true,
                        action: { Task { await refreshHostUnitStatus() } }
                    )
                    .accessibilityIdentifier("settings.hostUnit")
                    if hostUnitSnapshot?.isActive != true || !connection.state.isOnline {
                        PIListRow(
                            title: "重启命令",
                            subtitle: "systemctl --user restart pi-host.service",
                            isEnabled: false,
                            showsDivider: true
                        )
                        .accessibilityIdentifier("settings.restartCommand")
                    }
                    if let error = connection.lastError {
                        PIListRow(
                            title: "最近一次错误",
                            subtitle: error,
                            isEnabled: false,
                            showsDivider: true
                        )
                    }
                    if connection.state.isOnline {
                        PIListRow(
                            title: "刷新项目与会话",
                            subtitle: "重新发送 project/list 与 session/list",
                            showsChevron: true,
                            showsDivider: true,
                            action: { Task { await connection.refreshRemote() } }
                        )
                        PIListRow(
                            title: "断开隧道",
                            showsDivider: false,
                            action: { Task { await connection.disconnect() } }
                        )
                    } else {
                        PIListRow(
                            title: "连接",
                            subtitle: connectDisabledReason(host),
                            isEnabled: connectDisabledReason(host) == nil,
                            showsDivider: true,
                            action: { Task { await model.setCurrentHost(id: host.id) } }
                        )
                        PIListRow(
                            title: "断开隧道",
                            subtitle: "当前没有已建立的隧道",
                            isEnabled: false,
                            showsDivider: false
                        )
                    }
                }
                if case .offline(let reason) = connection.state, let reason {
                    PIStatusBanner(kind: .info, text: "未连接", detail: reason)
                }
                if !connection.state.isOnline, model.currentHost != nil {
                    // AC-17：服务停止时给出可复制的重启命令，不假装在线。
                    PICard {
                        Text("Host 离线时的排查")
                            .font(PIFont.captionStrong)
                            .foregroundStyle(PIColor.text2)
                        Text("在服务器上确认服务状态并重启：systemctl --user restart pi-host（系统级 unit 用 sudo systemctl restart pi-host）。App 不会自动重启服务器上的进程。")
                            .font(PIFont.caption)
                            .foregroundStyle(PIColor.text3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                PIListRow(
                    title: "连接状态",
                    subtitle: "还没有服务器，先在「服务器」里添加一台",
                    isEnabled: false,
                    showsDivider: false
                )
            }
        }
    }

    private var tunnelFooter: String {
        "隧道是 SSH `direct-tcpip` 到服务器 127.0.0.1:<pi-host 端口>，在其上跑 RACP WebSocket。断开后会自动按 1s/2s/4s/8s 退避重连。"
    }

    private func refreshHostUnitStatus() async {
        let requestID = UUID()
        hostUnitRequestID = requestID
        guard let host = model.currentHost, host.pairedAt != nil else {
            if hostUnitRequestID == requestID {
                hostUnitSnapshot = nil
                hostUnitError = nil
                isLoadingHostUnit = false
            }
            return
        }
        isLoadingHostUnit = true
        do {
            let snapshot = try await connection.hostUnitSnapshot(record: host)
            guard hostUnitRequestID == requestID,
                  model.currentHost?.id == host.id
            else { return }
            hostUnitSnapshot = snapshot
            hostUnitError = nil
            isLoadingHostUnit = false
        } catch {
            guard hostUnitRequestID == requestID,
                  model.currentHost?.id == host.id
            else { return }
            hostUnitSnapshot = nil
            hostUnitError = ConnectionErrorText.describe(error)
            isLoadingHostUnit = false
        }
    }

    /// 连接入口的禁用原因：缺凭证/端口/令牌时直接说明，不做「能点但没反应」。
    private func connectDisabledReason(_ host: HostRecord) -> String? {
        let account = KeychainStore.account(username: host.username, host: host.host, port: host.port)
        if KeychainStore.loadCredential(account: account) == nil {
            return "本机没有凭证：先在服务器页「保存并测试连接」"
        }
        if KeychainStore.loadDeviceToken(hostID: host.id) == nil {
            return "本机没有设备令牌：先在服务器页完成 pi-host 配对"
        }
        return nil
    }

    // MARK: - 模型

    private var modelsSection: some View {
        PIGroup(
            "模型",
            footer: "模型清单保存在本机；API Key 在导入后只保存在服务器。"
        ) {
            PIListRow(
                title: "模型服务",
                subtitle: model.currentModelProviders.isEmpty
                    ? "尚未导入；进入后可从服务端自动发现模型"
                    : "\(model.currentModelProviders.count) 个服务 · \(model.currentModelProviders.reduce(0) { $0 + $1.models.count }) 个模型",
                showsChevron: true,
                showsDivider: true,
                action: { path.append(.models) }
            )
            PIListRow(
                title: "Host v2 Provider",
                subtitle: "直接管理服务器保存的 provider 与密钥",
                showsChevron: true,
                showsDivider: true,
                action: { path.append(.hostProviders) }
            )
            PIListRow(
                title: "默认模型",
                value: model.defaultModelLabel,
                isEnabled: false,
                showsDivider: false
            )
        }
    }

    private var skillsSection: some View {
        PIGroup("Skill", footer: "全局 Skill 保存在服务器；更新后新 turn 使用新版本。") {
            PIListRow(
                title: "全局 Skill",
                subtitle: connection.state.isOnline ? "安装、更新、删除服务器 Skill" : "连接 Host 后可管理",
                showsChevron: true,
                showsDivider: false,
                action: { path.append(.skills) }
            )
        }
    }

    // MARK: - 本机

    private var deviceSection: some View {
        PIGroup("本机", footer: "外观偏好与缓存上限只存本机，不随服务器同步，也不依赖连接状态。") {
            PIListRow(
                title: "外观",
                subtitle: appearance.title,
                showsChevron: true,
                showsDivider: true,
                action: { showingAppearanceSheet = true }
            )
            PIListRow(
                title: "离线缓存上限",
                subtitle: "每个会话最多缓存 \(connection.cacheItemLimit) 条（当前按离线上限裁剪），最多 \(PersistedState.maxCachedConversations) 个会话",
                value: "\(model.offlineCacheLimit) 条",
                showsChevron: true,
                showsDivider: true,
                action: { showingCacheLimitSheet = true }
            )
            PIDangerRow(
                title: "撤销本机配对",
                isEnabled: model.isCurrentHostPaired,
                disabledReason: revokeDisabledReason,
                action: { pendingRevokeHostID = model.currentHost?.id }
            )
        }
    }

    private var revokeDisabledReason: String {
        if model.currentHost == nil {
            return "还没有服务器，没有可撤销的配对记录"
        }
        return "当前服务器未配对：配对流程属下一增量，没有可撤销的配对记录"
    }

    // MARK: - 固定说明（AC-16.2）

    private var pushNotice: some View {
        VStack(alignment: .leading, spacing: PISpacing.s4) {
            Text("不会收到后台推送")
                .font(PIFont.captionStrong)
                .foregroundStyle(PIColor.text2)
            Text("产品未接入 APNs：需要自己打开 App 才会拉取服务器状态与新消息。")
                .font(PIFont.caption)
                .foregroundStyle(PIColor.text3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, PISpacing.s4)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 外观浮层

private struct AppearanceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw = AppearanceMode.system.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: PISpacing.s16) {
            VStack(alignment: .leading, spacing: PISpacing.s4) {
                Text("外观")
                    .font(PIFont.navTitle)
                    .foregroundStyle(PIColor.text)
                Text("选择立即作用于全部页面与浮层。")
                    .font(PIFont.caption)
                    .foregroundStyle(PIColor.text2)
            }
            PIGroup {
                ForEach(Array(AppearanceMode.allCases.enumerated()), id: \.element.id) { index, mode in
                    PIOptionRow(
                        title: mode.title,
                        subtitle: mode.detail,
                        isSelected: appearanceRaw == mode.rawValue,
                        showsDivider: index < AppearanceMode.allCases.count - 1
                    ) {
                        appearanceRaw = mode.rawValue
                    }
                }
            }
            Spacer(minLength: 0)
            PIPrimaryButton(title: "完成") { dismiss() }
        }
        .padding(.horizontal, PIMetrics.pageMargin)
        .padding(.top, PISpacing.s24)
        .padding(.bottom, PIMetrics.safeBottom)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(PIColor.bg)
        .presentationDetents([.height(430)])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(PIRadius.sheet)
    }
}

// MARK: - 离线缓存上限浮层

private struct CacheLimitSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onSelect: (Int) -> Void
    @State private var selected: Int

    init(current: Int, onSelect: @escaping (Int) -> Void) {
        self.onSelect = onSelect
        _selected = State(initialValue: current)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PISpacing.s16) {
            VStack(alignment: .leading, spacing: PISpacing.s4) {
                Text("离线缓存上限")
                    .font(PIFont.navTitle)
                    .foregroundStyle(PIColor.text)
                Text("每个会话最多缓存的条数，默认 \(PersistedState.defaultOfflineCacheLimit) 条；本机最多缓存 \(PersistedState.maxCachedConversations) 个会话。")
                    .font(PIFont.caption)
                    .foregroundStyle(PIColor.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            PIGroup {
                ForEach(Array(PersistedState.offlineCacheLimitOptions.enumerated()), id: \.element) { index, option in
                    PIOptionRow(
                        title: "\(option) 条",
                        isSelected: selected == option,
                        showsDivider: index < PersistedState.offlineCacheLimitOptions.count - 1
                    ) {
                        selected = option
                        onSelect(option)
                    }
                }
            }
            Spacer(minLength: 0)
            PIPrimaryButton(title: "完成") { dismiss() }
        }
        .padding(.horizontal, PIMetrics.pageMargin)
        .padding(.top, PISpacing.s24)
        .padding(.bottom, PIMetrics.safeBottom)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(PIColor.bg)
        .presentationDetents([.height(430)])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(PIRadius.sheet)
    }
}
