import SwiftUI
import PIiOSNet
import UniformTypeIdentifiers

/// S-04 服务器（子页）。新增与编辑共用一张表单。
///
/// 本页现在真的会连一次服务器：「保存并测试连接」= 写入本机记录 + 凭证进 Keychain +
/// 一次真实 SSH 握手/认证/`exec`；首次连接会先停在指纹核对（AC-02.1）。
/// 配对使用 `pi-adaptor` 输出的一次性令牌；安装入口转到真实 bootstrap 状态机。
struct ServersScreen: View {
    let hostID: UUID?
    let push: (SettingsRoute) -> Void

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var connection: ConnectionModel
    @Environment(\.dismiss) private var dismiss

    @State private var draft = HostDraft()
    /// 首次「保存」创建记录后把它记下来，让表单转入该记录的编辑态：否则第二次
    /// 保存（例如首次连接测试失败后改了信息再存）会再调用一次 `addHost`，
    /// 生成重复的本机记录。
    @State private var createdHostID: UUID?
    @State private var errors = HostDraftErrors.none
    @State private var didLoadHost = false
    @State private var showDeleteConfirm = false
    @State private var isSaving = false
    @State private var isPairing = false
    @State private var isDeleting = false
    @State private var pairingToken = ""
    @State private var pairingMessage: String?
    @State private var resultMessage: String?
    /// 是否正在打开系统文件选择器。
    @State private var isPickingKey = false
    /// 选择私钥文件时的失败原因（不可读 / 格式不支持 / 空文件 / 过大）。
    @State private var keyFileError: String?
    /// 私钥文件选不进来时的兜底通道：直接把私钥文本粘贴进来。
    @State private var isPastingKey = false
    @State private var pastedKeyText = ""
    @State private var pasteKeyError: String?

    /// 当前表单绑定的记录 id：优先本页刚创建的记录，其次是从外层传入的编辑目标。
    private var activeHostID: UUID? { createdHostID ?? hostID }

    private var existingHost: HostRecord? {
        guard let activeHostID else { return nil }
        return model.hosts.first(where: { $0.id == activeHostID })
    }

    private var isEditing: Bool { activeHostID != nil }

    private var account: String? {
        let username = draft.username.piTrimmed
        let host = draft.host.piTrimmed
        guard !username.isEmpty, !host.isEmpty else { return nil }
        return KeychainStore.account(username: username, host: host, port: Int(draft.port.piTrimmed) ?? 22)
    }

    private var pinnedHostKey: SSHHostKey? {
        guard let account else { return nil }
        return KeychainStore.loadHostKey(account: account)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PISpacing.s24) {
                statusBanner
                connectionGroup
                authGroup
                saveButton
                if let host = existingHost {
                    fingerprintSection(for: host)
                    pairingSection(for: host)
                    dangerSection(for: host)
                }
                noteCard
            }
            .padding(.horizontal, PIMetrics.pageMargin)
            .padding(.top, PISpacing.s16)
            .padding(.bottom, PISpacing.s32)
        }
        .piPageBackground()
        .piDetailNavBar("服务器")
        .onAppear(perform: loadHostIfNeeded)
        .sheet(item: $connection.hostKeyPrompt) { prompt in
            HostKeyConfirmSheet(prompt: prompt) { confirmation in
                connection.respondHostKey(confirmation, operationID: prompt.operationID)
            }
        }
        // 用就地打开的选择器而不是 `.fileImporter`：复制型选择器会把系统判定为 package 的
        // `.key`（Keynote 类型）置灰，导致私钥文件选不中；选择器本身由透明宿主控制器模态
        // 弹出（把它内嵌成 sheet 内容时，真机上会「看得见但选不中」）。
        .sheet(isPresented: $isPickingKey) {
            PrivateKeyDocumentPicker(
                onPick: { result in
                    if case let .success(url) = result { importKeyFile(url) }
                    isPickingKey = false
                },
                onCancel: { isPickingKey = false }
            )
            .presentationBackground(.clear)
        }
        .sheet(isPresented: $isPastingKey) {
            pasteKeySheet
        }
        .confirmationDialog(
            deleteTitle,
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                guard let hostID = activeHostID else {
                    dismiss()
                    return
                }
                let name = existingHost?.name ?? "服务器"
                isDeleting = true
                Task { @MainActor in
                    defer { isDeleting = false }
                    if await model.deleteHost(id: hostID) {
                        model.showToast("已删除「\(name)」的本机记录")
                        dismiss()
                    } else {
                        model.showToast("服务器已切换，本次删除未执行")
                    }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只删除这条本机记录；同一 SSH 账户仍被其他记录使用时保留凭证。服务器上的会话、文件与模型配置不受影响。")
        }
    }

    private var deleteTitle: String {
        "删除「\(existingHost?.name ?? "这台服务器")」？"
    }

    // MARK: - 状态条

    @ViewBuilder
    private var statusBanner: some View {
        if connection.isTesting || isSaving {
            PIStatusBanner(
                kind: .info,
                text: "正在测试连接",
                detail: "会完成 SSH 握手与认证；首次连接需要你核对主机指纹。"
            )
        } else if let message = resultMessage {
            PIStatusBanner(kind: .info, text: "测试结果", detail: message)
        } else {
            PIStatusBanner(
                kind: .info,
                text: "保存并测试连接",
                detail: "凭证写入 Keychain（仅本机、不参与 iCloud 同步），本机记录写 state-v1.json；测试会真实连接一次服务器。"
            )
        }
    }

    // MARK: - 表单

    private var connectionGroup: some View {
        PIGroup("连接") {
            formRow {
                PIFormField(
                    label: "名称",
                    hint: "留空时使用服务器地址作为名称",
                    error: errors.name
                ) {
                    TextField("例如：家里的服务器", text: $draft.name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            PIRowDivider()
            formRow {
                PIFormField(
                    label: "地址",
                    hint: "主机名或 IPv4，例如 192.168.1.10",
                    error: errors.host
                ) {
                    TextField("192.168.1.10", text: $draft.host)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            PIRowDivider()
            formRow {
                PIFormField(
                    label: "SSH 端口",
                    hint: "默认 22",
                    error: errors.port
                ) {
                    TextField("22", text: $draft.port)
                        .keyboardType(.numberPad)
                }
            }
            PIRowDivider()
            formRow {
                PIFormField(
                    label: "用户名",
                    hint: "登录服务器用的 Linux 用户",
                    error: errors.username
                ) {
                    TextField("pi", text: $draft.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            PIRowDivider()
            formRow {
                PIFormField(
                    label: "PI-adaptor 端口",
                    hint: "可留空：连接时会通过 SSH 自动探测服务器上 PI-adaptor 监听的端口，无需手动填写",
                    error: errors.hostPort
                ) {
                    TextField("自动探测", text: $draft.hostPort)
                        .keyboardType(.numberPad)
                }
            }
        }
    }

    private var authGroup: some View {
        PIGroup("认证") {
            formRow {
                PIFormField(label: "认证方式", isPill: false) {
                    Picker("认证方式", selection: $draft.authKind) {
                        ForEach(AuthKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
            PIRowDivider()
            formRow {
                switch draft.authKind {
                case .password:
                    PIFormField(
                        label: "密码",
                        hint: "保存在 Keychain，不写入 state-v1.json",
                        error: errors.secret
                    ) {
                        SecureField("服务器登录密码", text: $draft.secret)
                            .textContentType(.password)
                    }
                case .privateKey:
                    VStack(alignment: .leading, spacing: PISpacing.s8) {
                        PIFormField(
                            label: "私钥文件",
                            hint: keyFileHint,
                            error: errors.secret
                        ) {
                            HStack(spacing: PISpacing.s8) {
                                Text(draft.keyFileName ?? (draft.secret.isEmpty ? "未选择文件" : "已载入私钥内容"))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .accessibilityIdentifier("servers.keyFileName")
                                Spacer(minLength: PISpacing.s8)
                                Button(draft.secret.isEmpty ? "选择文件" : "重新选择") {
                                    isPickingKey = true
                                }
                                .buttonStyle(.borderless)
                                .accessibilityIdentifier("servers.pickKey")
                                // 兜底通道：真机上系统选择器读不到文件时，直接把私钥文本粘进来。
                                Button("粘贴") {
                                    pasteKeyError = nil
                                    isPastingKey = true
                                }
                                .buttonStyle(.borderless)
                                .accessibilityIdentifier("servers.pasteKey")
                            }
                        }
                        if let message = keyFileError {
                            Text(message)
                                .font(PIFont.caption)
                                .foregroundStyle(PIColor.danger)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let info = try? SSHPrivateKeyParser.info(openSSHPrivateKey: draft.secret) {
                            Text(
                                "识别到 \(info.displayName)"
                                    + (info.bits > 0 ? " \(info.bits) 位" : "")
                                    + (info.isEncrypted
                                        ? "，已加密（\(info.cipherName)）：请填写下面的私钥口令"
                                        : "，未加密")
                            )
                            .font(PIFont.caption)
                            .foregroundStyle(PIColor.text2)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        if !draft.secret.isEmpty {
                            Button("移除已选择的私钥") {
                                draft.secret = ""
                                draft.keyFileName = nil
                                keyFileError = nil
                            }
                            .buttonStyle(.borderless)
                            .font(PIFont.caption)
                        }
                        PIFormField(
                            label: "私钥口令（可选）",
                            hint: "只在私钥带口令时需要；保存在 Keychain，不写入 state-v1.json",
                            error: errors.passphrase
                        ) {
                            SecureField("私钥口令", text: $draft.passphrase)
                                .textContentType(.newPassword)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                    }
                }
            }
            if isEditing {
                PIRowDivider()
                formRow {
                    Text(existingHost?.authKind != draft.authKind
                        ? "更换认证方式时，请填写对应的新凭证。"
                        : (draft.secret.piTrimmed.isEmpty
                            ? "留空表示沿用 Keychain 里已保存的凭证。"
                            : "填写后会覆盖 Keychain 里的旧凭证。"))
                        .font(PIFont.caption)
                        .foregroundStyle(PIColor.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var saveButton: some View {
        VStack(alignment: .leading, spacing: PISpacing.s8) {
            PIPrimaryButton(
                title: isSaving ? "正在测试连接…" : "保存并测试连接",
                isEnabled: !isSaving && !isPairing && !isDeleting
            ) {
                saveAndTest()
            }
            Text("测试连接会真实登录一次服务器；失败原因会原样显示，不做「看起来成功」。")
                .font(PIFont.caption)
                .foregroundStyle(PIColor.text3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func formRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, PISpacing.s16)
            .padding(.vertical, PISpacing.s12)
    }

    // MARK: - 指纹

    private func fingerprintSection(for host: HostRecord) -> some View {
        PIGroup(
            "主机指纹",
            footer: "指纹变化会被拒绝连接（AC-02.2）。服务器合法重装后，先「移除旧指纹」，再重新连接并确认新指纹（AC-02.3）。"
        ) {
            if let pinned = pinnedHostKey {
                PIListRow(
                    title: "已固定",
                    subtitle: pinned.fingerprint,
                    isEnabled: false,
                    showsDivider: true
                )
                PIListRow(
                    title: "移除旧指纹后重新核对",
                    subtitle: "移除后不会自动信任新指纹：下次连接仍需你确认",
                    showsChevron: true,
                    showsDivider: false,
                    action: {
                        connection.removeHostKeyPin(
                            account: KeychainStore.account(
                                username: host.username,
                                host: host.host,
                                port: host.port
                            ),
                            address: host.address,
                            previousFingerprint: pinned.fingerprint
                        )
                        model.showToast("已移除旧指纹；下次连接需要重新核对")
                    }
                )
            } else {
                PIListRow(
                    title: "尚未固定",
                    subtitle: "下次连接会显示 SHA256 指纹，确认后才写入 Keychain",
                    isEnabled: false,
                    showsDivider: false
                )
            }
        }
    }

    // MARK: - PI-adaptor 连接与危险区

    private func pairingSection(for host: HostRecord) -> some View {
        let hasDeviceToken = KeychainStore.loadDeviceToken(hostID: host.id) != nil
        return PIGroup(
            "PI-adaptor 连接",
            footer: "配对令牌由服务器执行 `pi-adaptor --pair` 时输出，只能使用一次。配对成功后设备令牌只保存在本机 Keychain。"
        ) {
            PIListRow(
                title: "安装或修复 PI-adaptor",
                subtitle: "远端探测、下载校验、systemd 常驻、配对与设备令牌重连",
                isEnabled: !isSaving && !isPairing && !isDeleting,
                showsChevron: true,
                showsDivider: true,
                action: { push(.installHost(host.id)) }
            )
            if hasDeviceToken {
                PIListRow(
                    title: "已保存设备令牌",
                    subtitle: connection.state.displayText,
                    isEnabled: false,
                    showsDivider: true
                )
                PIListRow(
                    title: "连接 PI-adaptor",
                    subtitle: "通过 SSH 隧道连接 127.0.0.1:\(host.hostPort.map(String.init) ?? "未设置")",
                    isEnabled: !isSaving && !isPairing && !isDeleting,
                    showsChevron: true,
                    showsDivider: false,
                    action: { connectExisting(host) }
                )
            } else {
                VStack(alignment: .leading, spacing: PISpacing.s8) {
                    PIFormField(
                        label: "一次性配对令牌",
                        hint: "默认安装格式：ppt2.…；安装流程会在远端启动 PI-adaptor --pair"
                    ) {
                        SecureField("ppt2.…", text: $pairingToken)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    PIPrimaryButton(title: isPairing ? "正在配对…" : "配对并连接") {
                        pairAndConnect(host)
                    }
                    .disabled(isPairing || isSaving || isDeleting || pairingToken.piTrimmed.isEmpty)
                }
                .padding(.horizontal, PISpacing.s16)
                .padding(.vertical, PISpacing.s12)
            }
            if let pairingMessage {
                Text(pairingMessage)
                    .font(PIFont.caption)
                    .foregroundStyle(PIColor.text2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, PISpacing.s16)
                    .padding(.vertical, PISpacing.s12)
            }
        }
    }

    private func pairAndConnect(_ host: HostRecord) {
        guard !isPairing, !isSaving, !isDeleting else { return }
        let account = KeychainStore.account(username: host.username, host: host.host, port: host.port)
        guard let credential = KeychainStore.loadCredential(account: account) else {
            pairingMessage = "本机没有可用凭证：请先保存并测试连接"
            return
        }
        let token = pairingToken
        pairingToken = ""
        isPairing = true
        pairingMessage = nil
        let operationGeneration = model.beginHostOperation(hostID: host.id)
        Task {
            do {
                try await connection.pair(
                    record: host,
                    credential: credential,
                    pairingToken: token
                )
                model.markHostPaired(id: host.id)
                await MainActor.run {
                    pairingMessage = "配对成功；设备令牌已保存"
                }
                if model.canApplyHostOperation(operationGeneration, hostID: host.id) {
                    await model.setCurrentHost(id: host.id)
                } else {
                    await MainActor.run {
                        pairingMessage = "配对成功；当前服务器已切换，未自动连接"
                    }
                }
            } catch {
                await MainActor.run {
                    pairingMessage = "配对失败：\(ConnectionErrorText.describe(error))"
                }
                if model.canApplyHostOperation(operationGeneration, hostID: host.id),
                   let current = model.currentHost {
                    await model.setCurrentHost(id: current.id)
                }
            }
            await MainActor.run { isPairing = false }
        }
    }

    private func connectExisting(_ host: HostRecord) {
        pairingMessage = nil
        Task {
            await model.setCurrentHost(id: host.id)
        }
    }

    private func dangerSection(for host: HostRecord) -> some View {
        PIGroup("危险操作") {
            PIDangerRow(
                title: "删除这台服务器",
                isEnabled: !isSaving && !isPairing && !isDeleting,
                action: { showDeleteConfirm = true }
            )
        }
    }

    private var noteCard: some View {
        PICard {
            Text("本机写了什么")
                .font(PIFont.captionStrong)
                .foregroundStyle(PIColor.text2)
            Text("state-v1.json：地址、端口、用户名、认证方式、名称与 PI-adaptor 端口。Keychain（仅本机）：密码或私钥、设备令牌、已固定的主机指纹。API Key 与令牌都不会出现在本机文件、日志或剪贴板里。")
                .font(PIFont.caption)
                .foregroundStyle(PIColor.text3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 行为

    private func loadHostIfNeeded() {
        guard !didLoadHost else { return }
        didLoadHost = true
        if let host = existingHost {
            draft = HostDraft(record: host)
        }
    }

    // MARK: - 私钥文件

    /// 私钥文件的提示：首次选择、重新选择、编辑态沿用已保存文件，三种情况文案不同。
    private var keyFileHint: String {
        if draft.secret.isEmpty, let name = draft.keyFileName {
            return "Keychain 里已有来自文件「\(name)」的私钥；重新选择会覆盖旧凭证。"
        }
        return "从「文件」App 或 iCloud 云盘选 OpenSSH 私钥（ed25519 / ECDSA / RSA，可带口令）。"
            + "不限制扩展名：`.key`、`.pem`、`id_ed25519` 等都能选。"
            + "文件只读取一次，私钥内容存进 Keychain，原文件之后可删除或移走。"
            + "选择器读不到文件时，用旁边的「粘贴」直接把私钥全文粘进来。"
    }
    /// 读取并校验所选私钥文件。
    ///
    /// iOS 的沙盒约束：外部文件只在选择回调期间可访问（security-scoped），所以这里一次性读入内存，
    /// 校验通过后只保留「文件名 + 私钥文本」。连接时用 Keychain 里的内容，不再依赖原文件路径。
    ///
    /// `url` 由选择器在委托回调里复制到沙盒临时目录，所以这里读到的是普通文件：
    /// 不再有 file provider 安全作用域过期的问题，读完顺手把这份临时副本删掉。
    private func importKeyFile(_ url: URL) {
        defer {
            let directory = url.deletingLastPathComponent()
            if directory.path.hasPrefix(FileManager.default.temporaryDirectory.path) {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        do {
            let file = try SSHPrivateKeyFileLoader.load(contentsOf: url)
            draft.secret = file.text
            draft.keyFileName = file.fileName
            errors.secret = nil
            keyFileError = file.info.isEncrypted && draft.passphrase.isEmpty
                ? "这把私钥带口令保护（\(file.info.cipherName)）：请填写下面的口令，否则连接会失败。"
                : nil
        } catch let error as SSHPrivateKeyFileError {
            // 读不到 / 空 / 过大 / 不是私钥：只报原因，不覆盖已选或已保存的私钥。
            keyFileError = error.description
        } catch {
            keyFileError = "读取私钥文件失败：\(error.localizedDescription)"
        }
    }

    /// 粘贴私钥的兜底通道（真机上系统选择器读不到文件时用）。
    ///
    /// 与文件选择同一条校验路径（`SSHPrivateKeyFileLoader.load`），所以格式错误、
    /// 带 WiFi 口令提示等行为完全一致。文本只在内存里流转，进 Keychain，不落盘、不写日志。
    private var pasteKeySheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $pastedKeyText)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 160)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("servers.pasteKey.text")
                } header: {
                    Text("私钥全文（以 -----BEGIN 开头）")
                } footer: {
                    Text("粘贴的文本只保存在 Keychain，不写入本机文件、日志或剪贴板。")
                }
                if let message = pasteKeyError {
                    Section {
                        Text(message)
                            .font(PIFont.caption)
                            .foregroundStyle(PIColor.danger)
                    }
                }
            }
            .navigationTitle("粘贴私钥")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { isPastingKey = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导入") { applyPastedKey() }
                        .accessibilityIdentifier("servers.pasteKey.import")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func applyPastedKey() {
        defer { pastedKeyText = "" }
        let trimmed = pastedKeyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            pasteKeyError = "先粘贴私钥全文。"
            return
        }
        do {
            let file = try SSHPrivateKeyFileLoader.load(
                fileName: "pasted-key",
                data: Data(trimmed.utf8)
            )
            draft.secret = file.text
            draft.keyFileName = file.fileName
            errors.secret = nil
            pasteKeyError = nil
            keyFileError = file.info.isEncrypted && draft.passphrase.isEmpty
                ? "这把私钥带口令保护（\(file.info.cipherName)）：请填写下面的口令，否则连接会失败。"
                : nil
            isPastingKey = false
        } catch let error as SSHPrivateKeyFileError {
            pasteKeyError = error.description
        } catch {
            pasteKeyError = "导入失败：\(error.localizedDescription)"
        }
    }

    private func saveAndTest() {
        guard !isSaving, !isPairing, !isDeleting else { return }
        errors = validateDraft()
        guard errors.isValid else { return }

        let trimmedName = draft.name.piTrimmed
        let displayName = trimmedName.isEmpty ? draft.host.piTrimmed : trimmedName
        let hostID = activeHostID
        let newHost = draft.host.piTrimmed
        let newPort = Int(draft.port.piTrimmed) ?? existingHost?.port ?? 22
        let account = KeychainStore.account(
            username: draft.username.piTrimmed,
            host: newHost,
            port: newPort
        )
        let typed = draft.secret.piTrimmed
        let credential: SSHCredential?
        if typed.isEmpty {
            credential = KeychainStore.loadCredential(account: account)
        } else {
            let newCredential: SSHCredential = draft.authKind == .password
                ? .password(draft.secret)
                : .privateKey(
                    openSSHText: draft.secret,
                    passphrase: draft.passphrase.isEmpty ? nil : draft.passphrase
                )
            guard KeychainStore.saveCredential(
                newCredential,
                kind: draft.authKind,
                account: account
            ) else {
                errors.secret = "凭证写入 Keychain 失败，请检查设备锁与签名后重试"
                return
            }
            credential = newCredential
        }
        guard let credential else {
            errors.secret = draft.authKind == .password ? "请填写服务器密码" : "请粘贴私钥内容"
            resultMessage = nil
            return
        }
        let requiresReconnect = isEditing
            && existingHost?.isCurrent == true
            && (connectionIdentityChanged(draft) || !draft.secret.piTrimmed.isEmpty)
        isSaving = true
        resultMessage = nil
        Task { @MainActor in
            var identityGeneration: Int?
            if requiresReconnect, let hostID {
                identityGeneration = await model.prepareHostIdentityChange(id: hostID)
            }
            defer {
                if requiresReconnect, let hostID, let identityGeneration {
                    model.finishHostIdentityChange(id: hostID, generation: identityGeneration)
                }
            }

            let record: HostRecord
            if let hostID {
                guard model.updateHost(id: hostID, with: draft),
                      let updated = model.hosts.first(where: { $0.id == hostID })
                else {
                    errors = validateDraft()
                    isSaving = false
                    return
                }
                record = updated
            } else {
                guard let added = model.addHost(draft) else {
                    errors = validateDraft()
                    isSaving = false
                    return
                }
                // 转入该记录的编辑态：再次保存必须更新它，而不是新建第二条。
                self.createdHostID = added.id
                record = added
            }

            let message = await connection.testConnection(record: record, credential: credential)
            if requiresReconnect,
               let hostID,
               let identityGeneration,
               message.hasPrefix("SSH 连接成功"),
               model.canApplyHostIdentityChange(id: hostID, generation: identityGeneration) {
                await model.setCurrentHost(id: hostID)
            }
            isSaving = false
            resultMessage = message
            model.showToast("已保存「\(displayName)」")
        }
    }

    private func connectionIdentityChanged(_ draft: HostDraft) -> Bool {
        guard let existing = existingHost else { return false }
        return existing.host != draft.host.piTrimmed
            || existing.port != (Int(draft.port.piTrimmed) ?? existing.port)
            || existing.username != draft.username.piTrimmed
            || existing.authKind != draft.authKind
            || existing.hostPort != Int(draft.hostPort.piTrimmed)
    }

    private func validateDraft() -> HostDraftErrors {
        // Changing credential type cannot reuse the previous type's secret.
        HostValidator.validate(
            draft,
            requiresSecret: !isEditing || existingHost?.authKind != draft.authKind
        )
    }
}

// MARK: - 指纹核对页（S-04「核对指纹」）

struct HostKeyConfirmSheet: View {
    let prompt: HostKeyPrompt
    let onConfirm: (HostKeyConfirmation) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: PISpacing.s16) {
            VStack(alignment: .leading, spacing: PISpacing.s4) {
                Text(prompt.status == .firstUse ? "核对主机指纹" : "主机指纹已变化")
                    .font(PIFont.navTitle)
                    .foregroundStyle(PIColor.text)
                Text(prompt.address)
                    .font(PIFont.caption)
                    .foregroundStyle(PIColor.text2)
            }

            if case .changed(let pinned) = prompt.status {
                PIStatusBanner(
                    kind: .danger,
                    text: "指纹与固定记录不一致，连接已被拒绝",
                    detail: "原指纹：\(pinned.fingerprint)。这不提供「一键忽略」：请先确认服务器是否被重装或中间人劫持。"
                )
            }

            PIGroup("SHA256 指纹") {
                VStack(alignment: .leading, spacing: PISpacing.s8) {
                    Text(prompt.key.fingerprint)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(PIColor.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("算法：\(prompt.key.algorithm)　与服务器上 `ssh-keygen -lf /etc/ssh/ssh_host_*_key.pub` 的输出逐字比对。")
                        .font(PIFont.caption)
                        .foregroundStyle(PIColor.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, PISpacing.s16)
                .padding(.vertical, PISpacing.s12)
            }

            Spacer(minLength: 0)

            PIPrimaryButton(title: "指纹一致，信任这台服务器") {
                onConfirm(.trust)
                dismiss()
            }
            PISecondaryButton(title: "取消（不建立连接）") {
                onConfirm(.reject)
                dismiss()
            }
        }
        .padding(.horizontal, PIMetrics.pageMargin)
        .padding(.top, PISpacing.s24)
        .padding(.bottom, PIMetrics.safeBottom)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(PIColor.bg)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(PIRadius.sheet)
        .interactiveDismissDisabled()
    }
}
