import SwiftUI
import PIiOSCore
import PIiOSNet

/// S-01 项目（根）。
///
/// 数据只来自服务器：`project/list` 与 `session/list`；注册走 `project/browse` + `project/register`，
/// 新建会话走 `session/create`。未连接、无数据、加载失败各自一个状态，没有示例数据。
struct ProjectsScreen: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var connection: ConnectionModel

    @State private var isRefreshing = false
    @State private var showingBrowser = false
    @State private var showingNewSession = false
    @State private var actionError: String?
    @State private var currentProjectId: String?
    @State private var selectedProject: RACPProjectSummary?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: PISpacing.s24) {
                    serverCard
                    if let actionError {
                        PIStatusBanner(kind: .danger, text: "操作未完成", detail: actionError)
                            .onTapGesture { self.actionError = nil }
                    }
                    if connection.hasLoadedCatalog,
                       let catalogError = connection.catalogError {
                        PIStatusBanner(
                            kind: .warning,
                            text: "项目与会话加载失败",
                            detail: catalogError,
                            actionTitle: connection.isRefreshingCatalog ? "正在重试…" : "重试",
                            action: { Task { await refresh() } }
                        )
                    }
                    content
                }
                .padding(.horizontal, PIMetrics.pageMargin)
                .padding(.top, PISpacing.s8)
                .padding(.bottom, PISpacing.s32)
            }
            .piPageBackground()
            .piRootNavBar("项目", onMenu: model.openSidebar) {
                Button(action: openProjectBrowser) {
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(PIColor.text)
                        .frame(width: PIMetrics.minHitTarget, height: PIMetrics.minHitTarget)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("添加项目")
                .accessibilityIdentifier("projects.add")
                .disabled(!canOpenProjectBrowser)
            }
            .task {
                if connection.state.isOnline { await refresh() }
            }
            .onChange(of: model.currentHost?.id) { _, _ in
                currentProjectId = nil
                selectedProject = nil
                actionError = nil
            }
            .sheet(isPresented: $showingBrowser) {
                ProjectBrowserSheet(
                    initialPath: initialBrowserPath,
                    existingProjects: projectRegistrationTargets
                ) { path, name in
                    try await register(path: path, name: name)
                }
            }
            .sheet(isPresented: $showingNewSession) {
                NewSessionSheet(
                    projectId: activeProjectId,
                    projectName: activeProjectName
                ) { title in
                    Task { await createSession(title: title) }
                }
            }
            .sheet(isPresented: projectDetailBinding) {
                if let project = selectedProject {
                    ProjectDetailSheet(
                        project: project,
                        initialName: projectDisplayName(project),
                        onOpenSession: { session in
                            selectedProject = nil
                            Task { await open(session) }
                        },
                        onNewSession: {
                            currentProjectId = project.id
                            model.rememberProject(project.id)
                            selectedProject = nil
                            showingNewSession = true
                        },
                        onArchive: {
                            archive(project)
                            selectedProject = nil
                        },
                        onDelete: {
                            delete(project)
                            selectedProject = nil
                        },
                        onRestore: {
                            restore(project)
                        }
                    )
                }
            }
        }
    }

    private var projectDetailBinding: Binding<Bool> {
        Binding(
            get: { selectedProject != nil },
            set: { if !$0 { selectedProject = nil } }
        )
    }

    private var initialBrowserPath: String? {
        guard let hostID = model.currentHost?.id else { return nil }
        return model.projectBrowserPath(hostID: hostID)
    }

    private var projectRegistrationTargets: [ProjectRegistrationTarget] {
        guard let hostID = model.currentHost?.id else { return [] }
        return connection.projects.filter {
            !model.isProjectDeleted(hostID: hostID, projectID: $0.id)
        }.map { project in
            ProjectRegistrationTarget(
                projectId: project.id,
                displayName: projectDisplayName(project, hostID: hostID),
                path: model.projectBinding(hostID: hostID, projectID: project.id)?.path
            )
        }
    }

    private var activeProjects: [RACPProjectSummary] {
        guard let hostID = model.currentHost?.id else { return [] }
        return connection.projects.filter {
            !model.isProjectDeleted(hostID: hostID, projectID: $0.id)
                && !model.isProjectArchived(hostID: hostID, projectID: $0.id)
        }
    }

    private var archivedProjects: [RACPProjectSummary] {
        guard let hostID = model.currentHost?.id else { return [] }
        return connection.projects.filter {
            !model.isProjectDeleted(hostID: hostID, projectID: $0.id)
                && model.isProjectArchived(hostID: hostID, projectID: $0.id)
        }
    }

    private var activeProjectId: String? {
        if let currentProjectId,
           activeProjects.contains(where: { $0.id == currentProjectId }) {
            return currentProjectId
        }
        if let hostID = model.currentHost?.id,
           let remembered = model.lastProjectID(for: hostID),
           activeProjects.contains(where: { $0.id == remembered }) {
            return remembered
        }
        return activeProjects.first?.id
    }

    private var activeProjectName: String? {
        guard let activeProjectId,
              let project = connection.projects.first(where: { $0.id == activeProjectId }),
              let hostID = model.currentHost?.id
        else { return nil }
        return projectDisplayName(project, hostID: hostID)
    }

    @ViewBuilder
    private var content: some View {
        if connection.state.isOnline {
            if !connection.hasLoadedCatalog, connection.catalogError == nil {
                PIStatusBanner(kind: .info, text: "正在加载项目与会话", detail: "已连上服务器，正在读取列表。")
            } else if !connection.hasLoadedCatalog, let catalogError = connection.catalogError {
                PIEmptyState(
                    title: "项目列表未加载",
                    message: catalogError,
                    actionTitle: "重新加载",
                    action: { Task { await refresh() } }
                )
            } else {
                projectsSection
                sessionsSection
            }
        } else {
            PIEmptyState(
                title: connection.state == .offline(reason: nil) ? "尚未连接服务器" : "连接未就绪",
                message: emptyMessage,
                actionTitle: "打开设置",
                action: { model.switchRoot(.settings) }
            )
        }
    }

    private var emptyMessage: String {
        if let detail = connection.state.detail {
            return "\(connection.state.displayText)：\(detail)"
        }
        return "隧道未建立时无法列出服务器上的项目与会话；到设置里连接当前服务器。"
    }

    private var serverCard: some View {
        PICard {
            Text("当前服务器")
                .font(PIFont.captionStrong)
                .foregroundStyle(PIColor.text2)
            if let host = model.currentHost {
                Text(host.name)
                    .font(PIFont.listTitle)
                    .foregroundStyle(PIColor.text)
                Text("\(host.address) · \(host.pairingText) · \(connection.state.displayText)")
                    .font(PIFont.caption)
                    .foregroundStyle(PIColor.text2)
            } else {
                Text("未配置服务器")
                    .font(PIFont.listTitle)
                    .foregroundStyle(PIColor.text)
                Text("先在「设置 → 服务器」添加一台服务器。")
                    .font(PIFont.caption)
                    .foregroundStyle(PIColor.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let info = connection.info {
                Text("Host \(info.serverName) \(info.serverVersion) · 协议 \(info.protocolVersion)")
                    .font(PIFont.caption)
                    .foregroundStyle(PIColor.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 项目

    private var projectsSection: some View {
        VStack(alignment: .leading, spacing: PISpacing.s8) {
            PISectionHeader(text: "项目")
            if activeProjects.isEmpty {
                PIEmptyState(
                    title: "还没有项目",
                    message: archivedProjects.isEmpty
                        ? "选择一个服务器目录并命名，注册后即可在该目录下创建会话。"
                        : "当前没有活跃项目；可从下方已归档项目恢复，或注册新目录。",
                    actionTitle: "选择服务器目录",
                    action: openProjectBrowser
                )
            } else {
                PIGroup {
                    ForEach(Array(activeProjects.enumerated()), id: \.element.id) { index, project in
                        ProjectSummaryRow(
                            projectID: project.id,
                            name: projectDisplayName(project),
                            sessionCount: sessionCount(for: project.id),
                            runningCount: statusCount(for: project.id, kind: .running),
                            pendingCount: statusCount(for: project.id, kind: .pending),
                            isCurrent: activeProjectId == project.id,
                            showsDivider: index < activeProjects.count - 1,
                            onOpen: { openProjectOrDetail(project) },
                            onDetails: { selectedProject = project }
                        )
                    }
                }
                PIListRow(
                    title: "浏览服务器目录并注册",
                    subtitle: "逐级浏览目录，填写项目名称后注册",
                    isEnabled: canOpenProjectBrowser,
                    showsChevron: true,
                    showsDivider: false,
                    action: openProjectBrowser
                )
            }
            if !archivedProjects.isEmpty {
                PISectionHeader(text: "已归档 · \(archivedProjects.count)")
                    .padding(.top, PISpacing.s8)
                PIGroup {
                    ForEach(Array(archivedProjects.enumerated()), id: \.element.id) { index, project in
                        PIListRow(
                            title: projectDisplayName(project),
                            subtitle: "本机归档，服务器内容未变",
                            value: "恢复",
                            showsChevron: true,
                            showsDivider: index < archivedProjects.count - 1,
                            action: { restore(project) }
                        )
                        .accessibilityIdentifier("projects.archived.\(project.id)")
                    }
                }
            }
        }
    }

    private func projectDisplayName(_ project: RACPProjectSummary) -> String {
        guard let hostID = model.currentHost?.id else {
            return project.label ?? project.id
        }
        return projectDisplayName(project, hostID: hostID)
    }

    private func projectDisplayName(_ project: RACPProjectSummary, hostID: UUID) -> String {
        model.projectDisplayName(
            hostID: hostID,
            projectID: project.id,
            fallback: project.label ?? project.id
        )
    }

    private func sessionCount(for projectId: String) -> Int {
        let excluded: Set<String>
        if let hostID = model.currentHost?.id {
            excluded = Set(
                model.sessionBindings.lazy
                    .filter { $0.hostID == hostID && $0.isDeleted }
                    .map(\.sessionID)
            )
        } else {
            excluded = []
        }
        return ProjectSessionRules.totalSessionCount(
            connection.sessions,
            projectID: projectId,
            excludingSessionIDs: excluded
        )
    }

    private enum SessionStatusKind {
        case running
        case pending
    }

    private func statusCount(for projectId: String, kind: SessionStatusKind) -> Int {
        sessions(for: projectId).filter { session in
            guard isSessionVisible(projectId: projectId, sessionID: session.id) else { return false }
            let value = session.status?.lowercased() ?? ""
            switch kind {
            case .running:
                return value.contains("running") || value.contains("working")
            case .pending:
                return value.contains("waiting")
                    || value.contains("approval")
                    || value.contains("input")
                    || value.contains("pending")
            }
        }.count
    }

    private func sessions(for projectId: String) -> [RACPSessionSummary] {
        connection.sessions.filter { $0.projectId == projectId }
    }

    private func isSessionVisible(projectId: String, sessionID: String) -> Bool {
        guard let hostID = model.currentHost?.id,
              let binding = model.sessionBinding(hostID: hostID, sessionID: sessionID)
        else { return false }
        return !binding.isArchived && !binding.isDeleted
    }

    // MARK: - 会话

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: PISpacing.s8) {
            PISectionHeader(text: "会话")
            let visible = visibleSessions
            if visible.isEmpty {
                PIListRow(
                    title: connection.sessions.isEmpty ? "服务器上没有会话" : "这个项目下没有会话",
                    subtitle: "点下面的「新建会话」创建一条",
                    isEnabled: false,
                    showsDivider: false
                )
            } else {
                PIGroup {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, session in
                        PIListRow(
                            title: sessionDisplayTitle(session),
                            subtitle: sessionSubtitle(session),
                            value: session.revision.map { "rev \($0)" },
                            showsChevron: true,
                            showsDivider: index < visible.count - 1,
                            action: { Task { await open(session) } }
                        )
                    }
                }
            }
            PIListRow(
                title: "新建会话",
                subtitle: activeProjectId == nil
                    ? "先选一个项目（会话需要项目作为工作区）"
                    : "在「\(activeProjectName ?? "所选项目")」下新建会话",
                isEnabled: connection.state.isOnline && activeProjectId != nil,
                showsChevron: true,
                showsDivider: false,
                action: { showingNewSession = true }
            )
        }
    }

    private var visibleSessions: [RACPSessionSummary] {
        guard let activeProjectId else { return [] }
        return connection.sessions.filter {
            $0.projectId == activeProjectId
                && isSessionVisible(projectId: activeProjectId, sessionID: $0.id)
        }
    }

    private func sessionSubtitle(_ session: RACPSessionSummary) -> String {
        var parts: [String] = [session.id]
        if let hostID = model.currentHost?.id,
           let count = model.sessionBinding(hostID: hostID, sessionID: session.id)?.messageCount {
            parts.append("\(count) 条")
        }
        if let status = session.status { parts.append(status) }
        if let mode = session.mode { parts.append(mode.title) }
        if let permission = session.permissionMode { parts.append(permission.title) }
        return parts.joined(separator: " · ")
    }

    private func sessionDisplayTitle(_ session: RACPSessionSummary) -> String {
        guard let hostID = model.currentHost?.id else { return session.title ?? session.id }
        return model.sessionDisplayTitle(
            hostID: hostID,
            sessionID: session.id,
            fallback: session.title ?? session.id
        )
    }

    // MARK: - 动作

    private func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        await connection.refreshRemote()
    }

    private func openProjectBrowser() {
        guard model.currentHost != nil else {
            model.showToast("请先添加一台服务器")
            model.switchRoot(.settings)
            return
        }
        guard canOpenProjectBrowser else {
            model.showToast(connection.catalogError == nil
                ? "项目列表尚未加载完成，请稍后重试"
                : "项目列表加载失败，请先重试")
            if connection.state.isOnline {
                Task { await refresh() }
            }
            return
        }
        showingBrowser = true
    }

    private var canOpenProjectBrowser: Bool {
        connection.state.isOnline
            && connection.hasLoadedCatalog
            && connection.catalogError == nil
    }

    private func openProjectOrDetail(_ project: RACPProjectSummary) {
        currentProjectId = project.id
        model.rememberProject(project.id)
        guard let hostID = model.currentHost?.id else {
            selectedProject = project
            return
        }
        let candidate = model.sessionBindings
            .filter {
                $0.hostID == hostID
                    && $0.projectID == project.id
                    && !$0.isArchived
                    && !$0.isDeleted
            }
            .sorted { ($0.lastOpenedAt ?? .distantPast) > ($1.lastOpenedAt ?? .distantPast) }
            .first
        if let candidate,
           let remote = connection.sessions.first(where: { $0.id == candidate.sessionID }) {
            Task { await open(remote) }
        } else {
            selectedProject = project
        }
    }

    private func restore(_ project: RACPProjectSummary) {
        guard let hostID = model.currentHost?.id else { return }
        model.setProjectArchived(hostID: hostID, projectID: project.id, archived: false)
        currentProjectId = project.id
        model.rememberProject(project.id)
        model.showToast("已恢复项目「\(projectDisplayName(project))」")
    }

    private func archive(_ project: RACPProjectSummary) {
        guard let hostID = model.currentHost?.id else { return }
        model.setProjectArchived(hostID: hostID, projectID: project.id, archived: true)
        if currentProjectId == project.id {
            currentProjectId = nil
            advanceCurrentProject(excluding: project.id)
        }
        model.showToast("已归档项目「\(projectDisplayName(project))」")
    }

    private func delete(_ project: RACPProjectSummary) {
        guard let hostID = model.currentHost?.id else { return }
        let removedSessions = model.deleteProjectLocally(hostID: hostID, projectID: project.id)
        connection.removeCachedSessions(removedSessions)
        if currentProjectId == project.id {
            currentProjectId = nil
            advanceCurrentProject(excluding: project.id)
        }
        model.showToast("已从本机删除项目「\(projectDisplayName(project))」")
    }

    private func advanceCurrentProject(excluding projectID: String) {
        if let next = activeProjects.first(where: { $0.id != projectID }) {
            currentProjectId = next.id
            model.rememberProject(next.id)
        } else {
            model.rememberProject(nil)
        }
    }

    private func register(path: String, name: String) async throws {
        guard let hostID = model.currentHost?.id else {
            throw ProjectRegistrationIssue.missingHost
        }
        guard model.isCurrentHostPaired else {
            throw ProjectRegistrationIssue.notPaired
        }
        guard connection.state.isOnline else {
            throw ProjectRegistrationIssue.offline
        }
        guard connection.hasLoadedCatalog, connection.catalogError == nil else {
            throw ProjectRegistrationIssue.catalogUnavailable
        }

        let normalizedPath = ProjectDirectoryRules.normalizedPath(path)
        let previous = model.projectBinding(hostID: hostID, path: normalizedPath)
        let listedProjectIDs = Set(connection.projects.map(\.id))
        let registrationTargets = projectRegistrationTargets
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let project = try await connection.registerProject(path: normalizedPath)
            let wasAlreadyListed = listedProjectIDs.contains(project.id)
                || previous?.projectID == project.id
            let normalizedName = ProjectRegistrationRules.normalizedName(name)
            let unresolvedConflict = registrationTargets.contains {
                $0.projectId != project.id
                    && $0.path == nil
                    && ProjectRegistrationRules.normalizedName($0.displayName) == normalizedName
            }
            let recordedName = unresolvedConflict
                ? ProjectRegistrationRules.uniqueName(
                    base: normalizedName,
                    existing: registrationTargets.filter { $0.projectId != project.id }
                )
                : normalizedName
            model.recordProjectBinding(
                hostID: hostID,
                projectID: project.id,
                path: normalizedPath,
                name: recordedName
            )
            model.rememberProjectBrowserPath(hostID: hostID, path: normalizedPath)
            currentProjectId = project.id
            model.rememberProject(project.id)
            await connection.refreshRemote()
            actionError = nil
            if recordedName != normalizedName {
                model.showToast(
                    "目录已注册；为避免重名，项目名称已调整为「\(recordedName)」"
                )
            } else if previous?.projectID == project.id || wasAlreadyListed {
                if previous?.name != recordedName {
                    model.showToast("已更新项目名称并切换为当前项目")
                } else {
                    model.showToast("该项目已存在，已切换为当前项目")
                }
            } else {
                model.showToast("已注册项目「\(recordedName)」")
            }
        } catch {
            actionError = ConnectionErrorText.describe(error)
            throw error
        }
    }

    private func createSession(title: String?) async {
        guard let hostID = model.currentHost?.id else {
            actionError = "没有当前服务器"
            return
        }
        let projectID = activeProjectId
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let created = try await connection.createSession(title: title, projectId: projectID)
            model.recordCreatedSession(
                hostID: hostID,
                sessionID: created.id,
                projectID: created.projectId ?? projectID,
                title: created.title
            )
            await connection.refreshRemote()
            guard model.currentHost?.id == hostID else {
                model.showToast("会话已在原服务器创建；切换回该服务器后可继续")
                return
            }
            model.rememberSession(created.id)
            await connection.session.attach(sessionId: created.id)
            model.switchRoot(.conversation)
        } catch {
            actionError = ConnectionErrorText.describe(error)
        }
    }

    private func open(_ summary: RACPSessionSummary) async {
        if let projectID = summary.projectId {
            currentProjectId = projectID
            model.rememberProject(projectID)
        }
        model.rememberSession(summary.id)
        await connection.session.attach(sessionId: summary.id)
        model.switchRoot(.conversation)
    }
}

// MARK: - 目录浏览（AC-08.4）

private struct ProjectBrowserSheet: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var connection: ConnectionModel
    @Environment(\.dismiss) private var dismiss

    let initialPath: String?
    let existingProjects: [ProjectRegistrationTarget]
    let onRegister: (String, String) async throws -> Void

    @State private var path: String?
    @State private var entries: [BrowserEntry] = []
    @State private var nameDraft = ProjectNameDraft()
    @State private var isLoading = false
    @State private var isRegistering = false
    @State private var directoryError: String?
    @State private var registrationError: String?
    @State private var verifiedPath: String?
    @State private var parentPath: String?
    @State private var loadSequence = 0

    init(
        initialPath: String?,
        existingProjects: [ProjectRegistrationTarget],
        onRegister: @escaping (String, String) async throws -> Void
    ) {
        self.initialPath = initialPath
        self.existingProjects = existingProjects
        self.onRegister = onRegister
    }

    struct BrowserEntry: Identifiable, Equatable {
        let id: String
        let name: String
        let isDirectory: Bool
    }

    private var canUseServer: Bool {
        model.currentHost != nil
            && model.isCurrentHostPaired
            && connection.state.isOnline
            && connection.hasLoadedCatalog
            && connection.catalogError == nil
    }

    var body: some View {
        NavigationStack {
            List {
                if let gateMessage {
                    Section {
                        PIStatusBanner(
                            kind: .warning,
                            text: lockTitle,
                            detail: gateMessage,
                            actionTitle: gateActionTitle,
                            action: performGateAction
                        )
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    }
                }
                if let directoryError {
                    VStack(alignment: .leading, spacing: PISpacing.s8) {
                        Text(directoryError)
                            .font(PIFont.caption)
                            .foregroundStyle(PIColor.danger)
                            .fixedSize(horizontal: false, vertical: true)
                        if canUseServer, !isLoading {
                            Button(path == nil ? "重试读取目录" : "重试当前目录") {
                                Task { await load(path, useInitialPath: false) }
                            }
                            .font(PIFont.captionStrong)
                        }
                    }
                }
                if let registrationError {
                    Text(registrationError)
                        .font(PIFont.caption)
                        .foregroundStyle(PIColor.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Section {
                    TextField("项目名称", text: projectNameBinding)
                        .disabled(isRegistering)
                        .accessibilityIdentifier("projectBrowser.name")
                    if let nameIssue {
                        Text(nameIssue.message)
                            .font(PIFont.caption)
                            .foregroundStyle(PIColor.danger)
                    } else {
                        Text("默认取目录名，可改写；只影响本机显示。")
                            .font(PIFont.caption)
                            .foregroundStyle(PIColor.text3)
                    }
                } header: {
                    Text("项目名称")
                }

                Section {
                    if let path {
                        Text(path)
                            .font(PIFont.meta)
                            .foregroundStyle(PIColor.text2)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("projectBrowser.currentPath")
                    }
                    if isLoading {
                        HStack(spacing: PISpacing.s8) {
                            ProgressView()
                            Text("正在读取目录")
                                .font(PIFont.caption)
                                .foregroundStyle(PIColor.text2)
                        }
                    }
                    if canUseServer, let parentPath {
                        Button {
                            Task { await load(parentPath) }
                        } label: {
                            HStack(spacing: PISpacing.s8) {
                                Image(systemName: "arrow.up")
                                    .foregroundStyle(PIColor.accent)
                                Text("返回上级目录")
                                    .foregroundStyle(PIColor.text)
                                Spacer()
                            }
                        }
                        .disabled(isLoading || isRegistering)
                        .accessibilityIdentifier("projectBrowser.parent")
                    }
                    if canUseServer {
                        ForEach(entries) { entry in
                            Button {
                                if entry.isDirectory { Task { await load(entry.id) } }
                            } label: {
                                HStack(spacing: PISpacing.s8) {
                                    Image(systemName: entry.isDirectory ? "folder" : "doc")
                                        .foregroundStyle(entry.isDirectory ? PIColor.accent : PIColor.text3)
                                    Text(entry.name)
                                        .foregroundStyle(entry.isDirectory ? PIColor.text : PIColor.text3)
                                    Spacer()
                                    if entry.isDirectory {
                                        Image(systemName: "chevron.right")
                                            .font(PIFont.meta)
                                            .foregroundStyle(PIColor.text3)
                                    }
                                }
                            }
                            .disabled(!entry.isDirectory || isLoading || isRegistering)
                            .accessibilityIdentifier("projectBrowser.entry.\(entry.id)")
                        }
                    }
                    if canUseServer, entries.isEmpty, !isLoading, directoryError == nil {
                        Text("这个目录没有子目录")
                            .font(PIFont.caption)
                            .foregroundStyle(PIColor.text3)
                    }
                } header: {
                    Text("当前目录")
                } footer: {
                    if canUseServer {
                        Text("逐级进入目标目录，再用该目录注册项目。")
                            .font(PIFont.caption)
                    }
                }

            }
            .scrollContentBackground(.hidden)
            .piPageBackground()
            .refreshable {
                await load(path, useInitialPath: false)
            }
            .piDetailNavBar("选择服务器目录")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(isRegistering)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                registrationFooter
            }
            .interactiveDismissDisabled(isRegistering)
            .accessibilityIdentifier("projectBrowser.sheet")
            .task { await load(initialPath, fallbackToHome: initialPath != nil) }
            .onChange(of: connection.state.isOnline) { _, _ in
                Task { await load(path ?? initialPath, fallbackToHome: path != nil) }
            }
            .onChange(of: connection.hasLoadedCatalog) { _, _ in
                Task { await load(path ?? initialPath, fallbackToHome: path != nil) }
            }
            .onChange(of: connection.catalogError) { _, _ in
                Task { await load(path ?? initialPath, fallbackToHome: path != nil) }
            }
        }
    }

    private var registrationFooter: some View {
        VStack(alignment: .leading, spacing: PISpacing.s8) {
            HStack(alignment: .firstTextBaseline, spacing: PISpacing.s8) {
                Text(projectName.piTrimmed.isEmpty ? "未命名项目" : projectName.piTrimmed)
                    .font(PIFont.captionStrong)
                    .foregroundStyle(PIColor.text)
                    .lineLimit(1)
                Spacer(minLength: PISpacing.s8)
                Text(registrationHint)
                    .font(PIFont.meta)
                    .foregroundStyle(
                        nameIssue == nil && canUseServer ? PIColor.text2 : PIColor.danger
                    )
                    .lineLimit(1)
            }
            if let path {
                Text(path)
                    .font(PIFont.meta)
                    .foregroundStyle(PIColor.text3)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            PIPrimaryButton(
                title: isRegistering ? "正在注册…" : "用当前目录注册项目",
                isEnabled: canRegister,
                identifier: "projectBrowser.register"
            ) {
                Task { await submit() }
            }
        }
        .padding(.horizontal, PIMetrics.pageMargin)
        .padding(.top, PISpacing.s12)
        .padding(.bottom, PISpacing.s8)
        .background(PIColor.surface)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PIColor.separator)
                .frame(height: 1)
        }
    }

    private var lockTitle: String {
        if model.currentHost == nil { return "还没有服务器" }
        if !model.isCurrentHostPaired { return "服务器尚未配对" }
        if connection.catalogError != nil { return "项目列表加载失败" }
        if !connection.hasLoadedCatalog { return "项目列表尚未就绪" }
        return "服务器离线"
    }

    private var gateRequiresSettings: Bool {
        model.currentHost == nil
            || !model.isCurrentHostPaired
            || !connection.state.isOnline
    }

    private var gateActionTitle: String {
        gateRequiresSettings ? "打开设置" : "重试"
    }

    private func performGateAction() {
        if gateRequiresSettings {
            dismiss()
            model.showSettings()
        } else {
            Task { await connection.refreshRemote() }
        }
    }

    private var gateMessage: String? {
        if model.currentHost == nil {
            return "先添加服务器并完成配对，才能浏览服务器目录。"
        }
        if !model.isCurrentHostPaired {
            return "完成配对后才能注册项目。"
        }
        if !connection.state.isOnline {
            return "恢复隧道连接后才能浏览目录并注册项目。"
        }
        if let catalogError = connection.catalogError {
            return "项目与会话列表加载失败：\(catalogError)"
        }
        if !connection.hasLoadedCatalog {
            return "正在读取项目与会话列表，完成后才能注册项目。"
        }
        return nil
    }

    private var nameIssue: ProjectRegistrationIssue? {
        guard canUseServer, let path else { return nil }
        return ProjectRegistrationRules.validate(
            name: projectName,
            path: path,
            existing: existingProjects,
            allowUnresolvedNameConflicts: true
        )
    }

    private var projectName: String {
        nameDraft.text
    }

    private var projectNameBinding: Binding<String> {
        Binding(
            get: { nameDraft.text },
            set: { nameDraft.edit($0) }
        )
    }

    private var canRegister: Bool {
        canUseServer
            && path != nil
            && verifiedPath == path
            && nameIssue == nil
            && directoryError == nil
            && !isLoading
            && !isRegistering
    }

    private var registrationHint: String {
        if !canUseServer { return lockTitle }
        if isLoading { return "正在读取目录" }
        if path == nil { return "先选择目录" }
        if let nameIssue { return nameIssue.message }
        if verifiedPath != path { return "目录尚未验证" }
        if isRegistering { return "正在保存" }
        if ProjectRegistrationRules.hasUnresolvedNameConflict(
            name: projectName,
            existing: existingProjects
        ) {
            return "提交后按服务器回执核验名称"
        }
        return "注册后切换为当前项目"
    }

    private func submit() async {
        guard !isRegistering else { return }
        guard let path else {
            registrationError = ProjectRegistrationIssue.missingPath.message
            return
        }
        guard verifiedPath == path else {
            registrationError = ProjectRegistrationIssue.invalidPath.message
            return
        }
        if let issue = ProjectRegistrationRules.validate(
            name: projectName,
            path: path,
            existing: existingProjects,
            allowUnresolvedNameConflicts: true
        ) {
            registrationError = issue.message
            return
        }
        registrationError = nil
        isRegistering = true
        defer { isRegistering = false }
        do {
            try await onRegister(path, ProjectRegistrationRules.normalizedName(projectName))
            dismiss()
        } catch {
            registrationError = errorText(error)
        }
    }

    private func load(
        _ target: String?,
        fallbackToHome: Bool = false,
        useInitialPath: Bool = true
    ) async {
        guard canUseServer else {
            loadSequence += 1
            isLoading = false
            entries = []
            verifiedPath = nil
            directoryError = nil
            if path == nil {
                path = target ?? initialPath
            }
            suggestNameIfNeeded()
            return
        }
        let sequence = loadSequence + 1
        loadSequence = sequence
        if path == nil, target == nil, useInitialPath {
            path = initialPath
        }
        isLoading = true
        defer {
            if loadSequence == sequence { isLoading = false }
        }
        do {
            let requestPath = target ?? (useInitialPath ? path : nil)
            let result = try await connection.browseProject(path: requestPath)
            guard loadSequence == sequence else { return }
            path = result.path
            verifiedPath = result.path
            parentPath = result.parent
            entries = ProjectDirectoryRules.entries(
                from: result.entries,
                currentPath: result.path
            ).map {
                BrowserEntry(
                    id: $0.path,
                    name: $0.name,
                    isDirectory: $0.isDirectory
                )
            }
            suggestNameIfNeeded()
            if let hostID = model.currentHost?.id {
                model.rememberProjectBrowserPath(hostID: hostID, path: result.path)
            }
            directoryError = nil
        } catch {
            guard loadSequence == sequence else { return }
            entries = []
            verifiedPath = nil
            if fallbackToHome {
                directoryError = nil
                path = nil
                parentPath = nil
                await load(nil, useInitialPath: false)
                return
            }
            if let target {
                path = target
                suggestNameIfNeeded()
            } else if path == nil, useInitialPath {
                path = initialPath
                suggestNameIfNeeded()
            }
            parentPath = nil
            directoryError = errorText(error)
        }
    }

    private func suggestNameIfNeeded() {
        guard let path else { return }
        nameDraft.suggestIfNeeded(for: path)
    }

    private func errorText(_ error: Error) -> String {
        if let issue = error as? ProjectRegistrationIssue {
            return issue.message
        }
        return ConnectionErrorText.describe(error)
    }
}

// MARK: - 新建会话（AC-08.2）

private struct NewSessionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let projectId: String?
    let projectName: String?
    let onCreate: (String?) -> Void

    @State private var title = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("会话标题（可留空）", text: $title)
                } footer: {
                    Text("留空时用首条消息作为标题；项目：\(projectName ?? projectId ?? "未选择")")
                        .font(PIFont.caption)
                }
            }
            .piPageBackground()
            .piDetailNavBar("新建会话")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") {
                        onCreate(title.piTrimmed.isEmpty ? nil : title.piTrimmed)
                        dismiss()
                    }
                    .disabled(projectId == nil)
                }
            }
        }
    }
}
