import Foundation
import PIiOSCore
import PIiOSNet

enum SessionModelAvailability: Equatable {
    case checking
    case available
    case unavailable(reason: String)
    case unknown(reason: String)

    var allowsSending: Bool { self == .available }

    var displayText: String? {
        switch self {
        case .checking:
            return "正在确认当前模型是否可用"
        case .available:
            return nil
        case .unavailable(let reason):
            return "当前模型不可用：\(reason)"
        case .unknown(let reason):
            return "无法确认当前模型是否可用：\(reason)"
        }
    }
}

/// 会话内的全部写操作（发送 / 中止 / 排队 / 审批 / 提问 / 配置）都经过这里。
///
/// 规则（与契约一致，不做例外处理）：
/// - 写操作一律要求隧道在线；离线时按钮禁用并给出原因，不产生静默失败（AC-15.2 / AC-G1）。
/// - 一次性动作（审批、提问、发送）都会带幂等键：发送的键**持久化**并在重试时复用（AC-14.4）。
/// - 提交审批用快照里该卡自己的 `revision`；卡片已不在快照里就不可提交（AC-14.5 / AC-14.6）。
@MainActor
final class SessionController: ObservableObject {
    @Published private(set) var view: RACPSessionView = .empty
    @Published private(set) var attachedSessionId: String?
    @Published private(set) var attachedSummary: RACPSessionSummary?
    @Published private(set) var lastError: String?
    @Published private(set) var notice: String?
    @Published private(set) var isBusy = false
    @Published private(set) var isOnline = false
    @Published private(set) var runningTurnId: String?
    @Published private(set) var permissionMode: RACPPermissionMode = .ask
    @Published private(set) var sessionMode: RACPSessionMode = .agent
    @Published private(set) var thinkingLevel: RACPThinkingLevel?
    @Published private(set) var selectedProviderId: String?
    @Published private(set) var selectedModelId: String?
    @Published private(set) var thinkingSupport = ThinkingLevelSupport(declared: [])
    /// 档位回落说明（AC-07.6）：非 nil 时界面必须展示。
    @Published private(set) var thinkingFallbackNotice: String?
    @Published private(set) var modelAvailability: SessionModelAvailability = .unknown(reason: "尚未检查")
    @Published private(set) var pendingAttachments: [RACPV2Attachment] = []
    @Published var draftText = "" {
        didSet { persistDraftIfNeeded() }
    }

    /// 由 `ConnectionModel` 注入：按 Host/连接代次门控后写入离线缓存。
    var onDraftChanged: ((String, String, String?) -> Void)?
    /// Flush the outgoing session's coalesced cache before changing `attachedSessionId`.
    var onSessionWillChange: (() async -> Void)?

    private var client: RACPClient?
    private var bindGeneration = 0
    private var sessionSelectionGeneration = 0
    var attachmentSelectionGeneration: Int { sessionSelectionGeneration }
    private var configurationGeneration = 0
    private var attachTask: Task<Void, Never>?
    private var busyTokens: Set<UUID> = []
    private var attachmentUploads: Set<UUID> = []
    private var draftSessionID: String?
    private var isReplacingDraft = false
#if DEBUG
    private var fixtureInterruptionEnabled = false
#endif
    private let requestKeys: SessionRequestKeyStore
    private var attachedHostID: String?
    private var draftPreview: (text: String, key: String)?
#if DEBUG
    private var fixtureSnapshots: [String: RACPSessionView] = [:]

    func configureUITestSnapshots(_ snapshots: [String: RACPSessionView]) {
        guard client == nil, !snapshots.isEmpty else { return }
        fixtureSnapshots = snapshots
    }
#endif

    init(requestKeys: SessionRequestKeyStore = SessionRequestKeyStore(fileURL: SessionCacheStore.defaultRequestKeyURL())) {
        self.requestKeys = requestKeys
    }

    var queuedTurns: [QueuedTurn] { view.queuedTurns }
    var pendingApprovals: [RACPApprovalRequest] { view.pendingApprovals }
    var pendingInputs: [RACPInputRequest] { view.pendingInputs }
    var activeItems: [RACPItem] { view.activeItems }

    /// 发送准入：离线禁用；有 turn 在跑则排队（AC-13.1）。
    var sendAdmission: SendAdmission {
        TurnQueuePolicy.admission(
            online: isOnline,
            activeItemCount: view.activeItems.count,
            runningTurnId: runningTurnId
        )
    }

    var canSend: Bool {
        sendAdmission.isAllowed
            && (!trimmedDraft.isEmpty || !pendingAttachments.isEmpty)
            && modelAvailability.allowsSending
    }

    var canInterrupt: Bool {
        TurnQueuePolicy.canInterrupt(
            online: isOnline,
            activeItemCount: view.activeItems.count,
            runningTurnId: runningTurnId
        )
    }

    /// 没有模型目录时（本轮不提供模型服务管理）档位控件不出现（AC-07.7）。
    var showsThinkingControl: Bool { !thinkingSupport.declared.isEmpty }

    var isTurnRunning: Bool {
        TurnQueuePolicy.isRunning(
            activeItemCount: view.activeItems.count,
            runningTurnId: runningTurnId
        )
    }

    var selectedBindingKey: String {
        [
            selectedProviderId ?? "",
            selectedModelId ?? "",
            thinkingLevel?.rawValue ?? "",
        ].joined(separator: "\u{1F}")
    }

    var trimmedDraft: String { draftText.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func prepareDraft(for sessionID: String) {
        guard draftSessionID != sessionID else { return }
        if let previousSessionID = draftSessionID {
            let normalized = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
            onDraftChanged?(
                previousSessionID,
                normalized.isEmpty ? "" : draftText,
                normalized.isEmpty ? nil : draftPreview?.key
            )
        }
        isReplacingDraft = true
        draftText = ""
        draftPreview = nil
        draftSessionID = sessionID
        isReplacingDraft = false
    }

    private func persistDraftIfNeeded() {
        guard !isReplacingDraft,
              let sessionID = attachedSessionId,
              sessionID == draftSessionID
        else { return }
        let normalized = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            draftPreview = nil
            onDraftChanged?(sessionID, "", nil)
            return
        }
        if draftPreview?.text != normalized {
            draftPreview = (normalized, "draft_\(UUID().uuidString)")
        }
        onDraftChanged?(sessionID, draftText, draftPreview?.key)
    }

    // MARK: 生命周期

    /// 连接建立/断开时由 `ConnectionModel` 调用。
    func bind(client: RACPClient?, online: Bool) {
        bindGeneration &+= 1
        sessionSelectionGeneration &+= 1
        attachTask?.cancel()
        attachTask = nil
        self.client = client
        attachedHostID = nil
        draftSessionID = nil
        draftPreview = nil
        isOnline = online
        busyTokens.removeAll()
        attachmentUploads.removeAll()
        isBusy = false
        if client == nil {
            view = .empty
            attachedSessionId = nil
            attachedSummary = nil
            runningTurnId = nil
            selectedProviderId = nil
            selectedModelId = nil
            thinkingSupport = ThinkingLevelSupport(declared: [])
            thinkingLevel = nil
            modelAvailability = .unknown(reason: "尚未检查")
            pendingAttachments = []
        }
    }

    func setOnline(_ online: Bool) {
        isOnline = online
    }

    /// 拉取客户端当前的会话视图（事件到达后由 `ConnectionModel` 触发）。
    func refreshView() async {
        guard let client else { return }
        let generation = bindGeneration
        let selection = sessionSelectionGeneration
        let latest = await client.sessionView()
        let hostID = await client.info()?.hostId
        guard isCurrent(client, generation: generation, selection: selection) else { return }
        if attachedHostID != hostID {
            if attachedHostID != nil { sessionSelectionGeneration &+= 1 }
            attachedHostID = hostID
            draftSessionID = nil
            if let sessionID = attachedSessionId { prepareDraft(for: sessionID) }
        }
        view = latest
        runningTurnId = latest.runningTurnId
        if let summary = latest.summary {
            attachedSummary = summary
            if let mode = summary.mode { sessionMode = mode }
            if let permission = summary.permissionMode { permissionMode = permission }
        }
    }

    /// 打开会话：`session/attach` 拉快照并订阅。
    func attach(sessionId: String) async {
#if DEBUG
        if let snapshot = fixtureSnapshots[sessionId] {
            bind(client: nil, online: true)
            view = snapshot
            attachedSummary = snapshot.summary
            attachedSessionId = sessionId
            runningTurnId = snapshot.runningTurnId
            lastError = nil
            return
        }
#endif
        guard client != nil else {
            lastError = "隧道未连接：无法打开会话"
            return
        }
        sessionSelectionGeneration &+= 1
        let selection = sessionSelectionGeneration
        let generation = bindGeneration
        await onSessionWillChange?()
        guard self.bindGeneration == generation,
              self.sessionSelectionGeneration == selection,
              self.client != nil
        else { return }
        let previous = attachTask
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self,
                  self.bindGeneration == generation,
                  self.sessionSelectionGeneration == selection,
                  let client = self.client
            else { return }
            let busy = self.beginBusy()
            defer { self.endBusy(busy) }
            do {
                try await client.attach(sessionId: sessionId)
                guard self.isCurrent(client, generation: generation, selection: selection) else {
                    return
                }
                if self.attachedSessionId != sessionId {
                    self.pendingAttachments = []
                    self.attachmentUploads.removeAll()
                }
                self.attachedSessionId = sessionId
                self.modelAvailability = .checking
                await self.refreshView()
                guard self.isCurrent(client, generation: generation, selection: selection) else { return }
                self.prepareDraft(for: sessionId)
                self.lastError = nil
            } catch {
                guard self.isCurrent(client, generation: generation, selection: selection) else {
                    return
                }
                self.lastError = ConnectionErrorText.describe(error)
            }
        }
        attachTask = task
        await task.value
    }

    func detach() {
        sessionSelectionGeneration &+= 1
        attachTask?.cancel()
        attachTask = nil
        busyTokens.removeAll()
        attachmentUploads.removeAll()
        isBusy = false
        attachedSessionId = nil
        attachedSummary = nil
        view = .empty
        runningTurnId = nil
        selectedProviderId = nil
        selectedModelId = nil
        thinkingSupport = ThinkingLevelSupport(declared: [])
        thinkingLevel = nil
        modelAvailability = .unknown(reason: "尚未打开会话")
        pendingAttachments = []
    }

    // MARK: 发送（AC-08 / AC-13.1）

    func addImage(data: Data, mimeType: String, fileName: String) async {
        guard let sessionId = attachedSessionId, let client else {
            lastError = "还没有打开会话"
            return
        }
        guard pendingAttachments.count + attachmentUploads.count < 10 else {
            lastError = "每条消息最多 10 张图片"
            return
        }
        let generation = bindGeneration
        let selection = sessionSelectionGeneration
        let uploadID = UUID()
        attachmentUploads.insert(uploadID)
        defer { attachmentUploads.remove(uploadID) }
        let busy = beginBusy()
        defer { endBusy(busy) }
        do {
            let attachment = try await client.uploadImage(
                sessionId: sessionId,
                data: data,
                mimeType: mimeType,
                fileName: fileName
            )
            guard isCurrent(client, generation: generation, selection: selection),
                  attachedSessionId == sessionId else { return }
            pendingAttachments.append(attachment)
            lastError = nil
        } catch {
            guard isCurrent(client, generation: generation, selection: selection),
                  attachedSessionId == sessionId else { return }
            lastError = ConnectionErrorText.describe(error)
        }
    }

    func removeAttachment(id: String) {
        pendingAttachments.removeAll { $0.id == id }
    }

    func send() async {
        guard let sessionId = attachedSessionId else {
            lastError = "还没有打开会话"
            return
        }
        guard !isBusy else {
            lastError = "上一条写入请求仍在处理中，请稍后重试"
            return
        }
        let text = trimmedDraft
        guard !text.isEmpty || !pendingAttachments.isEmpty else { return }
        guard sendAdmission.isAllowed else {
            lastError = "隧道未连接：现在发送会失败，已阻止"
            return
        }
        guard modelAvailability.allowsSending else {
            lastError = modelAvailability.displayText ?? "当前模型不可用，请重新选择模型"
            return
        }
        guard let client else {
            lastError = "隧道未连接"
            return
        }
        let generation = bindGeneration
        let selection = sessionSelectionGeneration
        let busy = beginBusy()
        defer { endBusy(busy) }
        await refreshView()
        guard isCurrent(client, generation: generation, selection: selection),
              trimmedDraft == text,
              let hostID = currentRequestHostID()
        else { return }
        do {
            let attachmentIDs = pendingAttachments.map(\.id)
            let action: SessionRequestAction = attachmentIDs.isEmpty
                ? .turn(text: text)
                : .turnAttachments(text: text, attachmentIds: attachmentIDs)
            let attempt = try requestKeys.prepare(
                SessionRequestIdentity(hostID: hostID, sessionID: sessionId, action: action),
                admission: sendAdmission.turnAdmission
            )
            draftPreview = (text, attempt.idempotencyKey)
            onDraftChanged?(sessionId, draftText, attempt.idempotencyKey)
            let result = try await client.startTurn(
                sessionId: sessionId,
                text: text,
                attachments: attachmentIDs,
                admission: attempt.admission,
                idempotencyKey: attempt.idempotencyKey
            )
            try requestKeys.acknowledge(attempt)
            guard isCurrent(client, generation: generation, selection: selection) else { return }
            runningTurnId = await client.sessionView().runningTurnId
            if trimmedDraft == text && draftPreview?.key == attempt.idempotencyKey {
                draftText = ""
                draftPreview = nil
                pendingAttachments = []
            }
            notice = attempt.admission == nil
                ? nil
                : "已排队：当前 turn 结束后自动开始（\(result.turn.id)）"
            lastError = nil
            await refreshView()
        } catch {
            // 保留草稿与幂等键：重试必须复用同一个键，否则服务器会当成第二条指令。
            guard isCurrent(client, generation: generation, selection: selection) else { return }
            lastError = ConnectionErrorText.describe(error)
        }
    }

    // MARK: 中止 / 取消排队（AC-09.1 / AC-13.2）

#if DEBUG
    func configureUITestInterruption(enabled: Bool) {
        fixtureInterruptionEnabled = enabled
    }
#endif

    func interrupt() async {
        guard isOnline else {
            lastError = "隧道未连接：无法中止当前 turn"
            return
        }
#if DEBUG
        if fixtureInterruptionEnabled, let turnId = runningTurnId {
            let generation = bindGeneration
            let selection = sessionSelectionGeneration
            let busy = beginBusy()
            defer { endBusy(busy) }
            do {
                try await Task.sleep(for: .milliseconds(150))
            } catch {
                return
            }
            guard bindGeneration == generation,
                  sessionSelectionGeneration == selection,
                  self.runningTurnId == turnId
            else { return }
            self.runningTurnId = nil
            self.view.activeItems = []
            notice = "已中止"
            lastError = nil
            return
        }
#endif
        guard let client, let sessionId = attachedSessionId else {
            lastError = "没有正在运行的 turn"
            return
        }
        let generation = bindGeneration
        let selection = sessionSelectionGeneration
        let busy = beginBusy()
        defer { endBusy(busy) }
        do {
            var turnId = runningTurnId
            do {
                // A queued turn promoted by the Host has no local start response.
                // Resolve the authoritative active id immediately before interrupting.
                _ = try await client.getSession(id: sessionId)
                guard isCurrent(client, generation: generation, selection: selection),
                      attachedSessionId == sessionId
                else { return }
                turnId = await client.sessionView().runningTurnId
                runningTurnId = turnId
            } catch {
                // Preserve the last known id only when it exists; the interrupt
                // request will still surface the underlying transport error.
                guard turnId != nil else { throw error }
            }
            guard isCurrent(client, generation: generation, selection: selection),
                  attachedSessionId == sessionId
            else { return }
            guard let turnId else {
                lastError = "没有正在运行的 turn"
                return
            }
            try await client.interruptTurn(turnId: turnId)
            guard isCurrent(client, generation: generation, selection: selection) else { return }
            if runningTurnId == turnId {
                runningTurnId = nil
                view.activeItems = []
            }
            notice = "已中止"
            lastError = nil
        } catch {
            guard isCurrent(client, generation: generation, selection: selection) else { return }
            lastError = ConnectionErrorText.describe(error)
        }
    }

    func cancelQueued(turnId: String) async {
        guard isOnline else {
            lastError = "隧道未连接：无法取消排队项"
            return
        }
        guard let client else {
            lastError = "隧道未连接"
            return
        }
        guard TurnQueuePolicy.canCancel(queued: queuedTurns, id: turnId) else {
            lastError = "该排队项已不在队列里"
            return
        }
        let generation = bindGeneration
        let selection = sessionSelectionGeneration
        let busy = beginBusy()
        defer { endBusy(busy) }
        do {
            try await client.cancelTurn(turnId: turnId)
            guard isCurrent(client, generation: generation, selection: selection) else { return }
            notice = "已取消排队项"
            await refreshView()
        } catch {
            guard isCurrent(client, generation: generation, selection: selection) else { return }
            lastError = ConnectionErrorText.describe(error)
        }
    }

    // MARK: 审批 / 提问（AC-10 / AC-11 / AC-12）

    func availability(for approvalId: String) -> DecisionAvailability {
        DecisionPolicy.approvalAvailability(
            id: approvalId,
            pending: pendingApprovals,
            expiredIds: view.expiredApprovalIds
        )
    }

    /// 判断这张卡是工具审批还是 Plan/Goal 契约（按卡片 `kind` 读，读不到按工具审批处理）。
    static func isContract(_ card: RACPApprovalRequest) -> Bool {
        let kind = card.payload.value(at: ["kind"])?.stringValue?.lowercased() ?? ""
        return kind.contains("plan") || kind.contains("goal") || kind.contains("contract")
    }

    func decide(approvalId: String, decision: RACPApprovalDecision) async {
        await respondApproval(approvalId: approvalId) { _ in
            .approval(decision: decision, permissionMode: decision == .allowSession ? self.permissionMode : nil)
        }
    }

    func decideContract(approvalId: String, decision: RACPContractDecision) async {
        await respondApproval(approvalId: approvalId) { card in
            try DecisionPolicy.contractAction(for: card, decision: decision, currentMode: self.permissionMode)
        }
    }

    private func respondApproval(
        approvalId: String,
        action makeAction: (RACPApprovalRequest) throws -> SessionRequestAction
    ) async {
        guard isOnline, let client else {
            lastError = "隧道未连接：审批现在提交会失败，已阻止"
            return
        }
        guard !isBusy else { return }
        let busy = beginBusy()
        defer { endBusy(busy) }
        let generation = bindGeneration
        let selection = sessionSelectionGeneration
        await refreshView()
        guard isCurrent(client, generation: generation, selection: selection),
              let sessionId = attachedSessionId,
              let hostID = currentRequestHostID()
        else { return }
        let availability = availability(for: approvalId)
        guard case let .actionable(cardRevision) = availability, let revision = cardRevision else {
            lastError = availability.statusText ?? "未取得审批版本：请刷新后重试"
            return
        }
        do {
            guard let card = pendingApprovals.first(where: { $0.id == approvalId }) else { return }
            let action = try makeAction(card)
            let attempt = try requestKeys.prepare(
                SessionRequestIdentity(hostID: hostID, sessionID: sessionId, itemID: approvalId, action: action)
            )
            let params = try RACPApprovalRespondParams(
                approvalId: approvalId, action: action,
                context: RACPContext(requestId: "req_\(UUID().uuidString)", idempotencyKey: attempt.idempotencyKey, expectedRevision: revision)
            )
            let result: JSONValue = try await client.request(.approvalRespond, params: params)
            try requestKeys.acknowledge(attempt)
            guard isCurrent(client, generation: generation, selection: selection) else { return }
            let alreadyResolved = result.value(at: ["alreadyResolved"])?.boolValue ?? false
            notice = alreadyResolved ? "该审批已被处理过，未重复执行" : "已提交审批结果"
            lastError = nil
            await refreshView()
        } catch {
            guard isCurrent(client, generation: generation, selection: selection) else { return }
            if let code = Self.serverCode(from: error), DecisionPolicy.marksCardStale(after: code) {
                await client.markApprovalExpired(id: approvalId)
                await refreshView()
                lastError = "该审批已失效：\(code.userMessage)"
            } else {
                lastError = ConnectionErrorText.describe(error)
            }
            await refreshView()
        }
    }

    /// 回答 AskTool 提问；`answers` 顺序必须与该卡问题顺序对齐（AC-11.1）。
    func answer(inputId: String, answers: [[String]?]) async {
        guard isOnline, let client else {
            lastError = "隧道未连接：回答现在提交会失败，已阻止"
            return
        }
        let generation = bindGeneration
        let selection = sessionSelectionGeneration
        await refreshView()
        guard isCurrent(client, generation: generation, selection: selection),
              let sessionId = attachedSessionId,
              let hostID = currentRequestHostID()
        else { return }
        guard case let .actionable(cardRevision) = DecisionPolicy.inputAvailability(id: inputId, pending: pendingInputs),
              let revision = cardRevision else {
            lastError = "该提问已不可提交或缺少版本：请刷新后重试"
            return
        }
        let busy = beginBusy()
        defer { endBusy(busy) }
        do {
            let attempt = try requestKeys.prepare(
                SessionRequestIdentity(hostID: hostID, sessionID: sessionId, itemID: inputId, action: .input(answers: answers))
            )
            _ = try await client.respondInput(
                inputId: inputId,
                answers: answers,
                expectedRevision: revision,
                idempotencyKey: attempt.idempotencyKey
            )
            try requestKeys.acknowledge(attempt)
            guard isCurrent(client, generation: generation, selection: selection) else { return }
            notice = "已回答提问"
            lastError = nil
            await refreshView()
        } catch {
            guard isCurrent(client, generation: generation, selection: selection) else { return }
            lastError = ConnectionErrorText.describe(error)
            await refreshView()
        }
    }

    // MARK: 配置（AC-07）

    /// 切换会话模式/权限模式/档位；运行中的 turn 不允许改模型（AC-07.2）。
    func configure(
        mode: RACPSessionMode? = nil,
        permissionMode: RACPPermissionMode? = nil,
        providerId: String? = nil,
        modelId: String? = nil,
        thinkingLevel requested: RACPThinkingLevel? = nil,
        thinkingSupport support: ThinkingLevelSupport? = nil
    ) async {
        guard isOnline else {
            lastError = "隧道未连接：配置未提交"
            return
        }
        guard let client, let sessionId = attachedSessionId else {
            lastError = "还没有打开会话"
            return
        }
        guard !isBusy else {
            lastError = "上一项操作仍在进行：请稍候再提交配置"
            return
        }
        let generation = bindGeneration
        let selection = sessionSelectionGeneration
        guard !TurnQueuePolicy.isRunning(activeItemCount: view.activeItems.count, runningTurnId: runningTurnId) else {
            lastError = "当前轮次仍在运行：等它结束再切换模型或档位"
            return
        }
        let changesModel = providerId != nil || modelId != nil
        let nextSupport = support ?? thinkingSupport
        let currentThinkingLevel = thinkingLevel
        let resolution: ThinkingLevelResolution
        if changesModel || requested != nil {
            resolution = ThinkingLevelPolicy.resolve(current: requested ?? currentThinkingLevel, support: nextSupport)
        } else {
            resolution = ThinkingLevelResolution(
                level: thinkingLevel,
                didFallback: false,
                fallbackSource: nil
            )
        }
        configurationGeneration &+= 1
        let configGeneration = configurationGeneration
        let busy = beginBusy()
        defer { endBusy(busy) }
        do {
            let summary = try await client.configureSession(
                sessionId: sessionId,
                mode: mode,
                permissionMode: permissionMode,
                providerId: providerId,
                modelId: modelId,
                thinkingLevel: resolution.level
            )
            guard configGeneration == configurationGeneration,
                  isCurrent(client, generation: generation, selection: selection)
            else { return }
            attachedSummary = summary
            if let newMode = summary.mode { sessionMode = newMode }
            if let newPermission = summary.permissionMode { self.permissionMode = newPermission }
            thinkingLevel = resolution.level
            if let providerId { selectedProviderId = providerId }
            if let modelId { selectedModelId = modelId }
            if support != nil { thinkingSupport = nextSupport }
            if changesModel { modelAvailability = .checking }
            thinkingFallbackNotice = resolution.didFallback
                ? ThinkingLevelPolicy.fallbackExplanation(
                    from: currentThinkingLevel,
                    to: resolution.level,
                    fallbackSource: resolution.fallbackSource
                )
                : nil
            notice = "会话配置已更新"
            lastError = nil
        } catch {
            guard configGeneration == configurationGeneration,
                  isCurrent(client, generation: generation, selection: selection)
            else { return }
            lastError = ConnectionErrorText.describe(error)
        }
    }

    // MARK: 错误分类

    static func serverCode(from error: Error) -> RACPErrorCode? {
        if case let RACPClientError.server(code, _) = error { return code }
        return nil
    }

    private func currentRequestHostID() -> String? {
        guard isOnline, let hostID = attachedHostID, !hostID.isEmpty else {
            lastError = "未确认在线 Host 身份：请重新连接后重试"
            return nil
        }
        return hostID
    }

    private func isCurrent(
        _ client: RACPClient,
        generation: Int,
        selection: Int
    ) -> Bool {
        self.client === client
            && bindGeneration == generation
            && sessionSelectionGeneration == selection
    }

    private func beginBusy() -> UUID {
        let token = UUID()
        busyTokens.insert(token)
        isBusy = true
        return token
    }

    private func endBusy(_ token: UUID) {
        busyTokens.remove(token)
        isBusy = !busyTokens.isEmpty
    }

    func clearError() { lastError = nil }
    func clearNotice() { notice = nil }

    func applyModelAvailability(_ status: ProviderBindingStatus) {
        if let providerId = status.pinnedProviderId {
            selectedProviderId = providerId
        }
        if let modelId = status.pinnedModelId {
            selectedModelId = modelId
        }
        if let rawLevel = status.pinnedThinkingLevel {
            thinkingLevel = RACPThinkingLevel(rawValue: rawLevel)
        }
        if status.available == true {
            modelAvailability = .available
            return
        }
        let reason = Self.availabilityReason(status.unavailableReason)
        if status.available == false {
            modelAvailability = .unavailable(reason: reason)
        } else {
            modelAvailability = .unknown(reason: reason)
        }
    }

    func markModelAvailabilityUnknown(_ reason: String) {
        modelAvailability = .unknown(reason: reason)
    }

    /// Mark the current model as known-unavailable with a reason the caller
    /// derived (e.g. the provider exists only in the legacy store), so the UI
    /// can show why sending is blocked and how to fix it.
    func markModelUnavailable(_ reason: String) {
        modelAvailability = .unavailable(reason: reason)
    }

    func markModelAvailabilityChecking() {
        modelAvailability = .checking
    }

    private static func availabilityReason(_ value: String?) -> String {
        switch value {
        case "provider_missing": return "模型服务不存在"
        case "provider_disabled": return "模型服务已禁用"
        case "models_empty": return "模型服务没有模型"
        case "model_removed": return "所选模型已被移除"
        case "secret_missing": return "模型服务缺少密钥"
        case "oauth_unsupported": return "不支持订阅账号型模型服务"
        case "no_candidate": return "没有可用的模型服务"
        default: return "请重新检查或选择其他模型"
        }
    }
}
