import SwiftUI
import PIiOSCore
import PIiOSNet

/// S-06 安装 pi-host。
///
/// 页面只展示 runner 的真实状态文件与事件，不伪造进度。远端安装脚本在
/// `setsid nohup` 子进程里继续运行；本页通过短 exec 轮询，因此锁屏或短暂
/// 离开页面不会把 69 MB 下载绑在单次 SSH exec 上。
struct InstallHostScreen: View {
    let hostID: UUID
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var connection: ConnectionModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var coordinator = InstallHostCoordinator()

    @State private var portText = ""
    @State private var didSeedPort = false
    @State private var showingLog = false
    @State private var sudoCredential = ""
    /// 强制重装：忽略服务器上的 `.release.sha256` 复用判定（版本没变但字节变了时用）。
    @State private var forceReinstall = false
    @FocusState private var portFocused: Bool

    private var host: HostRecord? {
        model.hosts.first(where: { $0.id == hostID })
    }

    private var portError: String? {
        let text = portText.piTrimmed
        if text.isEmpty {
            return "安装必须填写 pi-host 常驻端口"
        }
        return HostValidator.hostPortError(text)
    }

    private var canStart: Bool {
        host != nil && portError == nil && !coordinator.isRunning
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PISpacing.s24) {
                statusBanners
                targetCard
                if let host {
                    receiptCard(host)
                    configurationCard
                    if coordinator.state != nil {
                        progressCard
                    }
                    failureCard
                    actions
                } else {
                    missingHostCard
                }
                privacyCard
            }
            .padding(.horizontal, PIMetrics.pageMargin)
            .padding(.top, PISpacing.s16)
            .padding(.bottom, PISpacing.s32)
        }
        .piPageBackground()
        .piDetailNavBar("安装 pi-host")
        .onAppear(perform: seedPort)
        .sheet(item: $connection.hostKeyPrompt) { prompt in
            HostKeyConfirmSheet(prompt: prompt) { confirmation in
                connection.respondHostKey(confirmation, operationID: prompt.operationID)
            }
        }
        .sheet(isPresented: $showingLog) {
            InstallHostLogSheet(coordinator: coordinator) {
                await coordinator.loadLog(model: model, connection: connection, hostID: hostID)
            }
        }
    }

    @ViewBuilder
    private var statusBanners: some View {
        switch coordinator.phase {
        case .running:
            PIStatusBanner(
                kind: .info,
                text: "正在安装 pi-host",
                detail: coordinator.activity
            )
        case .stalled:
            PIStatusBanner(
                kind: .warning,
                text: "安装暂时没有进展",
                detail: (coordinator.stallMessage
                    ?? "这是一个可恢复点。可以查看日志；流程仍会继续轮询到 15 分钟。")
                    + " 最终失败后可重试，服务器会复用已下载分片和有效回执。"
            )
        case .success:
            PIStatusBanner(
                kind: coordinator.postInstallWarning == nil ? .success : .warning,
                text: coordinator.postInstallWarning == nil
                    ? "安装与设备验证完成"
                    : "安装完成，但本机记录未写回",
                detail: coordinator.activity
            )
        case .failed:
            PIStatusBanner(
                kind: .danger,
                text: "安装未完成",
                detail: coordinator.failureSummary
            )
        case .idle:
            PIStatusBanner(
                kind: .info,
                text: "安装会先核对服务器指纹",
                detail: "首次连接必须先确认 SSH SHA256 指纹。安装只写入该用户的 ~/.pi-desktop/pi-host 与 systemd user unit。"
            )
        }
    }

    private var targetCard: some View {
        PICard {
            Text("目标服务器")
                .font(PIFont.captionStrong)
                .foregroundStyle(PIColor.text2)
            if let host {
                Text(host.name)
                    .font(PIFont.listTitle)
                    .foregroundStyle(PIColor.text)
                Text("\(host.address) · \(host.statusText)")
                    .font(PIFont.caption)
                    .foregroundStyle(PIColor.text2)
            } else {
                Text("这台服务器的记录已不存在")
                    .font(PIFont.listTitle)
                    .foregroundStyle(PIColor.text)
                Text("可能已在设置里删除。返回服务器列表重新添加。")
                    .font(PIFont.caption)
                    .foregroundStyle(PIColor.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func receiptCard(_ host: HostRecord) -> some View {
        if let receipt = host.installReceipt {
            PICard {
                Text("上次成功安装")
                    .font(PIFont.captionStrong)
                    .foregroundStyle(PIColor.text2)
                Text("v\(receipt.version) · 端口 \(receipt.hostPort)")
                    .font(PIFont.listTitle)
                    .foregroundStyle(PIColor.text)
                Text("完成于 \(receipt.completedAt.formatted(date: .abbreviated, time: .shortened))。再次安装时服务器会先核对 .release.sha256，命中则跳过下载、校验和解包。")
                    .font(PIFont.caption)
                    .foregroundStyle(PIColor.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var configurationCard: some View {
        PIGroup(
            "安装参数",
            footer: "端口是服务器 127.0.0.1 上的 pi-host RACP 监听端口，不是 SSH 端口。安装成功后会自动写回本机服务器记录。"
        ) {
            VStack(alignment: .leading, spacing: PISpacing.s12) {
                PIFormField(
                    label: "pi-host 端口",
                    hint: "建议使用现有端口或 44271；不要填 0，随机端口无法常驻。",
                    error: portError
                ) {
                    TextField("44271", text: $portText)
                        .keyboardType(.numberPad)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($portFocused)
                        .accessibilityIdentifier("installHost.port")
                }
                Text("固定版本：v\(ConnectionModel.defaultHostInstallReleaseVersion) · 自动按 uname -m 选择 linux-x64 / linux-arm64")
                    .font(PIFont.caption)
                    .foregroundStyle(PIColor.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, PISpacing.s16)
            .padding(.vertical, PISpacing.s12)
        }
    }

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: PISpacing.s12) {
            PISectionHeader(text: "安装进度")
            if let state = coordinator.state {
                downloadCard(state)
                PIGroup(footer: "步骤来自服务器 .bootstrap/state.json；连接中断后重新进入本页可再次安装，服务器回执会避免重复下载。") {
                    ForEach(Array(InstallStepDescriptor.all.enumerated()), id: \.element.id) { index, step in
                        PIListRow(
                            title: step.title,
                            subtitle: step.detail,
                            value: coordinator.value(for: step.step),
                            isEnabled: false,
                            showsDivider: index < InstallStepDescriptor.all.count - 1
                        )
                    }
                }
                if !coordinator.transitionNotes.isEmpty {
                    PIStatusBanner(
                        kind: .warning,
                        text: "状态推进异常",
                        detail: coordinator.transitionNotes.joined(separator: "\n")
                    )
                }
            }
        }
    }

    private func downloadCard(_ state: BootstrapStateFile) -> some View {
        PICard {
            Text("下载数据")
                .font(PIFont.captionStrong)
                .foregroundStyle(PIColor.text2)
            let downloaded = state.artifact?.downloadedBytes ?? 0
            let total = state.artifact?.bytes ?? 0
            Text(coordinator.byteSummary(state: state))
                .font(PIFont.listTitle)
                .foregroundStyle(PIColor.text)
            if total > 0 {
                ProgressView(value: Double(min(downloaded, total)), total: Double(total))
                    .tint(PIColor.accent)
                    .accessibilityLabel("下载进度")
                    .accessibilityValue("\(Int(Double(min(downloaded, total)) / Double(total) * 100))%")
            } else if coordinator.isRunning && state.step == .download {
                ProgressView()
                    .tint(PIColor.accent)
                    .accessibilityLabel("正在下载")
            }
            if let name = state.artifact?.name {
                Text(name)
                    .font(PIFont.caption)
                    .foregroundStyle(PIColor.text3)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var failureCard: some View {
        if coordinator.phase == .failed {
            PICard {
                Text("故障分类")
                    .font(PIFont.captionStrong)
                    .foregroundStyle(PIColor.text2)
                Text(coordinator.failureCode?.rawValue ?? "client-error")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(PIColor.danger)
                    .textSelection(.enabled)
                if let code = coordinator.failureCode {
                    Text(code.displayMessage)
                        .font(PIFont.caption)
                        .foregroundStyle(PIColor.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if coordinator.failureCode == .pairFailed {
                    Text("安装包已下载并切换完成，当前只差重新启动配对；重试不会重新下载或解包。")
                        .font(PIFont.caption)
                        .foregroundStyle(PIColor.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if [.downloadFailed, .checksumMismatch].contains(coordinator.failureCode),
                   coordinator.failureCount >= 2 {
                    Text("已连续失败 \(coordinator.failureCount) 次：请检查服务器出网是否经过需要认证的代理，或 GitHub Release 是否可达。")
                        .font(PIFont.caption)
                        .foregroundStyle(PIColor.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("installHost.proxyHint")
                }
                if let detail = coordinator.failureDetail, !detail.isEmpty {
                    Text(detail)
                        .font(PIFont.caption)
                        .foregroundStyle(PIColor.text3)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if coordinator.failureCode == .unitFailed {
                    SecureField("sudo 密码", text: $sudoCredential)
                        .textContentType(.password)
                        .disabled(coordinator.isRunning)
                        .accessibilityIdentifier("installHost.sudoCredential")
                    PISecondaryButton(
                        title: "重新授权并继续",
                        isEnabled: !sudoCredential.isEmpty && !coordinator.isRunning
                    ) {
                        guard let host, let port = Int(portText.piTrimmed) else { return }
                        coordinator.start(
                            host: host,
                            port: port,
                            sudoCredential: sudoCredential,
                            model: model,
                            connection: connection
                        )
                    }
                    .accessibilityIdentifier("installHost.retrySudo")
                }
                Text("重试会生成新的 attemptId；服务器上的有效安装回执和已下载分片会继续复用。")
                    .font(PIFont.caption)
                    .foregroundStyle(PIColor.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var actions: some View {
        VStack(spacing: PISpacing.s12) {
            Toggle(isOn: $forceReinstall) {
                VStack(alignment: .leading, spacing: PISpacing.s4) {
                    Text("强制重装（忽略已装版本）")
                        .font(PIFont.captionStrong)
                    Text("勾选后不会复用服务器上已有的安装树：重新下载并激活当前发布包。版本没变但发布字节变了时必须勾选。")
                        .font(PIFont.metaSmall)
                        .foregroundStyle(PIColor.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .disabled(!canStart)
            .accessibilityIdentifier("installHost.forceReinstall")
            PIPrimaryButton(
                title: primaryButtonTitle,
                isEnabled: canStart && coordinator.failureCode != .unitFailed,
                identifier: "installHost.start"
            ) {
                portFocused = false
                guard let host, let port = Int(portText.piTrimmed) else { return }
                coordinator.start(
                    host: host,
                    port: port,
                    forceReinstall: forceReinstall,
                    model: model,
                    connection: connection
                )
            }
            HStack(spacing: PISpacing.s12) {
                PISecondaryButton(
                    title: coordinator.isLoadingLog ? "正在读取日志…" : "查看安装日志",
                    isEnabled: !coordinator.isLoadingLog
                ) {
                    showingLog = true
                    Task {
                        await coordinator.loadLog(
                            model: model,
                            connection: connection,
                            hostID: hostID
                        )
                    }
                }
                .accessibilityIdentifier("installHost.log")
                PISecondaryButton(title: "刷新日志") {
                    Task {
                        await coordinator.loadLog(
                            model: model,
                            connection: connection,
                            hostID: hostID
                        )
                    }
                }
                .disabled(coordinator.isLoadingLog)
                .accessibilityIdentifier("installHost.log.refresh")
            }
            if coordinator.phase == .failed {
                PISecondaryButton(title: "返回服务器") {
                    dismiss()
                }
                .accessibilityIdentifier("installHost.back")
            }
        }
    }

    private var primaryButtonTitle: String {
        switch coordinator.phase {
        case .running, .stalled:
            return "正在安装…"
        case .failed:
            switch coordinator.failureCode {
            case .downloadFailed, .checksumMismatch:
                return "重试下载"
            case .pairFailed:
                return "重新配对"
            default:
                return "重试安装"
            }
        case .success:
            return "重新运行安装"
        case .idle:
            return "开始安装"
        }
    }

    private var missingHostCard: some View {
        PICard {
            Text("无法开始")
                .font(PIFont.captionStrong)
                .foregroundStyle(PIColor.text2)
            Text("服务器记录已被删除，请返回服务器页重新添加并保存 SSH 凭证。")
                .font(PIFont.caption)
                .foregroundStyle(PIColor.text3)
        }
    }

    private var privacyCard: some View {
        PICard {
            Text("安全边界")
                .font(PIFont.captionStrong)
                .foregroundStyle(PIColor.text2)
            Text("配对令牌只从 0600 的远端文件读入内存，并立即从服务器删除；设备令牌只写本机 Keychain。API Key、设备令牌与配对令牌都不会进入安装日志或本机状态文件。")
                .font(PIFont.caption)
                .foregroundStyle(PIColor.text3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func seedPort() {
        guard !didSeedPort else { return }
        didSeedPort = true
        if let existing = host?.hostPort, (1...65_535).contains(existing) {
            portText = String(existing)
        } else {
            portText = "44271"
        }
    }
}

private struct InstallHostLogSheet: View {
    @ObservedObject var coordinator: InstallHostCoordinator
    let reload: () async -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                if coordinator.isLoadingLog {
                    ProgressView("正在读取 bootstrap.log…")
                        .padding(PISpacing.s24)
                } else if let error = coordinator.logError {
                    PIStatusBanner(kind: .danger, text: "日志读取失败", detail: error)
                        .padding(PIMetrics.pageMargin)
                } else {
                    Text(coordinator.logText ?? "还没有读取日志。")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(PIColor.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(PIMetrics.pageMargin)
                }
            }
            .background(PIColor.bg)
            .navigationTitle("安装日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("刷新") { Task { await reload() } }
                        .disabled(coordinator.isLoadingLog)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .task {
            if coordinator.logText == nil {
                await reload()
            }
        }
    }
}

@MainActor
private final class InstallHostCoordinator: ObservableObject {
    enum Phase: Equatable {
        case idle
        case running
        case stalled
        case success
        case failed
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var state: BootstrapStateFile?
    @Published private(set) var activity = "准备探测服务器平台。"
    @Published private(set) var stallMessage: String?
    @Published private(set) var failureCode: BootstrapFailureCode?
    @Published private(set) var failureDetail: String?
    @Published private(set) var failureCount = 0
    @Published private(set) var transitionNotes: [String] = []
    @Published private(set) var postInstallWarning: String?
    @Published private(set) var logText: String?
    @Published private(set) var logError: String?
    @Published private(set) var isLoadingLog = false

    private var runTask: Task<Void, Never>?
    private var runID = UUID()

#if DEBUG
    init() {
        switch ProcessInfo.processInfo.environment["PI_IOS_INSTALL_FIXTURE_FAILURE"] {
        case "download-twice":
            phase = .failed
            failureCode = .downloadFailed
            failureCount = 2
            failureDetail = "UI fixture：下载在 42% 中断。"
        case "pair-expired":
            phase = .failed
            failureCode = .pairFailed
            failureCount = 1
            failureDetail = "UI fixture：一次性配对令牌已过期。"
        case "sudo-failure":
            phase = .failed
            failureCode = .unitFailed
            failureCount = 1
            failureDetail = "UI fixture：sudo 密码错误。"
        default:
            break
        }
    }
#endif

    var isRunning: Bool { phase == .running || phase == .stalled }

    var failureSummary: String {
        if failureDetail == nil, let failureCode {
            return failureCode.displayMessage
        }
        return failureDetail ?? "安装器返回了未知错误。"
    }

    func start(
        host: HostRecord,
        port: Int,
        sudoCredential: String? = nil,
        forceReinstall: Bool = false,
        model: AppModel,
        connection: ConnectionModel
    ) {
        guard !isRunning else { return }
        let generation = UUID()
        runID = generation
        phase = .running
        state = nil
        activity = "正在连接 SSH 并探测服务器平台。"
        stallMessage = nil
        failureCode = nil
        failureDetail = nil
        transitionNotes = []
        postInstallWarning = nil

        runTask = Task { [weak self] in
            guard let self else { return }
            do {
                if let sudoCredential {
                    guard !sudoCredential.isEmpty else {
                        throw HostInstallError.emptySudoPassword
                    }
                    self.activity = "正在通过 SSH stdin 授权 loginctl enable-linger。"
                    try await connection.authorizeHostInstall(
                        record: host,
                        sudoPassword: sudoCredential
                    )
                    guard self.runID == generation else { return }
                }
                let outcome = try await connection.installHost(
                    record: host,
                    port: port,
                    force: forceReinstall
                ) { event in
                    await self.receive(event)
                }
                guard self.runID == generation else { return }
                self.finish(outcome: outcome, host: host, model: model)
            } catch is CancellationError {
                guard self.runID == generation else { return }
                self.phase = .failed
                self.failureCount += 1
                self.failureDetail = "安装任务已取消；服务器上的后台任务可能仍在继续，可查看日志或重试。"
            } catch {
                guard self.runID == generation else { return }
                self.phase = .failed
                self.failureCount += 1
                self.failureDetail = ConnectionErrorText.describe(error)
            }
            if self.runID == generation {
                self.runTask = nil
            }
        }
    }

    private func receive(_ event: BootstrapRunnerEvent) {
        switch event {
        case .state(let next):
            if let previous = state,
               previous.step == next.step,
               (previous.artifact?.downloadedBytes ?? 0) == (next.artifact?.downloadedBytes ?? 0) {
                // Preserve the stalled presentation until there is real progress.
            } else {
                stallMessage = nil
                if phase == .stalled { phase = .running }
            }
            state = next
            activity = "当前步骤：\(stepTitle(next.step))"
        case .transitionIssues(let issues):
            transitionNotes = issues.map(\.message)
        case .stalled(let message):
            stallMessage = message
            if phase == .running { phase = .stalled }
        case .pairingStarted:
            activity = "正在用同一 SSH 连接交换一次性配对令牌。"
        case .pairingCompleted(let deviceId):
            activity = "配对成功，设备 \(deviceId) 已写入 Keychain；正在等待常驻服务启动。"
        case .verificationStarted:
            activity = "正在用新设备令牌重连 RACP 并发送 connection/ping。"
        case .verificationCompleted:
            activity = "设备令牌验证通过，正在等待 install 的最终回执。"
        }
    }

    private func finish(
        outcome: HostInstallRunOutcome,
        host: HostRecord,
        model: AppModel
    ) {
        switch outcome.result {
        case .succeeded(let success):
            state = success.state
            let persisted = model.completeHostInstallation(
                id: host.id,
                expectedHost: host.host,
                expectedPort: host.port,
                expectedUsername: host.username,
                port: success.port,
                version: outcome.releaseVersion,
                attemptId: outcome.attemptId
            )
            phase = .success
            if persisted {
                activity = "systemd unit active，设备令牌重连与 ping 均成功；hostPort、pairedAt 与安装回执已写回本机。"
                postInstallWarning = nil
            } else {
                activity = "安装与设备验证已完成，但本机服务器记录写入失败：\(model.saveError ?? "未知错误")"
                postInstallWarning = model.saveError
            }
            failureCode = nil
            failureDetail = nil
            failureCount = 0
        case .failed(let failure):
            state = failure.state
            phase = .failed
            failureCode = failure.code
            failureDetail = failureMeta(failure)
            failureCount += 1
        case .unsupported(let reason):
            phase = .failed
            failureCode = reason.code
            failureDetail = reason.message
            failureCount += 1
        }
    }

    private func failureMeta(_ failure: BootstrapRunFailure) -> String? {
        var details: [String] = []
        if failure.callbackFailure == .pairing {
            details.append("客户端配对回调失败；令牌已失效时请重试以重新启动 --pair。")
        } else if failure.callbackFailure == .verification {
            details.append("客户端设备令牌验证失败；常驻服务已启动，但尚未达到可连接终态。")
        }
        if let raw = failure.state.failureCodeRaw, raw != failure.code.rawValue {
            details.append("服务器原始失败码：\(raw)")
        }
        if let artifact = failure.state.artifact?.name {
            details.append("产物：\(artifact)")
        }
        return details.isEmpty ? nil : details.joined(separator: "\n")
    }

    func loadLog(
        model: AppModel,
        connection: ConnectionModel,
        hostID: UUID
    ) async {
        guard !isLoadingLog else { return }
        guard let host = model.hosts.first(where: { $0.id == hostID }) else {
            logError = "服务器记录已不存在。"
            return
        }
        isLoadingLog = true
        logError = nil
        defer { isLoadingLog = false }
        do {
            logText = try await connection.hostInstallLog(record: host)
        } catch {
            logError = ConnectionErrorText.describe(error)
        }
    }

    func value(for step: BootstrapStep) -> String {
        guard let current = state else { return "等待" }
        if current.status == .failed, current.step == step { return "失败" }
        if current.status == .ok, step == .done { return "完成" }
        guard let currentOrder = current.step.order, let order = step.order else {
            return current.step == step ? "进行中" : "等待"
        }
        if order < currentOrder { return "完成" }
        if order == currentOrder { return phase == .success ? "完成" : "进行中" }
        return "等待"
    }

    func byteSummary(state: BootstrapStateFile) -> String {
        let downloaded = state.artifact?.downloadedBytes ?? 0
        let total = state.artifact?.bytes ?? 0
        if total > 0 {
            return "\(Self.bytes(downloaded)) / \(Self.bytes(total))"
        }
        if downloaded > 0 {
            return "已下载 \(Self.bytes(downloaded))"
        }
        return state.step == .download ? "正在建立下载" : "尚无下载数据"
    }

    private func stepTitle(_ step: BootstrapStep) -> String {
        InstallStepDescriptor.all.first(where: { $0.step == step })?.title ?? step.rawValue
    }

    private static func bytes(_ value: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(max(0, value)), countStyle: .file)
    }
}

private struct InstallStepDescriptor: Identifiable {
    let step: BootstrapStep
    let title: String
    let detail: String

    var id: String { step.rawValue }

    static let all: [InstallStepDescriptor] = [
        .init(step: .probe, title: "探测", detail: "读取 uname -s / uname -m 并选择架构"),
        .init(step: .resolve, title: "解析 Release", detail: "下载并解析对应产物的 sha256"),
        .init(step: .download, title: "下载", detail: "断点续传到 owner-only .part 文件"),
        .init(step: .verify, title: "校验", detail: "sha256 不匹配则不切换 current"),
        .init(step: .extract, title: "解包", detail: "解包到隔离暂存目录并检查结构"),
        .init(step: .activate, title: "激活版本", detail: "执行 bundle 自检后原子切换 current"),
        .init(step: .writeUnit, title: "写入 unit", detail: "写入 systemd user unit 并 enable-linger"),
        .init(step: .startPair, title: "启动配对进程", detail: "停止 unit，单独启动一次 --pair"),
        .init(step: .pair, title: "交换设备令牌", detail: "同一 SSH 连接完成 connection/pair"),
        .init(step: .stopManual, title: "停止手动进程", detail: "确认 --pair 进程已退出"),
        .init(step: .startUnit, title: "启动常驻服务", detail: "启动不带 --pair 的 systemd unit"),
        .init(step: .verifyDevice, title: "验证设备令牌", detail: "重新 initialize + ping"),
        .init(step: .done, title: "完成", detail: "unit active 且设备令牌重连成功"),
    ]
}
