import SwiftUI
import UIKit
import QuartzCore
import PhotosUI
import PIiOSCore
import PIiOSNet

/// S-02 会话（根）。
///
/// 线程、审批、提问、排队与中止都走真实的 RACP 调用；离线时只显示本机缓存并标注可能不是最新。
/// 没有向量（vector）能力：不渲染示例对话，也不在缺数据时假装有内容。
struct ConversationScreen: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var connection: ConnectionModel
    @ObservedObject private var session: SessionController

    @State private var showingConfig = false
    @State private var selections: [String: [Int: Set<String>]] = [:]
    @State private var showingRename = false
    @State private var renameDraft = ""
    @State private var isNearBottom = true
    @State private var hasNewBelow = false
    @State private var scrollToBottomRequest = 0
    @State private var isCheckingModelAvailability = false
    @State private var modelAvailabilityGeneration = 0
    /// Provider ids that exist only in the legacy store (never mirrored into the
    /// v2 Host store). Empty until a successful v2 probe confirms we are talking
    /// to a v2 Host, so a v1 Host never gets its models wrongly marked.
    @State private var legacyOnlyProviderIDs: Set<String> = []
    @State private var topVisibleItemID: String?
    @State private var lastMeasuredTopItemID: String?
    @State private var readingRestoreTargetItemID: String?
    @State private var readingRestoreRequestID = 0
    @State private var activeReadingHostID: UUID?
    @State private var activeReadingSessionID: String?
    @State private var isRestoringReadingPosition = false
    @State private var newMessagesDuringRestore = false
    @State private var restoreBaselineReady = false
    @State private var restoreBaselineCount = 0
    @State private var restoreBaselineLastItemID: String?
    @State private var readingRestoreGeneration = 0
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var photoSelectionID = UUID()

    init(session: SessionController) {
        self.session = session
    }

    private var currentHost: HostRecord? { model.currentHost }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                Divider()
                // 待审批卡片固定在滚动区之上，不随会话滚动：它是「工具正在等你的决定」的
                // 唯一入口，放进滚动内容时会被自动滚到底部的逻辑顶出视口（长历史下差上千点），
                // 用户看不到卡片就只能中止，表现为「工具一直在执行中」。
                if connection.state.isOnline,
                   session.attachedSessionId != nil,
                   !session.pendingApprovals.isEmpty {
                    ScrollView {
                        approvalSection
                            .padding(.horizontal, PIMetrics.pageMargin)
                            .padding(.vertical, PISpacing.s8)
                    }
                    .frame(maxHeight: 260)
                    .scrollBounceBehavior(.basedOnSize)
                    Divider()
                }
                GeometryReader { viewport in
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: PISpacing.s16) {
                                statusArea
                                if connection.state.isOnline, session.attachedSessionId != nil {
                                    inputSection
                                    queueSection
                                    threadSection
                                } else if !connection.state.isOnline, let sessionId = cachedSessionId {
                                    offlineThread(sessionId: sessionId)
                                }
                            }
                            .padding(.horizontal, PIMetrics.pageMargin)
                            .padding(.vertical, PISpacing.s16)
                            .id("thread-bottom")
                            .background {
                                GeometryReader { content in
                                    Color.clear.preference(
                                        key: ConversationContentBottomKey.self,
                                        value: content.frame(in: .named("conversation-scroll")).maxY
                                    )
                                }
                            }
                        }
                        .coordinateSpace(name: "conversation-scroll")
                        .id(readingContextKey ?? "unbound-reading-context")
                        .transaction { transaction in
                            if isRestoringReadingPosition {
                                transaction.animation = nil
                                transaction.disablesAnimations = true
                            }
                        }
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 2).onChanged { _ in
                                guard isRestoringReadingPosition else { return }
                                readingRestoreTargetItemID = nil
                                isRestoringReadingPosition = false
                                hasNewBelow = newMessagesDuringRestore
                            }
                        )
                        .onPreferenceChange(ConversationContentBottomKey.self) { contentBottom in
                            let distance = contentBottom - viewport.size.height
                            let near = distance <= 96
                            let changed = isNearBottom != near
                            if near {
                                hasNewBelow = false
                            }
                            isNearBottom = near
                            if changed {
                                recordReadingPosition()
                            }
                        }
                        .onPreferenceChange(ConversationItemFrameKey.self) { frames in
                            let viewportBottom = viewport.size.height
                            let visibleItemID = frames
                                .filter { frame in
                                    frame.value.maxY > 0 && frame.value.minY < viewportBottom
                                }
                                .min { lhs, rhs in
                                    lhs.value.minY < rhs.value.minY
                                }?
                                .key
                            lastMeasuredTopItemID = visibleItemID

                            if isRestoringReadingPosition {
                                guard let target = readingRestoreTargetItemID,
                                      let frame = frames[target],
                                      abs(frame.minY) <= 2
                                else { return }
                                readingRestoreTargetItemID = nil
                                topVisibleItemID = target
                                isNearBottom = false
                                hasNewBelow = newMessagesDuringRestore
                                isRestoringReadingPosition = false
                                recordReadingPosition()
                                return
                            }

                            if let lastItemID = session.view.items.last?.id {
                                let lastFrame = frames[lastItemID]
                                let near = lastFrame.map {
                                    $0.maxY > 0 && $0.minY <= viewportBottom + 96
                                } ?? false
                                if isNearBottom != near {
                                    isNearBottom = near
                                    if near { hasNewBelow = false }
                                    recordReadingPosition()
                                }
                            }
                            guard let visibleItemID,
                                  visibleItemID != topVisibleItemID
                            else { return }
                            topVisibleItemID = visibleItemID
                            recordReadingPosition()
                        }
                        .onChange(of: session.view.items) { _, _ in
                            recordVisibleMessageCount()
                            guard !isRestoringReadingPosition else {
                                if restoreBaselineReady,
                                   session.view.items.count > restoreBaselineCount,
                                   session.view.items.last?.id != restoreBaselineLastItemID {
                                    newMessagesDuringRestore = true
                                }
                                return
                            }
                            if isNearBottom {
                                withAnimation(.easeOut(duration: 0.15)) {
                                    proxy.scrollTo("thread-bottom", anchor: .bottom)
                                }
                            } else {
                                hasNewBelow = true
                            }
                        }
                        .onChange(of: session.view.runningTurnId) { _, _ in
                            guard !isRestoringReadingPosition, isNearBottom else { return }
                            withAnimation(.easeOut(duration: 0.15)) {
                                proxy.scrollTo("thread-bottom", anchor: .bottom)
                            }
                        }
                        .onChange(of: session.view.activeItems) { _, _ in
                            guard !isRestoringReadingPosition, isNearBottom else { return }
                            withAnimation(.easeOut(duration: 0.15)) {
                                proxy.scrollTo("thread-bottom", anchor: .bottom)
                            }
                        }
                        .onChange(of: session.view.queuedTurns) { _, _ in
                            guard !isRestoringReadingPosition, isNearBottom else { return }
                            withAnimation(.easeOut(duration: 0.15)) {
                                proxy.scrollTo("thread-bottom", anchor: .bottom)
                            }
                        }
                        .onChange(of: scrollToBottomRequest) { _, _ in
                            isNearBottom = true
                            hasNewBelow = false
                            withAnimation(.easeOut(duration: 0.15)) {
                                proxy.scrollTo("thread-bottom", anchor: .bottom)
                            }
                            recordReadingPosition()
                        }
                        .task(id: readingRestoreTaskKey) {
                            await restoreReadingPosition(proxy: proxy)
                        }
                        .overlay(alignment: .bottomTrailing) {
                            if !isNearBottom {
                                Button {
                                    withAnimation(.easeOut(duration: 0.18)) {
                                        proxy.scrollTo("thread-bottom", anchor: .bottom)
                                    }
                                    isNearBottom = true
                                    hasNewBelow = false
                                    recordReadingPosition()
                                } label: {
                                    Text(hasNewBelow ? "新消息 · 回到最新" : "回到最新")
                                        .font(PIFont.captionStrong)
                                        .foregroundStyle(PIColor.onAccent)
                                        .padding(.horizontal, PISpacing.s12)
                                        .padding(.vertical, PISpacing.s8)
                                        .background(PIColor.accent, in: Capsule())
                                }
                                .buttonStyle(.plain)
                                .padding(PISpacing.s12)
                                .accessibilityLabel(hasNewBelow ? "有新消息，回到最新" : "回到最新")
                            }
                        }
                    }
                }
                composer
            }
            .piPageBackground()
            .overlay(alignment: .topLeading) {
#if DEBUG
                Text(topVisibleItemID ?? "none")
                    .font(.system(size: 1))
                    .foregroundStyle(PIColor.text)
                    .frame(width: 1, height: 1)
                    .clipped()
                    .accessibilityIdentifier("conversation.debugTopVisibleItem")
                    .allowsHitTesting(false)
                Text("target=\(readingRestoreTargetItemID ?? "none"),measured=\(lastMeasuredTopItemID ?? "none")")
                    .font(.system(size: 1))
                    .foregroundStyle(PIColor.text)
                    .frame(width: 1, height: 1)
                    .clipped()
                    .accessibilityIdentifier("conversation.debugRestorationState")
                    .allowsHitTesting(false)
#endif
            }
            .piRootNavBar(sessionTitle, onMenu: model.openSidebar) {
                Menu {
                    Button("会话配置") { showingConfig = true }
                        .disabled(!connection.state.isOnline || session.attachedSessionId == nil)
                    Button("重命名会话") {
                        renameDraft = sessionTitle
                        showingRename = true
                    }
                    .disabled(session.attachedSessionId == nil)
                    Button("归档会话", role: .destructive) {
                        archiveCurrentSession()
                    }
                    .disabled(session.attachedSessionId == nil)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: PIMetrics.minHitTarget, height: PIMetrics.minHitTarget)
                }
                .accessibilityLabel("会话操作")
            }
            .sheet(isPresented: $showingConfig) {
                SessionConfigSheet(
                    session: session,
                    groups: model.currentModelGroups,
                    diagnostics: model.currentModelDiagnostics,
                    unavailableProviderIDs: legacyOnlyProviderIDs
                )
            }
            .alert("重命名会话", isPresented: $showingRename) {
                TextField("会话标题", text: $renameDraft)
                Button("取消", role: .cancel) {}
                Button("保存") { renameCurrentSession() }
            } message: {
                Text("标题只保存在本机，不会改写服务器上的会话内容。")
            }
            .task(id: session.attachedSessionId) {
                await refreshModelAvailability()
            }
            .onDisappear {
                recordReadingPosition()
            }
            .onChange(of: session.selectedBindingKey) { _, _ in
                Task { await refreshModelAvailability() }
            }
        }
    }

    private var sessionTitle: String {
        guard let sessionID = session.attachedSessionId,
              let hostID = model.currentHost?.id
        else { return "会话" }
        let fallback = session.attachedSummary?.title ?? "会话 \(sessionID)"
        return model.sessionDisplayTitle(hostID: hostID, sessionID: sessionID, fallback: fallback)
    }

    // MARK: - 头部（常驻，AC-08.12）

    /// 副信息行：合并 host·地址与模型名，避免多行平铺 meta（spec P1 AC-4/AC-5）。
    private var secondaryLine: String {
        let hostPart = currentHost.map { "\($0.name) · \($0.address)" }
        let modelPart = selectedModelLabel
        switch (hostPart, modelPart.isEmpty) {
        case let (host?, false): return "\(host) · \(modelPart)"
        case let (host?, true): return host
        case (nil, false): return modelPart
        case (nil, true): return ""
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: PISpacing.s8) {
            // 主状态行：权限 + 会话模式 + 连接状态（原则 1：回来第一眼看到运行状态）。
            HStack(spacing: PISpacing.s8) {
                PIPermissionBadge(mode: session.permissionMode)
                Text(session.sessionMode.title)
                    .font(PIFont.captionStrong)
                    .foregroundStyle(PIColor.text2)
                Spacer()
                Circle()
                    .fill(connection.state.isOnline ? PIColor.success : PIColor.warning)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(connection.state.displayText)
                    .font(PIFont.captionStrong)
                    .foregroundStyle(connection.state.isOnline ? PIColor.success : PIColor.warning)
            }
            // 副信息行：host·地址 与模型合并为一行 meta，弱化次要信息。
            Text(secondaryLine)
                .font(PIFont.meta)
                .foregroundStyle(PIColor.text3)
                .lineLimit(1)
            if session.isTurnRunning {
                HStack(spacing: PISpacing.s8) {
                    Text(session.runningTurnId.map { "正在运行 \($0)" } ?? "正在运行")
                        .font(PIFont.captionStrong)
                        .foregroundStyle(PIColor.text2)
                        .accessibilityIdentifier("conversation.runningTurn")
                    Spacer()
                    Button(role: .destructive) {
                        Task { await session.interrupt() }
                    } label: {
                        Label("中止", systemImage: "stop.circle")
                            .font(PIFont.caption)
                    }
                    .accessibilityIdentifier("conversation.interrupt")
                    .disabled(!session.canInterrupt || session.isBusy)
                }
            }
        }
        .padding(.horizontal, PIMetrics.pageMargin)
        .padding(.vertical, PISpacing.s8)
        .background(PIColor.surface)
    }

    // MARK: - 状态区

    @ViewBuilder
    private var statusArea: some View {
        if let error = session.lastError {
            PIStatusBanner(kind: .danger, text: "操作未完成", detail: error)
                .onTapGesture { session.clearError() }
        }
        if let notice = session.notice {
            PIStatusBanner(kind: .success, text: notice, detail: "点一下收起")
                .onTapGesture { session.clearNotice() }
        }
        if !connection.state.isOnline {
            PIStatusBanner(
                kind: .warning,
                text: "离线，内容可能不是最新",
                detail: connection.state.detail.map { "\(connection.state.displayText)：\($0)" }
                    ?? "隧道未建立时只能读到本机缓存；发送与审批已禁用。"
            )
        } else if session.attachedSessionId == nil {
            VStack(alignment: .leading, spacing: PISpacing.s8) {
                PIStatusBanner(kind: .info, text: "还没有打开会话", detail: "到项目页选择或新建一个会话。")
                Button("去项目页") { model.switchRoot(.projects) }
                    .buttonStyle(.borderless)
            }
        } else {
            switch session.modelAvailability {
            case .available:
                EmptyView()
            case .checking:
                PIStatusBanner(
                    kind: .info,
                    text: "正在检查模型可用性",
                    detail: "发送会在服务器确认 provider、模型与密钥都可用后放行。"
                )
            case .unavailable(let reason), .unknown(let reason):
                PIStatusBanner(
                    kind: .warning,
                    text: "模型暂不可用",
                    detail: reason,
                    actionTitle: isCheckingModelAvailability ? "正在检查…" : "重新检查",
                    action: {
                        Task { await refreshModelAvailability() }
                    }
                )
                Button("选择其他模型") { showingConfig = true }
                    .buttonStyle(.borderless)
            }
        }
    }

    // MARK: - 线程

    private var threadSection: some View {
        VStack(alignment: .leading, spacing: PISpacing.s8) {
            PISectionHeader(text: "消息")
            if session.view.items.isEmpty {
                PIListRow(
                    title: "这个会话还没有消息",
                    subtitle: "在下方输入框发出第一条指令",
                    isEnabled: false,
                    showsDivider: false
                )
            } else {
                ForEach(session.view.items, id: \.id) { item in
                    itemRow(item)
                        .id(scrollID(for: item.id))
                        .background {
                            ReadingRestoreAnchor(
                                itemID: item.id,
                                targetID: readingRestoreTargetItemID,
                                requestID: readingRestoreRequestID,
                                onUserInteraction: {
                                    guard isRestoringReadingPosition else { return }
                                    readingRestoreTargetItemID = nil
                                    isRestoringReadingPosition = false
                                    hasNewBelow = newMessagesDuringRestore
                                }
                            )
                        }
                        .background {
                            GeometryReader { frame in
                                Color.clear.preference(
                                    key: ConversationItemFrameKey.self,
                                    value: [
                                        item.id: frame.frame(in: .named("conversation-scroll"))
                                    ]
                                )
                            }
                        }
                }
            }
            if !session.activeItems.isEmpty {
                Text("正在生成 \(session.activeItems.count) 条内容…")
                    .font(PIFont.caption)
                    .foregroundStyle(PIColor.text2)
                    .accessibilityIdentifier("conversation.streamingCount")
            }
        }
    }

    @ViewBuilder
    private func itemRow(_ item: RACPItem) -> some View {
        if item.toolName != nil || item.role == "tool" || item.kind?.lowercased().contains("tool") == true {
            ToolItemCard(item: item)
        } else if item.role == "user" {
            // 用户消息：右侧淡蓝气泡、无角色标签（design-system.md §7 / spec AC-1）。
            HStack(alignment: .top, spacing: 0) {
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: PISpacing.s8) {
                    if !item.attachments.isEmpty {
                        VStack(alignment: .leading, spacing: PISpacing.s8) {
                            ForEach(item.attachments, id: \.id) { attachment in
                                AttachmentThumbnailView(attachment: attachment)
                            }
                        }
                    }
                    Text(item.text ?? item.kind ?? "条目")
                        .font(PIFont.body)
                        .foregroundStyle(PIColor.text)
                        .fixedSize(horizontal: false, vertical: true)
                    if let status = item.status {
                        Text(status)
                            .font(PIFont.meta)
                            .foregroundStyle(PIColor.text2)
                    }
                }
                .padding(.horizontal, PISpacing.s12)
                .padding(.vertical, PISpacing.s8)
                .frame(maxWidth: 320, alignment: .leading)
                .background(PIColor.accentSoft, in: RoundedRectangle(cornerRadius: PIRadius.card, style: .continuous))
            }
        } else {
            // Agent / 系统消息：左对齐、无气泡、无头像、无角色标签（design-system.md §7 / spec AC-2）。
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: PISpacing.s8) {
                    if !item.attachments.isEmpty {
                        VStack(alignment: .leading, spacing: PISpacing.s8) {
                            ForEach(item.attachments, id: \.id) { attachment in
                                AttachmentThumbnailView(attachment: attachment)
                            }
                        }
                    }
                    Text(item.text ?? item.kind ?? "条目")
                        .font(PIFont.body)
                        .foregroundStyle(PIColor.text)
                        .fixedSize(horizontal: false, vertical: true)
                    if let status = item.status {
                        Text(status)
                            .font(PIFont.meta)
                            .foregroundStyle(PIColor.text3)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var readingContextKey: String? {
        guard let hostID = model.currentHost?.id,
              let sessionID = session.attachedSessionId
        else { return nil }
        return "\(hostID.uuidString):\(sessionID)"
    }

    /// 附加会话 ID 会先到，`session/view` 可能晚到；视图真的换成目标会话后要再触发一次恢复。
    private var readingRestoreTaskKey: String? {
        guard let context = readingContextKey else { return nil }
        return "\(context):\(session.view.sessionId ?? "pending")"
    }

    private func scrollID(for itemID: String) -> String {
        "conversation-item:\(itemID)"
    }

    @MainActor
    private func restoreReadingPosition(proxy: ScrollViewProxy) async {
        readingRestoreGeneration &+= 1
        let generation = readingRestoreGeneration
        defer {
            if readingRestoreGeneration == generation {
                isRestoringReadingPosition = false
            }
        }
        guard let hostID = model.currentHost?.id,
              let sessionID = session.attachedSessionId,
              let contextKey = readingContextKey
        else {
            activeReadingHostID = nil
            activeReadingSessionID = nil
            topVisibleItemID = nil
            return
        }

        activeReadingHostID = hostID
        activeReadingSessionID = sessionID
        topVisibleItemID = nil
        lastMeasuredTopItemID = nil
        readingRestoreTargetItemID = nil
        newMessagesDuringRestore = false
        restoreBaselineReady = false
        restoreBaselineCount = 0
        restoreBaselineLastItemID = nil
        hasNewBelow = false
        isRestoringReadingPosition = true

        // `attachedSessionId` 会早于 sessionView 完成更新；等这一代会话的视图落位后再恢复。
        for _ in 0..<60 {
            guard !Task.isCancelled, readingContextKey == contextKey else { return }
            if session.view.sessionId == sessionID { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard !Task.isCancelled,
              readingContextKey == contextKey,
              session.view.sessionId == sessionID
        else { return }
        restoreBaselineCount = session.view.items.count
        restoreBaselineLastItemID = session.view.items.last?.id
        restoreBaselineReady = true

        // Large restored snapshots need multiple layout passes before the target's
        // UIKit anchor can drive the scroll view and its frame can be confirmed.
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled, readingContextKey == contextKey else { return }

        let saved = model.readingPosition(hostID: hostID, sessionID: sessionID)
        if let saved,
           !saved.isNearBottom,
           let itemID = saved.lastVisibleItemID,
           session.view.items.contains(where: { $0.id == itemID }) {
            readingRestoreTargetItemID = itemID
            isNearBottom = false
            hasNewBelow = newMessagesDuringRestore
            readingRestoreRequestID &+= 1
            for _ in 0..<10 where isRestoringReadingPosition {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled,
                      readingContextKey == contextKey,
                      readingRestoreTargetItemID == itemID
                else { return }
                readingRestoreRequestID &+= 1
            }
            if isRestoringReadingPosition,
               readingRestoreTargetItemID == itemID {
                readingRestoreTargetItemID = nil
                topVisibleItemID = itemID
                isRestoringReadingPosition = false
                isNearBottom = false
                hasNewBelow = newMessagesDuringRestore
                return
            }
            isNearBottom = false
            hasNewBelow = newMessagesDuringRestore
        } else {
            readingRestoreTargetItemID = nil
            proxy.scrollTo("thread-bottom", anchor: .bottom)
            topVisibleItemID = session.view.items.last?.id
            isNearBottom = true
            hasNewBelow = false
        }

        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled, readingContextKey == contextKey else { return }
        isRestoringReadingPosition = false
        recordReadingPosition()
    }

    private func recordReadingPosition() {
        guard !isRestoringReadingPosition,
              let hostID = activeReadingHostID,
              let sessionID = activeReadingSessionID,
              model.currentHost?.id == hostID,
              session.attachedSessionId == sessionID
        else { return }
        model.rememberReadingPosition(
            hostID: hostID,
            sessionID: sessionID,
            lastVisibleItemID: topVisibleItemID ?? session.view.items.last?.id,
            isNearBottom: isNearBottom
        )
    }

    private func recordVisibleMessageCount() {
        guard let sessionID = session.attachedSessionId,
              let hostID = model.currentHost?.id
        else { return }
        model.updateSessionActivity(
            hostID: hostID,
            sessionID: sessionID,
            messageCount: session.view.items.count
        )
    }

    private func renameCurrentSession() {
        guard let sessionID = session.attachedSessionId,
              let hostID = model.currentHost?.id
        else { return }
        if model.renameSession(hostID: hostID, sessionID: sessionID, title: renameDraft) {
            session.clearError()
        } else {
            model.showToast("会话标题不能为空")
        }
    }

    private func archiveCurrentSession() {
        guard let sessionID = session.attachedSessionId,
              let hostID = model.currentHost?.id
        else { return }
        let projectID = session.attachedSummary?.projectId
            ?? model.sessionBinding(hostID: hostID, sessionID: sessionID)?.projectID
        let next = connection.sessions
            .filter {
                $0.id != sessionID
                    && $0.projectId == projectID
                    && model.sessionBinding(hostID: hostID, sessionID: $0.id).map {
                        !$0.isArchived && !$0.isDeleted
                    } == true
            }
            .sorted {
                (model.sessionBinding(hostID: hostID, sessionID: $0.id)?.lastActivityAt ?? .distantPast)
                    > (model.sessionBinding(hostID: hostID, sessionID: $1.id)?.lastActivityAt ?? .distantPast)
            }
            .first
        model.setSessionArchived(hostID: hostID, sessionID: sessionID, archived: true)
        model.rememberSession(nil)
        if let next {
            Task {
                await connection.session.attach(sessionId: next.id)
                model.rememberSession(next.id)
            }
        } else {
            session.detach()
            model.switchRoot(.projects)
        }
    }

    /// 离线时只显示用户在侧边栏显式点过、且按当前 Host 保存的会话。
    private var cachedSessionId: String? {
        guard let hostID = model.currentHost?.id else { return nil }
        return model.cachedSessionSelectionID(for: hostID)
    }

    @ViewBuilder
    private func offlineThread(sessionId: String) -> some View {
        let cached = connection.cachedSession(sessionId: sessionId)
        let entries = cached?.entries ?? []
        VStack(alignment: .leading, spacing: PISpacing.s8) {
            PISectionHeader(text: "缓存的历史（只读）")
            PIStatusBanner(
                kind: .warning,
                text: "离线只读 · 缓存可能已过期",
                detail: "审批卡只用于展示，不能在离线状态提交；恢复在线后会按服务器快照重建。"
            )
            if let approvals = cached?.approvals, !approvals.isEmpty {
                PISectionHeader(text: "缓存的待审批（\(approvals.count)）")
                ForEach(approvals, id: \.id) { approval in
                    offlineApprovalCard(approval)
                }
            }
            if let draft = cached?.draft,
               !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                PICard {
                    VStack(alignment: .leading, spacing: PISpacing.s4) {
                        Text("未发送草稿（离线只读）")
                            .font(PIFont.captionStrong)
                            .foregroundStyle(PIColor.text2)
                        Text(draft.text)
                            .font(PIFont.body)
                            .foregroundStyle(PIColor.text)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("恢复在线并完成快照重建后可重新编辑或发送。")
                            .font(PIFont.meta)
                            .foregroundStyle(PIColor.text3)
                    }
                }
            }
            if cached == nil {
                PIListRow(
                    title: "本机没有这个会话的缓存",
                    subtitle: "缓存只保存曾在联网时读到的内容，最多 \(PersistedState.maxCachedConversations) 个会话",
                    isEnabled: false,
                    showsDivider: false
                )
            } else if entries.isEmpty {
                PIListRow(
                    title: "缓存里没有文本消息",
                    subtitle: "审批卡或未发送草稿仍可在上方查看，全部为只读。",
                    isEnabled: false,
                    showsDivider: false
                )
            } else {
                ForEach(entries, id: \.id) { entry in
                    PICard {
                        VStack(alignment: .leading, spacing: PISpacing.s4) {
                            Text(entry.displayText)
                                .font(PIFont.body)
                                .foregroundStyle(PIColor.text)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(PIFont.meta)
                                .foregroundStyle(PIColor.text3)
                        }
                    }
                }
            }
        }
    }

    private func offlineApprovalCard(_ approval: OfflineSessionApproval) -> some View {
        let contract = cachedApprovalIsContract(approval)
        return PICard {
            VStack(alignment: .leading, spacing: PISpacing.s8) {
                HStack {
                    Text(contract ? "计划 / 目标契约" : "权限请求")
                        .font(PIFont.captionStrong)
                        .foregroundStyle(PIColor.text2)
                    Spacer()
                    Text(approval.offlineStatusText)
                        .font(PIFont.meta)
                        .foregroundStyle(PIColor.warning)
                }
                Text(cachedApprovalSummary(approval))
                    .font(PIFont.body)
                    .foregroundStyle(PIColor.text)
                    .fixedSize(horizontal: false, vertical: true)
                if let revision = approval.revision {
                    Text("缓存 revision：\(revision)")
                        .font(PIFont.meta)
                        .foregroundStyle(PIColor.text3)
                }
                if contract {
                    HStack(spacing: PISpacing.s8) {
                        Button("批准") {}
                            .buttonStyle(.borderedProminent)
                        Button("驳回", role: .destructive) {}
                            .buttonStyle(.bordered)
                    }
                    .disabled(true)
                } else {
                    HStack(spacing: PISpacing.s8) {
                        Button("允许一次") {}
                        Button("本会话允许") {}
                        Button("拒绝", role: .destructive) {}
                    }
                    .buttonStyle(.bordered)
                    .disabled(true)
                }
                Text("离线状态不可提交；恢复在线后只使用新快照里的卡片与 revision。")
                    .font(PIFont.meta)
                    .foregroundStyle(PIColor.text3)
            }
        }
    }

    private func cachedApprovalIsContract(_ approval: OfflineSessionApproval) -> Bool {
        let kind = approval.payload.value(at: ["kind"])?.stringValue?.lowercased() ?? ""
        return kind.contains("plan") || kind.contains("goal") || kind.contains("contract")
    }

    private func cachedApprovalSummary(_ approval: OfflineSessionApproval) -> String {
        if let tool = approval.payload.value(at: ["toolName"])?.stringValue {
            return "工具：\(tool)"
        }
        if let text = approval.payload.value(at: ["summary"])?.stringValue {
            return text
        }
        if let text = approval.payload.value(at: ["detail"])?.stringValue {
            return text
        }
        return "服务器当时没有给出可显示的摘要（id \(approval.id)）"
    }

    // MARK: - 审批（AC-10 / AC-12）

    @ViewBuilder
    private var approvalSection: some View {
        ForEach(orderedApprovals, id: \.id) { card in
            let availability = session.availability(for: card.id)
            PICard {
                VStack(alignment: .leading, spacing: PISpacing.s8) {
                    HStack {
                        Text(SessionController.isContract(card) ? "计划 / 目标契约" : "权限请求")
                            .font(PIFont.captionStrong)
                            .foregroundStyle(PIColor.text2)
                        Spacer()
                        if let status = availability.statusText {
                            Text(status)
                                .font(PIFont.meta)
                                .foregroundStyle(PIColor.warning)
                        }
                    }
                    Text(summary(of: card))
                        .font(PIFont.body)
                        .foregroundStyle(PIColor.text)
                        .fixedSize(horizontal: false, vertical: true)
                    if availability.isActionable {
                        if SessionController.isContract(card) {
                            HStack(spacing: PISpacing.s8) {
                                PIApprovalPrimaryButton(title: "批准", isEnabled: !(session.isBusy || !connection.state.isOnline)) {
                                    Task { await session.decideContract(approvalId: card.id, decision: .approve) }
                                }
                                PIDangerOutlineButton(title: "驳回", isEnabled: !(session.isBusy || !connection.state.isOnline)) {
                                    Task { await session.decideContract(approvalId: card.id, decision: .reject) }
                                }
                            }
                        } else {
                            VStack(alignment: .leading, spacing: PISpacing.s8) {
                                HStack(spacing: PISpacing.s8) {
                                    PIApprovalPrimaryButton(title: "允许一次", isEnabled: !(session.isBusy || !connection.state.isOnline)) {
                                        Task { await session.decide(approvalId: card.id, decision: .allowOnce) }
                                    }
                                    PIApprovalSecondaryButton(title: "本会话允许", isEnabled: !(session.isBusy || !connection.state.isOnline)) {
                                        Task { await session.decide(approvalId: card.id, decision: .allowSession) }
                                    }
                                }
                                // 危险决策与安全决策视觉不共位：独立一行 + 上方留白（design-system.md 原则 2）。
                                HStack(spacing: PISpacing.s8) {
                                    PIDangerOutlineButton(title: "拒绝", isEnabled: !(session.isBusy || !connection.state.isOnline)) {
                                        Task { await session.decide(approvalId: card.id, decision: .deny) }
                                    }
                                }
                                .padding(.top, PISpacing.s4)
                            }
                        }
                    } else {
                        Text("这张卡已不可提交：请等待下一次同步重新生成。")
                            .font(PIFont.caption)
                            .foregroundStyle(PIColor.text3)
                    }
                }
            }
        }
        ForEach(Array(session.view.expiredApprovalIds).sorted(), id: \.self) { expiredId in
            if session.availability(for: expiredId) == .expired {
                PICard {
                    HStack {
                        Text("审批 \(expiredId) 已失效")
                            .font(PIFont.caption)
                            .foregroundStyle(PIColor.text3)
                        Spacer()
                    }
                }
            }
        }
    }

    /// 可提交的卡片排在最前：审批卡片区在滚动内容最前面，用户被带过去时第一眼就该能处理它；
    /// 已失效（不在快照里）的卡片沉到后面——AC-14.5 只要求标失效，没有要求保留到达顺序。
    private var orderedApprovals: [RACPApprovalRequest] {
        session.pendingApprovals.enumerated()
            .sorted { lhs, rhs in
                let left = session.availability(for: lhs.element.id).isActionable
                let right = session.availability(for: rhs.element.id).isActionable
                if left != right { return left }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    private func summary(of card: RACPApprovalRequest) -> String {
        if let tool = card.toolName { return "工具：\(tool)" }
        if let text = card.payload.value(at: ["summary"])?.stringValue { return text }
        if let text = card.payload.value(at: ["detail"])?.stringValue { return text }
        return "服务器没有给出可显示的摘要（id \(card.id)）"
    }

    // MARK: - 提问（AC-11）

    @ViewBuilder
    private var inputSection: some View {
        ForEach(session.pendingInputs, id: \.id) { card in
            let questions = InputQuestionParser.questions(from: card)
            PICard {
                VStack(alignment: .leading, spacing: PISpacing.s8) {
                    Text("需要你回答")
                        .font(PIFont.captionStrong)
                        .foregroundStyle(PIColor.text2)
                    if questions.isEmpty {
                        Text("这张提问卡没有可解析的问题：只能跳过。")
                            .font(PIFont.caption)
                            .foregroundStyle(PIColor.text3)
                    }
                    ForEach(questions) { question in
                        VStack(alignment: .leading, spacing: PISpacing.s4) {
                            Text(question.prompt)
                                .font(PIFont.body)
                                .foregroundStyle(PIColor.text)
                                .fixedSize(horizontal: false, vertical: true)
                            if question.options.isEmpty {
                                Text("该问题没有提供选项，提交时记为跳过。")
                                    .font(PIFont.meta)
                                    .foregroundStyle(PIColor.text3)
                            } else {
                                ForEach(question.options, id: \.self) { option in
                                    Toggle(option, isOn: binding(for: card.id, question: question.id, option: option))
                                        .toggleStyle(.button)
                                        .font(PIFont.caption)
                                }
                            }
                        }
                    }
                    HStack(spacing: PISpacing.s8) {
                        Button("提交回答") {
                            let answers = InputQuestionParser.answers(
                                selections: selections[card.id] ?? [:],
                                questionCount: questions.count
                            )
                            Task {
                                await session.answer(inputId: card.id, answers: answers)
                                selections[card.id] = nil
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(session.isBusy || !connection.state.isOnline)
                        Button("全部跳过") {
                            let answers = InputQuestionParser.answers(
                                selections: [:],
                                questionCount: questions.count
                            )
                            Task { await session.answer(inputId: card.id, answers: answers) }
                        }
                        .buttonStyle(.bordered)
                        .disabled(session.isBusy || !connection.state.isOnline)
                    }
                }
            }
        }
    }

    private func binding(for cardId: String, question: Int, option: String) -> Binding<Bool> {
        Binding(
            get: { selections[cardId]?[question]?.contains(option) ?? false },
            set: { isOn in
                var card = selections[cardId] ?? [:]
                var set = card[question] ?? []
                if isOn { set.insert(option) } else { set.remove(option) }
                card[question] = set
                selections[cardId] = card
            }
        )
    }

    // MARK: - 排队（AC-13）

    @ViewBuilder
    private var queueSection: some View {
        if !session.queuedTurns.isEmpty {
            VStack(alignment: .leading, spacing: PISpacing.s8) {
                PISectionHeader(text: "排队中（\(session.queuedTurns.count)）")
                ForEach(session.queuedTurns) { turn in
                    PICard {
                        HStack(spacing: PISpacing.s8) {
                            VStack(alignment: .leading, spacing: PISpacing.s4) {
                                Text(turn.text ?? "排队指令 \(turn.id)")
                                    .font(PIFont.body)
                                    .foregroundStyle(PIColor.text)
                                    .lineLimit(2)
                                Text("当前 turn 结束后自动开始")
                                    .font(PIFont.meta)
                                    .foregroundStyle(PIColor.text3)
                            }
                            Spacer()
                            Button("取消", role: .destructive) {
                                Task { await session.cancelQueued(turnId: turn.id) }
                            }
                            .buttonStyle(.bordered)
                            .disabled(session.isBusy || !connection.state.isOnline)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 输入栏

    private var composer: some View {
        // Read the main-actor-isolated admission into a plain value once: the
        // PhotosPicker label runs in a Sendable closure and must not touch
        // `session` directly (Swift 6).
        let allowsAttachments = session.sendAdmission.isAllowed
        return VStack(alignment: .leading, spacing: PISpacing.s8) {
            composerConfigurationChips
            if case .queue = session.sendAdmission {
                Text("当前 turn 仍在运行：发送会排成下一条指令（P0 不支持改写正在运行的 turn）")
                    .font(PIFont.meta)
                    .foregroundStyle(PIColor.text2)
            }
            if !session.isOnline {
                Text("离线：发送已禁用")
                    .font(PIFont.meta)
                    .foregroundStyle(PIColor.warning)
            }
            if !session.pendingAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: PISpacing.s8) {
                        ForEach(session.pendingAttachments, id: \.id) { attachment in
                            HStack(spacing: PISpacing.s4) {
                                Image(systemName: "photo")
                                Text(attachment.fileName)
                                    .lineLimit(1)
                                Button {
                                    session.removeAttachment(id: attachment.id)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.plain)
                            }
                            .font(PIFont.meta)
                            .padding(.horizontal, PISpacing.s8)
                            .padding(.vertical, PISpacing.s4)
                            .background(PIColor.surface2, in: Capsule())
                        }
                    }
                }
            }
            HStack(alignment: .bottom, spacing: PISpacing.s8) {
                PhotosPicker(
                    selection: $selectedPhotos,
                    maxSelectionCount: 10,
                    matching: .images
                ) {
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(allowsAttachments ? PIColor.text2 : PIColor.text3)
                        .frame(width: PIMetrics.minHitTarget, height: PIMetrics.minHitTarget)
                        .contentShape(Rectangle())
                }
                .disabled(!session.sendAdmission.isAllowed || session.attachedSessionId == nil)
                .accessibilityLabel("添加图片附件")
                .accessibilityHint("最多选择 10 张 JPEG、PNG 或 WebP 图片")
                .onChange(of: selectedPhotos) { items in
                    guard !items.isEmpty else { return }
                    let selection = session.attachmentSelectionGeneration
                    let photoSelection = UUID()
                    photoSelectionID = photoSelection
                    Task {
                        for item in items {
                            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                            guard session.attachmentSelectionGeneration == selection,
                                  photoSelectionID == photoSelection else { break }
                            let mime = imageMimeType(data)
                            let ext = mime == "image/png" ? "png" : (mime == "image/webp" ? "webp" : "jpg")
                            await session.addImage(
                                data: data,
                                mimeType: mime,
                                fileName: "photo-\(UUID().uuidString).\(ext)"
                            )
                        }
                        if photoSelectionID == photoSelection { selectedPhotos = [] }
                    }
                }
                TextField("给 Agent 的指令", text: $session.draftText, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)
                    .font(PIFont.body)
                    .foregroundStyle(PIColor.text)
                    .padding(.vertical, PISpacing.s8)
                    .disabled(!session.sendAdmission.isAllowed || session.attachedSessionId == nil)
                    .accessibilityIdentifier("conversation.composer")
                Button {
                    scrollToBottomRequest &+= 1
                    Task {
                        await refreshModelAvailability()
                        await session.send()
                    }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(session.canSend && !session.isBusy ? PIColor.accent : PIColor.text3)
                        .frame(width: PIMetrics.minHitTarget, height: PIMetrics.minHitTarget)
                        .contentShape(Rectangle())
                }
                .disabled(!session.canSend || session.isBusy)
                .accessibilityLabel("发送")
            }
            .padding(.leading, PISpacing.s4)
            .padding(.trailing, PISpacing.s4)
            .padding(.vertical, PISpacing.s4)
            .background(PIColor.surface, in: Capsule(style: .continuous))
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(PIColor.separator, lineWidth: PIMetrics.hairline)
            )
            .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
            Text("支持 JPEG、PNG、WebP；单张不超过 20 MiB，每条消息最多 10 张")
                .font(PIFont.meta)
                .foregroundStyle(PIColor.text3)
        }
        .padding(.horizontal, PIMetrics.pageMargin)
        .padding(.vertical, PISpacing.s8)
        .background(PIColor.surface)
    }

    private func imageMimeType(_ data: Data) -> String {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if data.starts(with: [0x52, 0x49, 0x46, 0x46]) { return "image/webp" }
        return "image/jpeg"
    }

    private var composerConfigurationChips: some View {
        HStack(spacing: PISpacing.s8) {
            configurationChip(
                title: session.sessionMode.title,
                tint: PIColor.text2,
                identifier: "composer.modeChip"
            )
            configurationChip(
                title: session.permissionMode.title,
                tint: session.permissionMode.tint,
                identifier: "composer.permissionChip"
            )
            Spacer(minLength: PISpacing.s4)
            configurationChip(
                title: selectedModelLabel,
                tint: PIColor.text2,
                identifier: "composer.modelChip",
                maxWidth: 190,
                alignment: .trailing
            )
            if session.thinkingLevel != nil, selectedModelDeclaresThinking {
                configurationChip(
                    title: session.thinkingLevel?.rawValue ?? "",
                    tint: PIColor.text2,
                    identifier: "composer.thinkingChip"
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func configurationChip(
        title: String,
        tint: Color,
        identifier: String,
        maxWidth: CGFloat? = nil,
        alignment: Alignment = .leading
    ) -> some View {
        Button {
            showingConfig = true
        } label: {
            HStack(spacing: PISpacing.s4) {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(PIColor.text3)
            }
            .font(PIFont.metaSmall)
            .foregroundStyle(tint)
            .padding(.horizontal, PISpacing.s8 + 1)
            .frame(minHeight: 32)
            .frame(maxWidth: maxWidth, alignment: alignment)
            .background(PIColor.surface2, in: Capsule())
            // 视觉 32pt 高，热区补足到 44pt（spec AC-7）。
            .padding(.vertical, (PIMetrics.minHitTarget - 32) / 2)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(
            session.isTurnRunning
                || session.isBusy
                || !connection.state.isOnline
                || session.attachedSessionId == nil
        )
        .accessibilityIdentifier(identifier)
        .accessibilityHint(
            session.isTurnRunning
                ? "等待当前轮次结束后才能切换"
                : (session.isBusy ? "等待当前操作完成" : "打开会话配置")
        )
    }

    private var selectedModelDeclaresThinking: Bool {
        guard let providerID = session.selectedProviderId,
              let modelID = session.selectedModelId
        else { return false }
        for group in model.currentModelGroups where group.providerId == providerID {
            if let record = group.models.first(where: { $0.modelId == modelID }) {
                return !record.thinkingLevels.isEmpty
            }
        }
        return false
    }

    private func refreshModelAvailability() async {
        guard connection.state.isOnline,
              let sessionID = session.attachedSessionId,
              let host = model.currentHost
        else {
            legacyOnlyProviderIDs = []
            session.markModelAvailabilityUnknown("服务器离线或尚未打开会话")
            return
        }
        modelAvailabilityGeneration &+= 1
        let generation = modelAvailabilityGeneration
        let bindingKey = session.selectedBindingKey
        isCheckingModelAvailability = true
        session.markModelAvailabilityChecking()
        defer {
            if generation == modelAvailabilityGeneration {
                isCheckingModelAvailability = false
            }
        }
        do {
            // Prefer the v2 Host's own provider store; fall back to the legacy
            // SSH-based binding probe for old v1 Hosts.
            let status = try await connection.hostV2BindingStatus(sessionId: sessionID)
            guard generation == modelAvailabilityGeneration,
                  model.currentHost?.id == host.id,
                  session.attachedSessionId == sessionID,
                  session.selectedBindingKey == bindingKey
            else { return }
            // A successful v2 probe means the Host keeps providers in the v2
            // store; anything our local catalog knows only from the legacy store
            // cannot drive a turn on it.
            let legacyOnly = Set(
                model.currentModelProviders
                    .filter { $0.hostV2Mirror != true }
                    .map(\.providerId)
            )
            legacyOnlyProviderIDs = legacyOnly
            if let reason = Self.legacyOnlyReason(status: status, legacyOnly: legacyOnly) {
                // Self-heal when possible: mirror the legacy-only provider into
                // the v2 store and rebind, if we still hold its key locally.
                let healed = await mirrorLegacyOnlyProvider(
                    pinnedProviderId: status.pinnedProviderId,
                    pinnedModelId: status.pinnedModelId,
                    host: host
                )
                if healed {
                    session.markModelAvailabilityChecking()
                } else {
                    session.markModelUnavailable(reason)
                }
            } else {
                session.applyModelAvailability(status)
            }
        } catch {
            legacyOnlyProviderIDs = []
            do {
                let receipt = try await connection.providerBindingStatus(
                    record: host,
                    sessionId: sessionID
                )
                guard generation == modelAvailabilityGeneration,
                      model.currentHost?.id == host.id,
                      session.attachedSessionId == sessionID,
                      session.selectedBindingKey == bindingKey
                else { return }
                switch receipt {
                case .success(let status):
                    session.applyModelAvailability(status)
                case .failure(let failure):
                    session.markModelAvailabilityUnknown(failure.displayMessage)
                case .unparseable(let reason):
                    session.markModelAvailabilityUnknown("服务器返回的绑定状态无法解析：\(reason)")
                }
            } catch {
                guard generation == modelAvailabilityGeneration,
                      model.currentHost?.id == host.id,
                      session.attachedSessionId == sessionID,
                      session.selectedBindingKey == bindingKey
                else { return }
                session.markModelAvailabilityUnknown(ConnectionErrorText.describe(error))
            }
        }
    }

    /// When the v2 Host reports the pinned provider as missing but our local
    /// catalog knows it only from the legacy store, the real cause is the
    /// two-store split — name it and point at the fix (re-import writes the
    /// provider and its key into pi-host-v2) instead of a generic message.
    private static func legacyOnlyReason(
        status: ProviderBindingStatus,
        legacyOnly: Set<String>
    ) -> String? {
        guard status.available != true,
              status.unavailableReason == "provider_missing",
              let providerId = status.pinnedProviderId,
              legacyOnly.contains(providerId)
        else { return nil }
        return "该模型服务只导入到了服务器的旧存储，尚未同步到 pi-host-v2，因此无法驱动会话。"
            + "请到 设置 → 模型服务 重新导入这个服务（导入会一并写入 pi-host-v2 并保存密钥）。"
    }

    /// Best-effort self-heal for the two-store split (§7): when a session is
    /// bound to a provider that exists only in the legacy store, and we still
    /// hold its API key in the Keychain, mirror it into the v2 Host store and
    /// rebind the session to the mirrored provider id. Returns true when a
    /// rebind was issued (a fresh availability check follows).
    private func mirrorLegacyOnlyProvider(
        pinnedProviderId: String?,
        pinnedModelId: String?,
        host: HostRecord
    ) async -> Bool {
        guard let pinnedProviderId, let pinnedModelId else { return false }
        guard let local = model.currentModelProviders.first(where: {
            $0.providerId == pinnedProviderId && $0.hostV2Mirror != true
        }) else { return false }
        guard let key = KeychainStore.loadProviderKey(hostID: host.id, providerId: pinnedProviderId),
              let operation = model.providerOperationContext(for: host)
        else { return false }
        let specs = local.models.map(\.providerSpec)
        guard let mirrored = try? await connection.registerHostProvider(
            name: local.name,
            vendorKey: "mirror-\(UUID().uuidString)",
            baseURL: local.baseURL,
            apiKey: key,
            models: specs
        ), model.canApplyProviderOperation(operation) else { return false }
        let input = ProviderCreateInput(
            name: local.name,
            vendorKey: mirrored.vendorKey,
            type: mirrored.type,
            protocol: mirrored.protocolName,
            authKind: mirrored.authKind,
            baseUrl: local.baseURL,
            models: specs,
            defaultModelId: local.defaultModelId
        )
        guard model.recordImportedProvider(
            context: operation,
            input: input,
            providerId: mirrored.id,
            serverDefaultSet: false,
            legacyProviderId: pinnedProviderId,
            hostV2Mirror: true
        ) else { return false }
        await session.configure(providerId: mirrored.id, modelId: pinnedModelId)
        return true
    }

    private var selectedModelLabel: String {
        guard let providerID = session.selectedProviderId,
              let modelID = session.selectedModelId
        else { return "模型未绑定" }
        for group in model.currentModelGroups where group.providerId == providerID {
            if let record = group.models.first(where: { $0.modelId == modelID }) {
                return "\(group.name) · \(record.displayName)"
            }
        }
        return "\(providerID) · \(modelID)"
    }
}

private struct ConversationContentBottomKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ConversationItemFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct ToolItemCard: View {
    let item: RACPItem
    private let presentation: ToolResultPresentation
    @State private var expanded = false
    @State private var renderStartedAt: TimeInterval?
    @State private var renderMilliseconds: Double?
    @State private var firstFrameMilliseconds: Double?
    private let measuresRender: Bool

    init(item: RACPItem) {
        self.item = item
        presentation = ToolResultPresentation(text: item.text ?? "")
#if DEBUG
        measuresRender = ProcessInfo.processInfo.environment["PI_IOS_MEASURE_TOOL_RENDER"] == "1"
#else
        measuresRender = false
#endif
    }

    var body: some View {
        PICard {
            DisclosureGroup(isExpanded: expansionBinding) {
                VStack(alignment: .leading, spacing: PISpacing.s8) {
                    if let text = item.text, !text.isEmpty {
                        Text(presentation.preview)
                            .font(PIFont.caption)
                            .foregroundStyle(PIColor.text)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("toolCard.\(item.id).preview")
                            .onAppear { finishRenderMeasurement() }
                            .background {
#if DEBUG
                                if measuresRender, let renderStartedAt {
                                    ToolFirstFrameProbe(startedAt: renderStartedAt) { milliseconds in
                                        guard firstFrameMilliseconds == nil else { return }
                                        firstFrameMilliseconds = milliseconds
                                    }
                                }
#endif
                            }
                        if let notice = presentation.truncationNotice {
                            Text(notice)
                                .font(PIFont.meta)
                                .foregroundStyle(PIColor.text3)
                                .accessibilityIdentifier("toolCard.\(item.id).truncation")
                        }
                    } else {
                        Text(emptyBodyNotice)
                            .font(PIFont.caption)
                            .foregroundStyle(PIColor.text3)
                    }
                }
                .padding(.top, PISpacing.s8)
            } label: {
                HStack(spacing: PISpacing.s8) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(PIColor.text2)
                    VStack(alignment: .leading, spacing: PISpacing.s4) {
                        Text(item.toolName.map { "工具 · \($0)" } ?? "工具调用")
                            .font(PIFont.captionStrong)
                            .foregroundStyle(PIColor.text)
                        if let status = item.status {
                            Text(status)
                                .font(PIFont.metaSmall)
                                .foregroundStyle(PIColor.text3)
                        }
                    }
                    Spacer()
                }
            }
            .tint(PIColor.text2)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("toolCard.\(item.id).toggle")
        .accessibilityValue(renderMeasurementValue)
    }

    private var expansionBinding: Binding<Bool> {
        Binding(
            get: { expanded },
            set: { next in
                if next, !expanded {
                    renderStartedAt = CACurrentMediaTime()
                    renderMilliseconds = nil
                    firstFrameMilliseconds = nil
                }
                expanded = next
            }
        )
    }

    private func finishRenderMeasurement() {
        guard measuresRender,
              renderMilliseconds == nil,
              let started = renderStartedAt
        else { return }
        renderMilliseconds = (CACurrentMediaTime() - started) * 1_000
    }

    private var renderMeasurementValue: String {
        guard let renderMilliseconds, let firstFrameMilliseconds else { return "" }
        return String(
            format: "renderMs=%.3f;firstFrameMs=%.3f",
            renderMilliseconds,
            firstFrameMilliseconds
        )
    }

    /// 运行中的工具只是还没有正文。把「还没输出」说成「服务器没有返回工具输出正文」
    /// 会让用户以为工具已经结束、结果丢了。
    private var emptyBodyNotice: String {
        switch item.status?.lowercased() {
        case nil, "streaming", "running", "pending", "in_progress":
            return "工具执行中…"
        default:
            return "服务器没有返回工具输出正文。"
        }
    }
}

#if DEBUG
private struct ToolFirstFrameProbe: UIViewRepresentable {
    let startedAt: TimeInterval
    let onFirstFrame: (Double) -> Void

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.startedAt = startedAt
        view.onFirstFrame = onFirstFrame
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {
        uiView.startedAt = startedAt
        uiView.onFirstFrame = onFirstFrame
    }

    final class ProbeView: UIView {
        var startedAt: TimeInterval = 0
        var onFirstFrame: ((Double) -> Void)?
        private var displayLink: CADisplayLink?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil {
                displayLink?.invalidate()
                displayLink = nil
                return
            }
            guard displayLink == nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(frameCommitted(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        @objc private func frameCommitted(_ link: CADisplayLink) {
            let milliseconds = (link.timestamp - startedAt) * 1_000
            link.invalidate()
            displayLink = nil
            onFirstFrame?(milliseconds)
        }
    }
}
#endif

// MARK: - 会话配置（AC-07）

private struct SessionConfigSheet: View {
    @ObservedObject var session: SessionController
    let groups: [ProviderModelGroup]
    let diagnostics: [ModelGroupingDiagnostic]
    /// Providers our local catalog knows but the connected v2 Host's own store
    /// does not (legacy-only imports); their models cannot drive a turn.
    let unavailableProviderIDs: Set<String>
    @Environment(\.dismiss) private var dismiss

    private var selectedBinding: ModelRecord? {
        flatten(groups).first {
            $0.providerId == session.selectedProviderId && $0.modelId == session.selectedModelId
        }
    }

    private var configLocked: Bool { session.isTurnRunning || session.isBusy }
    private var configEnabled: Bool { !configLocked && session.isOnline }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: PISpacing.s24) {
                    if !diagnostics.isEmpty {
                        PIStatusBanner(
                            kind: .warning,
                            text: "模型清单有重复记录",
                            detail: diagnostics.map(\.message).joined(separator: "\n")
                        )
                    }
                    if !unavailableProviderIDs.isEmpty {
                        PIStatusBanner(
                            kind: .warning,
                            text: "部分模型未同步到服务器",
                            detail: "标记为「未同步」的模型只存在于服务器的旧存储，无法在该服务器上运行。"
                                + "请到 设置 → 模型服务 重新导入对应服务（会写入 pi-host-v2）。"
                        )
                    }
                    if configLocked {
                        PIStatusBanner(
                            kind: .warning,
                            text: "当前轮次仍在运行",
                            detail: "模型、会话模式和思考档位会在本轮结束后恢复可切换。"
                        )
                    } else if !session.isOnline {
                        PIStatusBanner(
                            kind: .warning,
                            text: "服务器离线",
                            detail: "恢复连接后才能提交会话配置。"
                        )
                    }
                    PIGroup("权限模式", footer: "改动通过 `session/configure` 下发，运行中的轮次不允许切换。") {
                        ForEach(RACPPermissionMode.allCases, id: \.self) { mode in
                            PIListRow(
                                title: mode.title,
                                value: session.permissionMode == mode ? "当前" : nil,
                                isEnabled: configEnabled,
                                showsDivider: mode != .auto,
                                action: { Task { await session.configure(permissionMode: mode) } }
                            )
                        }
                    }
                    PIGroup("会话模式", footer: "Plan 模式提交计划后需要你在这里或用审批卡批准。") {
                        ForEach(RACPSessionMode.allCases, id: \.self) { mode in
                            PIListRow(
                                title: mode.title,
                                value: session.sessionMode == mode ? "当前" : nil,
                                isEnabled: configEnabled,
                                showsDivider: mode != .goal,
                                action: { Task { await session.configure(mode: mode) } }
                            )
                        }
                    }
                    PIGroup("模型", footer: "来自本机模型清单；选择后通过 `session/configure` 下发 providerId、modelId 与该模型的默认思考档位。") {
                        if groups.isEmpty {
                            PIListRow(
                                title: "没有可用模型",
                                subtitle: "先到 设置 → 模型服务 导入模型",
                                isEnabled: false,
                                showsDivider: false
                            )
                        } else {
                            ForEach(groups.indices, id: \.self) { groupIndex in
                                let group = groups[groupIndex]
                                Text(group.name)
                                    .font(PIFont.meta)
                                    .foregroundStyle(PIColor.text3)
                                    .padding(.horizontal, PISpacing.s16)
                                    .padding(.top, groupIndex == 0 ? 0 : PISpacing.s8)
                                ForEach(group.models.indices, id: \.self) { modelIndex in
                                    let record = group.models[modelIndex]
                                    let unavailable = isUnavailable(record)
                                    PIListRow(
                                        title: record.displayName,
                                        subtitle: unavailable
                                            ? "\(modelSubtitle(record)) · 未同步到 pi-host-v2"
                                            : modelSubtitle(record),
                                        value: isSelected(record) ? "当前" : nil,
                                        isEnabled: configEnabled && !unavailable,
                                        showsDivider: !(groupIndex == groups.count - 1 && modelIndex == group.models.count - 1),
                                        action: { select(record) }
                                    )
                                }
                            }
                        }
                    }
                    if let selectedBinding, !selectedBinding.thinkingLevels.isEmpty {
                        PIGroup("思考档位", footer: "档位只来自当前模型；未声明档位的模型不显示本组。") {
                            let levels = selectedBinding.thinkingLevels
                            ForEach(Array(levels.enumerated()), id: \.offset) { index, raw in
                                let level = RACPThinkingLevel(rawValue: raw)
                                PIListRow(
                                    title: raw,
                                    value: session.thinkingLevel?.rawValue == raw ? "当前" : nil,
                                    isEnabled: configEnabled,
                                    showsDivider: index != levels.count - 1,
                                    action: {
                                        Task { await select(selectedBinding, thinking: level) }
                                    }
                                )
                            }
                        }
                    }
                    if let notice = session.thinkingFallbackNotice {
                        PIStatusBanner(kind: .info, text: "档位已调整", detail: notice)
                    }
                    if let error = session.lastError {
                        PIStatusBanner(kind: .danger, text: "配置未生效", detail: error)
                    }
                }
                .padding(.horizontal, PIMetrics.pageMargin)
                .padding(.vertical, PISpacing.s16)
            }
            .piPageBackground()
            .piDetailNavBar("会话配置")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func isSelected(_ record: ModelRecord) -> Bool {
        record.providerId == session.selectedProviderId && record.modelId == session.selectedModelId
    }

    private func isUnavailable(_ record: ModelRecord) -> Bool {
        guard let providerId = record.providerId else { return false }
        return unavailableProviderIDs.contains(providerId)
    }

    private func modelSubtitle(_ record: ModelRecord) -> String {
        var parts = [record.modelId]
        if let context = record.contextWindow {
            parts.append("\(compactModelTokens(context)) ctx")
        }
        if let output = record.maxTokens {
            parts.append("\(compactModelTokens(output)) output")
        }
        if !record.thinkingLevels.isEmpty {
            parts.append("思考 \(record.thinkingLevels.joined(separator: "/"))")
        }
        return parts.joined(separator: " · ")
    }

    private func compactModelTokens(_ value: Int) -> String {
        if value >= 1_000_000, value % 1_000_000 == 0 { return "\(value / 1_000_000)M" }
        if value >= 1_000, value % 1_000 == 0 { return "\(value / 1_000)K" }
        return String(value)
    }

    private func select(_ record: ModelRecord, thinking: RACPThinkingLevel? = nil) {
        guard let providerId = record.providerId else { return }
        let levels = record.thinkingLevels.compactMap(RACPThinkingLevel.init(rawValue:))
        let support = ThinkingLevelSupport(
            declared: levels,
            defaultLevel: record.defaultThinkingLevel.flatMap(RACPThinkingLevel.init(rawValue:))
        )
        Task {
            await session.configure(
                providerId: providerId,
                modelId: record.modelId,
                thinkingLevel: thinking,
                thinkingSupport: support
            )
        }
    }
}

/// SwiftUI's item-level `ScrollViewReader.scrollTo`/`scrollPosition` can keep the
/// previous offset when session content is swapped in place. This anchor applies
/// the restore directly to the enclosing UIScrollView, then the measured frame is
/// used by `ConversationScreen` to confirm success.
private struct ReadingRestoreAnchor: UIViewRepresentable {
    let itemID: String
    let targetID: String?
    let requestID: Int
    let onUserInteraction: () -> Void

    final class Coordinator {
        var appliedRequestID = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        guard targetID == itemID,
              requestID > 0,
              context.coordinator.appliedRequestID != requestID
        else { return }
        context.coordinator.appliedRequestID = requestID
        let expectedRequestID = requestID

        DispatchQueue.main.async {
            guard context.coordinator.appliedRequestID == expectedRequestID else { return }
            guard uiView.window != nil,
                  let scrollView = uiView.enclosingScrollView
            else {
                context.coordinator.appliedRequestID = 0
                return
            }
            guard !scrollView.isDragging,
                  !scrollView.isTracking,
                  !scrollView.isDecelerating
            else {
                onUserInteraction()
                return
            }
            let current = uiView.convert(uiView.bounds, to: scrollView)
            let inset = scrollView.adjustedContentInset
            let desiredY = scrollView.contentOffset.y + current.minY
            let minimumY = -inset.top
            let maximumY = max(
                minimumY,
                scrollView.contentSize.height - scrollView.bounds.height + inset.bottom
            )
            scrollView.setContentOffset(
                CGPoint(
                    x: scrollView.contentOffset.x,
                    y: min(max(desiredY, minimumY), maximumY)
                ),
                animated: false
            )
        }
    }
}

private extension UIView {
    var enclosingScrollView: UIScrollView? {
        var candidate = superview
        while let view = candidate {
            if let scrollView = view as? UIScrollView { return scrollView }
            candidate = view.superview
        }
        return nil
    }
}
struct AttachmentThumbnailView: View {
    let attachment: RACPV2Attachment
    @EnvironmentObject private var connection: ConnectionModel
    @State private var uiImage: UIImage?
    @State private var isLoading = false
    @State private var loadFailed = false
    @State private var showingDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: PISpacing.s4) {
            if let uiImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 200)
                    .cornerRadius(PIRadius.control)
                    .onTapGesture { showingDetail = true }
            } else if isLoading {
                ProgressView()
                    .frame(height: 100)
            } else if loadFailed {
                Label("图片加载失败", systemImage: "exclamationmark.triangle")
                    .font(PIFont.meta)
                    .foregroundStyle(PIColor.danger)
            } else {
                HStack(spacing: PISpacing.s4) {
                    Image(systemName: "photo")
                    Text(attachment.fileName)
                        .font(PIFont.meta)
                }
                .padding(PISpacing.s8)
                .background(PIColor.surface2, in: RoundedRectangle(cornerRadius: PIRadius.control, style: .continuous))
            }
        }
        .task {
            await loadImage()
        }
        .sheet(isPresented: $showingDetail) {
            if let uiImage {
                NavigationStack {
                    VStack {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFit()
                            .padding()
                        ShareLink(
                            item: Image(uiImage: uiImage),
                            preview: SharePreview(attachment.fileName, image: Image(uiImage: uiImage))
                        ) {
                            Label("保存或分享图片", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.borderedProminent)
                        .padding()
                    }
                    .navigationTitle(attachment.fileName)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        Button("关闭") { showingDetail = false }
                    }
                }
            }
        }
    }

    private func loadImage() async {
        guard uiImage == nil, !isLoading else { return }
        guard let client = connection.activeClient else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let read = try await client.readImageAttachment(attachmentId: attachment.id, offset: 0, length: 20 * 1024 * 1024)
            if let data = Data(base64Encoded: read.dataBase64), let image = UIImage(data: data) {
                uiImage = image
                loadFailed = false
            } else {
                loadFailed = true
            }
        } catch {
            loadFailed = true
        }
    }
}

