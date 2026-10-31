import SwiftUI
import Foundation
import PIiOSCore

/// 会话侧边栏（screens.md S-07 / information-architecture.md §2 抽屉浮层）。
///
/// 构成：顶部 Host 选择器（名称、连接状态、▾）+ 右侧 ×；会话区；底部新建会话与 项目 / 设置。
/// 会话区读真实数据：在线时列服务器上的会话（可点开），离线时列本机缓存的会话（只读）。
struct SidebarView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var connection: ConnectionModel
    @State private var searchText = ""
    @State private var dragSessionID: String?
    @State private var dropResolution: SessionDropResolution?
    @State private var sessionRowFrames: [String: CGRect] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            hostSelector
            divider
            conversationArea
            divider
            bottomBar
        }
        .frame(width: PIMetrics.sidebarWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(PIColor.surface.ignoresSafeArea(edges: .bottom))
        .onDisappear(perform: resetSessionDrag)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(PIColor.separator)
                .frame(width: PIMetrics.hairline)
                .ignoresSafeArea(edges: .bottom)
        }
        .accessibilityAddTraits(.isModal)
    }

    private var divider: some View {
        Rectangle()
            .fill(PIColor.separator)
            .frame(height: PIMetrics.hairline)
    }

    // MARK: - Host 选择器

    @ViewBuilder
    private var hostSelector: some View {
        HStack(alignment: .center, spacing: PISpacing.s8) {
            if model.hosts.isEmpty {
                Button {
                    model.showSettings()
                } label: {
                    VStack(alignment: .leading, spacing: PISpacing.s4) {
                        Text("未配置服务器")
                            .font(PIFont.listTitle)
                            .foregroundStyle(PIColor.text)
                        Text("去设置添加服务器")
                            .font(PIFont.meta)
                            .foregroundStyle(PIColor.accent)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(minHeight: PIMetrics.minHitTarget)
            } else {
                Menu {
                    ForEach(model.hosts) { host in
                        Button {
                            Task { await model.setCurrentHost(id: host.id) }
                        } label: {
                            Text(host.isCurrent ? "✓ \(host.name)" : host.name)
                        }
                    }
                    Divider()
                    Button("管理服务器…") { model.showSettings() }
                } label: {
                    HStack(spacing: PISpacing.s4) {
                        VStack(alignment: .leading, spacing: PISpacing.s4) {
                            Text(model.currentHost?.name ?? "选择服务器")
                                .font(PIFont.listTitle)
                                .foregroundStyle(PIColor.text)
                                .lineLimit(1)
                            Text(model.currentHost?.statusText ?? "")
                                .font(PIFont.meta)
                                .foregroundStyle(PIColor.text2)
                                .lineLimit(1)
                        }
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(PIColor.text3)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .frame(minHeight: PIMetrics.minHitTarget)
                .accessibilityLabel("切换服务器")
            }

            Button {
                model.closeSidebar()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(PIColor.text2)
                    .frame(width: PIMetrics.minHitTarget, height: PIMetrics.minHitTarget)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("关闭侧边栏")
            .accessibilityIdentifier("sidebar.close")
        }
        .padding(.horizontal, PISpacing.s16)
        .padding(.top, PISpacing.s8)
        .padding(.bottom, PISpacing.s12)
    }

    private var conversationArea: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PISpacing.s8) {
                TextField("搜索会话或项目", text: $searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                    .padding(.bottom, PISpacing.s8)
                    .onSubmit {}
                if connection.state.isOnline {
                    if sidebarGroups.isEmpty {
                        Text(
                            trimmedSearch.isEmpty
                                ? "没有活跃会话；上游同步的会话会先进入已归档，可在项目详情恢复。"
                                : "没有匹配的会话或项目。"
                        )
                            .font(PIFont.caption)
                            .foregroundStyle(PIColor.text2)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        ForEach(sidebarGroups) { group in
                            projectGroup(group)
                        }
                    }
                } else {
                    if offlineSidebarGroups.isEmpty {
                        Text("尚未连接服务器，本机也没有缓存的历史。")
                            .font(PIFont.caption)
                            .foregroundStyle(PIColor.text2)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("离线：下面是可以只读查看的缓存会话。")
                            .font(PIFont.caption)
                            .foregroundStyle(PIColor.warning)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(offlineSidebarGroups) { group in
                            offlineProjectGroup(group)
                        }
                    }
                }
            }
            .onPreferenceChange(SidebarSessionFramePreferenceKey.self) { frames in
                sessionRowFrames = frames
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, PISpacing.s16)
            .padding(.vertical, PISpacing.s16)
        }
        .coordinateSpace(name: SidebarSessionCoordinates.list)
    }

    private struct SidebarGroup: Identifiable {
        let project: RACPProjectSummary
        let name: String
        let sessions: [RACPSessionSummary]

        var id: String { project.id }
    }

    private struct OfflineSidebarGroup: Identifiable {
        let projectID: String
        let name: String
        let sessionIDs: [String]

        var id: String { projectID }
    }

    private var trimmedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var sidebarGroups: [SidebarGroup] {
        guard let hostID = model.currentHost?.id else { return [] }
        let projects = connection.projects.filter {
            !model.isProjectDeleted(hostID: hostID, projectID: $0.id)
                && !model.isProjectArchived(hostID: hostID, projectID: $0.id)
        }
        let query = trimmedSearch.lowercased()
        let groups = projects.compactMap { project -> SidebarGroup? in
            let name = model.projectDisplayName(
                hostID: hostID,
                projectID: project.id,
                fallback: project.label ?? project.id
            )
            let sessions = connection.sessions
                .filter { $0.projectId == project.id }
                .filter { session in
                    guard let binding = model.sessionBinding(hostID: hostID, sessionID: session.id) else {
                        return false
                    }
                    return !binding.isArchived && !binding.isDeleted
                }
                .filter { session in
                    guard !query.isEmpty else { return true }
                    let title = model.sessionDisplayTitle(
                        hostID: hostID,
                        sessionID: session.id,
                        fallback: session.title ?? session.id
                    )
                    return title.lowercased().contains(query) || name.lowercased().contains(query)
                }
            let byID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
            let pinnedOrders = Dictionary(uniqueKeysWithValues: sessions.compactMap { session in
                model.sessionBinding(hostID: hostID, sessionID: session.id)?
                    .pinOrder
                    .map { (session.id, $0) }
            })
            let activity = Dictionary(uniqueKeysWithValues: sessions.map { session in
                (session.id, model.sessionBinding(hostID: hostID, sessionID: session.id)?.lastActivityAt ?? .distantPast)
            })
            let ordered = SessionOrderingPolicy.orderedIDs(
                sessions.map(\.id),
                pinnedOrders: pinnedOrders,
                lastActivity: activity
            ).compactMap { byID[$0] }
            guard !ordered.isEmpty || query.isEmpty else { return nil }
            return SidebarGroup(project: project, name: name, sessions: ordered)
        }
        let activeProject = model.lastProjectID(for: hostID)
        return groups.sorted { left, right in
            if left.project.id == activeProject, right.project.id != activeProject { return true }
            if right.project.id == activeProject, left.project.id != activeProject { return false }
            return left.name.localizedCompare(right.name) == .orderedAscending
        }
    }

    private var offlineSidebarGroups: [OfflineSidebarGroup] {
        guard let hostID = model.currentHost?.id else { return [] }
        let cached = connection.cachedSessionIds()
        var byProject: [String: [String]] = [:]

        for sessionID in cached {
            let binding = model.sessionBinding(hostID: hostID, sessionID: sessionID)
            guard binding?.isArchived != true, binding?.isDeleted != true else { continue }
            let projectID = binding?.projectID ?? "offline-unassigned"
            if let project = model.projectBinding(hostID: hostID, projectID: projectID),
               project.isArchived || project.isDeleted {
                continue
            }
            byProject[projectID, default: []].append(sessionID)
        }

        let groups = byProject.map { projectID, sessionIDs in
            let name = projectID == "offline-unassigned"
                ? "未归属项目"
                : model.projectDisplayName(
                    hostID: hostID,
                    projectID: projectID,
                    fallback: projectID
                )
            let pinnedOrders = Dictionary(uniqueKeysWithValues: sessionIDs.compactMap { sessionID in
                model.sessionBinding(hostID: hostID, sessionID: sessionID)?
                    .pinOrder
                    .map { (sessionID, $0) }
            })
            let activity = Dictionary(uniqueKeysWithValues: sessionIDs.map { sessionID in
                (sessionID, model.sessionBinding(hostID: hostID, sessionID: sessionID)?.lastActivityAt ?? .distantPast)
            })
            return OfflineSidebarGroup(
                projectID: projectID,
                name: name,
                sessionIDs: SessionOrderingPolicy.orderedIDs(
                    sessionIDs,
                    pinnedOrders: pinnedOrders,
                    lastActivity: activity
                )
            )
        }
        let activeProject = model.lastProjectID(for: hostID)
        return groups.sorted { left, right in
            if left.projectID == activeProject, right.projectID != activeProject { return true }
            if right.projectID == activeProject, left.projectID != activeProject { return false }
            return left.name.localizedCompare(right.name) == .orderedAscending
        }
    }

    private func offlineProjectGroup(_ group: OfflineSidebarGroup) -> some View {
        let hostID = model.currentHost?.id
        let collapsed = hostID.map {
            model.isProjectGroupCollapsed(hostID: $0, projectID: group.projectID)
        } == true
        let current = hostID.map { model.lastProjectID(for: $0) == group.projectID } ?? false
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                guard let hostID else { return }
                model.toggleProjectGroup(hostID: hostID, projectID: group.projectID)
            } label: {
                HStack(spacing: PISpacing.s8) {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(PIColor.text3)
                    Text(group.name)
                        .font(PIFont.captionStrong)
                        .foregroundStyle(PIColor.text)
                        .lineLimit(1)
                    Text("\(group.sessionIDs.count)")
                        .font(PIFont.metaSmall)
                        .foregroundStyle(PIColor.text3)
                    if current {
                        Text("当前")
                            .font(PIFont.metaSmall)
                            .foregroundStyle(PIColor.accent)
                    }
                    Spacer()
                }
                .padding(.horizontal, PISpacing.s8)
                .frame(minHeight: 34)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                "\(group.name)，\(group.sessionIDs.count) 个会话"
                    + (current ? "，当前项目" : "")
                    + (collapsed ? "，已折叠" : "")
            )
            .accessibilityIdentifier("sidebar.project.\(group.projectID)")

            if !collapsed {
                ForEach(group.sessionIDs, id: \.self) { sessionID in
                    PIListRow(
                        title: sessionID,
                        subtitle: hostID.map {
                            model.hasSessionUpdate(hostID: $0, sessionID: sessionID)
                                ? "本机缓存（只读） · 新" : "本机缓存（只读）"
                        } ?? "本机缓存（只读）",
                        showsChevron: true,
                        showsDivider: true,
                        action: {
                            guard let hostID else { return }
                            model.selectCachedSession(hostID: hostID, sessionID: sessionID)
                            model.switchRoot(.conversation)
                            model.closeSidebar()
                        }
                    )
                }
            }
        }
        .padding(.bottom, PISpacing.s4)
    }

    private func projectGroup(_ group: SidebarGroup) -> some View {
        let hostID = model.currentHost?.id
        let collapsed = trimmedSearch.isEmpty
            && hostID.map { model.isProjectGroupCollapsed(hostID: $0, projectID: group.project.id) } == true
        let current = hostID.map { model.lastProjectID(for: $0) == group.project.id } ?? false
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                guard trimmedSearch.isEmpty, let hostID else { return }
                model.toggleProjectGroup(hostID: hostID, projectID: group.project.id)
            } label: {
                HStack(spacing: PISpacing.s8) {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(PIColor.text3)
                    Text(group.name)
                        .font(PIFont.captionStrong)
                        .foregroundStyle(PIColor.text)
                        .lineLimit(1)
                    Text("\(group.sessions.count)")
                        .font(PIFont.metaSmall)
                        .foregroundStyle(PIColor.text3)
                    if current {
                        Text("当前")
                            .font(PIFont.metaSmall)
                            .foregroundStyle(PIColor.accent)
                    }
                    Spacer()
                }
                .padding(.horizontal, PISpacing.s8)
                .frame(minHeight: 34)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                "\(group.name)，\(group.sessions.count) 个会话"
                    + (current ? "，当前项目" : "")
                    + (collapsed ? "，已折叠" : "")
            )
            .accessibilityIdentifier("sidebar.project.\(group.project.id)")

            if !collapsed {
                let reorderableIDs = projectReorderableSessionIDs(for: group)
                ForEach(group.sessions, id: \.id) { session in
                    sessionRow(
                        session,
                        projectID: group.project.id,
                        reorderableIDs: reorderableIDs
                    )
                }
            }
        }
        .padding(.bottom, PISpacing.s4)
    }

    private func projectReorderableSessionIDs(for group: SidebarGroup) -> [String] {
        guard let hostID = model.currentHost?.id else { return [] }
        let candidates = group.sessions.compactMap { session -> SessionDragCandidate? in
            guard let binding = model.sessionBinding(
                hostID: hostID,
                sessionID: session.id
            ) else { return nil }
            return SessionDragCandidate(
                sessionID: session.id,
                projectID: binding.projectID ?? group.project.id,
                isPinned: binding.isPinned
            )
        }
        return SessionDragPolicy.reorderableSessionIDs(
            from: candidates,
            projectID: group.project.id
        )
    }

    private func sessionRow(
        _ session: RACPSessionSummary,
        projectID: String,
        reorderableIDs: [String]
    ) -> some View {
        let hostID = model.currentHost?.id
        let binding = hostID.flatMap { model.sessionBinding(hostID: $0, sessionID: session.id) }
        let title = hostID.map {
            model.sessionDisplayTitle(hostID: $0, sessionID: session.id, fallback: session.title ?? session.id)
        } ?? (session.title ?? session.id)
        let isCurrent = connection.session.attachedSessionId == session.id
        let isPinned = binding?.isPinned == true
        return HStack(spacing: PISpacing.s8) {
            if isPinned {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(PIColor.text3)
                    .accessibilityHidden(true)
            }
            Button {
                openSession(session)
            } label: {
                VStack(alignment: .leading, spacing: PISpacing.s4) {
                    HStack(spacing: PISpacing.s4) {
                        Text(title)
                            .font(PIFont.listTitle)
                            .foregroundStyle(PIColor.text)
                            .lineLimit(1)
                        if hostID.map({ model.hasSessionUpdate(hostID: $0, sessionID: session.id) }) == true {
                            Text("新")
                                .font(PIFont.metaSmall)
                                .foregroundStyle(PIColor.accent)
                                .accessibilityLabel("离开期间有更新")
                        }
                    }
                    Text(sessionStatus(session, binding: binding))
                        .font(PIFont.metaSmall)
                        .foregroundStyle(PIColor.text3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: PIMetrics.minHitTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("sidebar.session.\(session.id)")
            if isCurrent {
                Text("当前")
                    .font(PIFont.metaSmall)
                    .foregroundStyle(PIColor.accent)
            }
            if let hostID {
                Button {
                    if isPinned {
                        model.unpinSession(hostID: hostID, sessionID: session.id)
                    } else {
                        model.pinSession(hostID: hostID, sessionID: session.id)
                    }
                } label: {
                    Image(systemName: isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isPinned ? PIColor.accent : PIColor.text3)
                        .frame(width: 30, height: 34)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isPinned ? "取消置顶" : "置顶会话")
                .accessibilityIdentifier("sidebar.pin.\(session.id)")
            }
        }
        .padding(.horizontal, PISpacing.s8)
        .padding(.vertical, PISpacing.s8)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: SidebarSessionFramePreferenceKey.self,
                    value: [
                        session.id: proxy.frame(
                            in: .named(SidebarSessionCoordinates.list)
                        ),
                    ]
                )
            }
        }
        .background(
            (dropResolution?.targetID == session.id ? PIColor.accentSoft : Color.clear),
            in: RoundedRectangle(cornerRadius: PIRadius.control, style: .continuous)
        )
        .overlay(alignment: .top) {
            if dropResolution?.targetID == session.id, dropResolution?.edge == .before {
                dropIndicator
            }
        }
        .overlay(alignment: .bottom) {
            if dropResolution?.targetID == session.id, dropResolution?.edge == .after {
                dropIndicator
            }
        }
        .opacity(dragSessionID == session.id ? 0.72 : 1)
        .contentShape(Rectangle())
        .gesture(
            reorderGesture(
                sessionID: session.id,
                projectID: projectID,
                isPinned: isPinned,
                reorderableIDs: reorderableIDs
            )
        )
        .accessibilityHint(
            isPinned ? "长按 0.5 秒后拖动，可在本项目内调整置顶顺序" : ""
        )
    }

    private var dropIndicator: some View {
        Rectangle()
            .fill(PIColor.accent)
            .frame(height: 2)
            .padding(.horizontal, PISpacing.s4)
            .accessibilityHidden(true)
    }

    private func reorderGesture(
        sessionID: String,
        projectID: String,
        isPinned: Bool,
        reorderableIDs: [String]
    ) -> some Gesture {
        LongPressGesture(
            minimumDuration: SessionDragPolicy.longPressDuration,
            maximumDistance: SessionDragPolicy.scrollCancellationDistance
        )
        .sequenced(
            before: DragGesture(
                minimumDistance: 0,
                coordinateSpace: .named(SidebarSessionCoordinates.list)
            )
        )
        .onChanged { value in
            guard isPinned else { return }
            switch value {
            case .first(true):
                dragSessionID = sessionID
                dropResolution = nil
            case .second(true, let drag):
                guard dragSessionID == sessionID, let drag else { return }
                dropResolution = SessionDragPolicy.resolveDrop(
                    at: drag.location,
                    sourceID: sessionID,
                    projectID: projectID,
                    candidates: dragCandidates(
                        reorderableIDs,
                        projectID: projectID
                    ),
                    frames: sessionRowFrames
                )
            default:
                break
            }
        }
        .onEnded { value in
            let sourceID = dragSessionID
            let resolution: SessionDropResolution?
            if case .second(true, let drag) = value, let drag {
                resolution = SessionDragPolicy.resolveDrop(
                    at: drag.location,
                    sourceID: sessionID,
                    projectID: projectID,
                    candidates: dragCandidates(
                        reorderableIDs,
                        projectID: projectID
                    ),
                    frames: sessionRowFrames
                )
            } else {
                resolution = dropResolution
            }
            defer { resetSessionDrag() }
            guard isPinned,
                  sourceID == sessionID,
                  let resolution,
                  let hostID = model.currentHost?.id
            else { return }
            applyDrop(
                hostID: hostID,
                projectID: projectID,
                sourceID: sessionID,
                resolution: resolution,
                orderedIDs: reorderableIDs
            )
        }
    }

    private func dragCandidates(
        _ reorderableIDs: [String],
        projectID: String
    ) -> [SessionDragCandidate] {
        reorderableIDs.map {
            SessionDragCandidate(
                sessionID: $0,
                projectID: projectID,
                isPinned: true
            )
        }
    }

    private func applyDrop(
        hostID: UUID,
        projectID: String,
        sourceID: String,
        resolution: SessionDropResolution,
        orderedIDs: [String]
    ) {
        switch resolution.edge {
        case .before:
            model.movePinnedSession(
                hostID: hostID,
                projectID: projectID,
                sessionID: sourceID,
                before: resolution.targetID
            )
        case .after:
            guard let targetIndex = orderedIDs.firstIndex(of: resolution.targetID) else {
                return
            }
            if let nextID = orderedIDs
                .dropFirst(targetIndex + 1)
                .first(where: { $0 != sourceID }) {
                model.movePinnedSession(
                    hostID: hostID,
                    projectID: projectID,
                    sessionID: sourceID,
                    before: nextID
                )
            } else {
                // The Host-facing model exposes "move before" only. These two
                // scoped moves append the source after the final pinned row.
                model.movePinnedSession(
                    hostID: hostID,
                    projectID: projectID,
                    sessionID: sourceID,
                    before: resolution.targetID
                )
                model.movePinnedSession(
                    hostID: hostID,
                    projectID: projectID,
                    sessionID: resolution.targetID,
                    before: sourceID
                )
            }
        }
    }

    private func resetSessionDrag() {
        dragSessionID = nil
        dropResolution = nil
    }

    private func sessionStatus(
        _ session: RACPSessionSummary,
        binding: StoredSessionBinding?
    ) -> String {
        let status = session.status?.lowercased() ?? ""
        var parts: [String] = []
        if status.contains("running") || status.contains("working") {
            parts.append("运行中")
        } else if status.contains("waiting")
                    || status.contains("approval")
                    || status.contains("input")
                    || status.contains("pending") {
            parts.append("待处理")
        } else {
            parts.append(session.status ?? "idle")
        }
        if let messageCount = binding?.messageCount {
            parts.append("\(messageCount) 条")
        }
        return parts.joined(separator: " · ")
    }

    private func openSession(_ session: RACPSessionSummary) {
        if let projectID = session.projectId {
            model.rememberProject(projectID)
        }
        model.rememberSession(session.id)
        Task {
            await connection.session.attach(sessionId: session.id)
            model.switchRoot(.conversation)
            model.closeSidebar()
        }
    }

    // MARK: - 底部

    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: PISpacing.s12) {
            if connection.state.isOnline {
                PIListRow(
                    title: "新建会话",
                    subtitle: "到项目页选择项目后创建（需要项目作为工作区）",
                    showsChevron: true,
                    showsDivider: false,
                    action: {
                        model.switchRoot(.projects)
                        model.closeSidebar()
                    }
                )
            } else {
                disabledAction(title: "新建会话", reason: "未连接服务器，无法新建会话")
            }
            HStack(spacing: PISpacing.s8) {
                // IA §1 的三个根都要有入口：会话 / 项目 / 设置（会话页仍是既有空态，不造假数据）。
                rootButton(.conversation)
                rootButton(.projects)
                rootButton(.settings)
            }
        }
        .padding(.horizontal, PISpacing.s16)
        .padding(.top, PISpacing.s12)
        .padding(.bottom, PISpacing.s16)
    }

    private func rootButton(_ root: AppModel.Root) -> some View {
        PISecondaryButton(title: root.title) {
            model.switchRoot(root)
        }
    }

    /// 禁用态操作：明确写清原因，不做「点了没反应」的按钮。
    private func disabledAction(title: String, reason: String) -> some View {
        VStack(alignment: .leading, spacing: PISpacing.s4) {
            HStack(spacing: PISpacing.s4) {
                Image(systemName: "lock")
                    .font(.system(size: 11, weight: .semibold))
                    .accessibilityHidden(true)
                Text(title)
                    .font(PIFont.button)
            }
            .foregroundStyle(PIColor.text3)
            .frame(maxWidth: .infinity, minHeight: PIMetrics.minHitTarget)
            .background(PIColor.surface2, in: RoundedRectangle(cornerRadius: PIRadius.control, style: .continuous))
            Text(reason)
                .font(PIFont.metaSmall)
                .foregroundStyle(PIColor.text3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)，不可用：\(reason)")
    }
}

private enum SidebarSessionCoordinates {
    static let list = "sidebar-session-list"
}

private struct SidebarSessionFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(
        value: inout [String: CGRect],
        nextValue: () -> [String: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}
