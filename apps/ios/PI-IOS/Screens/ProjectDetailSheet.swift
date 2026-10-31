import SwiftUI
import PIiOSCore

struct ProjectSummaryRow: View {
    let projectID: String
    let name: String
    let sessionCount: Int
    let runningCount: Int
    let pendingCount: Int
    let isCurrent: Bool
    let showsDivider: Bool
    let onOpen: () -> Void
    let onDetails: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: PISpacing.s8) {
                Button(action: onOpen) {
                    HStack(alignment: .center, spacing: PISpacing.s8) {
                        VStack(alignment: .leading, spacing: PISpacing.s4) {
                            Text(name)
                                .font(PIFont.listTitle)
                                .foregroundStyle(PIColor.text)
                                .multilineTextAlignment(.leading)
                            HStack(spacing: PISpacing.s8) {
                                if isCurrent {
                                    Text("当前")
                                        .font(PIFont.metaSmall)
                                        .foregroundStyle(PIColor.accent)
                                }
                                Text(summary)
                                    .font(PIFont.caption)
                                    .foregroundStyle(PIColor.text2)
                            }
                        }
                        Spacer(minLength: PISpacing.s8)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(PIColor.text3)
                    }
                    .padding(.leading, PISpacing.s16)
                    .padding(.vertical, PISpacing.s12)
                    .frame(maxWidth: .infinity, minHeight: PIMetrics.listRowMinHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(name)，\(isCurrent ? "当前项目，" : "")\(summary)")
                .accessibilityIdentifier("projects.row.\(projectID)")

                Button("详情", action: onDetails)
                    .font(PIFont.captionStrong)
                    .foregroundStyle(PIColor.accent)
                    .frame(minWidth: 54, minHeight: PIMetrics.minHitTarget)
                    .contentShape(Rectangle())
                    .padding(.trailing, PISpacing.s12)
                    .accessibilityLabel("查看 \(name) 详情")
                    .accessibilityIdentifier("projects.details.\(projectID)")
            }
            if showsDivider { PIRowDivider() }
        }
    }

    private var summary: String {
        var parts: [String] = ["\(sessionCount) 个会话"]
        if runningCount > 0 { parts.append("运行 \(runningCount)") }
        if pendingCount > 0 { parts.append("待处理 \(pendingCount)") }
        return parts.joined(separator: " · ")
    }
}

struct ProjectDetailSheet: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var connection: ConnectionModel
    @Environment(\.dismiss) private var dismiss

    let project: RACPProjectSummary
    let initialName: String
    let onOpenSession: (RACPSessionSummary) -> Void
    let onNewSession: () -> Void
    let onArchive: () -> Void
    let onDelete: () -> Void
    let onRestore: () -> Void

    @State private var projectName: String
    @State private var nameError: String?
    @State private var showingDeleteConfirm = false

    init(
        project: RACPProjectSummary,
        initialName: String,
        onOpenSession: @escaping (RACPSessionSummary) -> Void,
        onNewSession: @escaping () -> Void,
        onArchive: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onRestore: @escaping () -> Void
    ) {
        self.project = project
        self.initialName = initialName
        self.onOpenSession = onOpenSession
        self.onNewSession = onNewSession
        self.onArchive = onArchive
        self.onDelete = onDelete
        self.onRestore = onRestore
        _projectName = State(initialValue: initialName)
    }

    private var hostID: UUID? { model.currentHost?.id }

    private var binding: StoredProjectBinding? {
        guard let hostID else { return nil }
        return model.projectBinding(hostID: hostID, projectID: project.id)
    }

    private var sessions: [RACPSessionSummary] {
        connection.sessions.filter { session in
            guard session.projectId == project.id else { return false }
            guard let hostID else { return true }
            return !(model.sessionBinding(hostID: hostID, sessionID: session.id)?.isDeleted ?? false)
        }
    }

    private var runningCount: Int {
        sessions.filter { ($0.status?.lowercased() ?? "").contains("running") }.count
    }

    private var activeSessionCount: Int {
        guard let hostID else { return 0 }
        return sessions.filter { session in
            guard let binding = model.sessionBinding(hostID: hostID, sessionID: session.id) else {
                return false
            }
            return !binding.isArchived && !binding.isDeleted
        }.count
    }

    private var isArchived: Bool {
        binding?.isArchived ?? false
    }

    private var sessionStatisticsText: String {
        guard connection.hasLoadedCatalog else {
            return "会话统计等待服务器返回"
        }
        let suffix = isCatalogStale ? " · 上次同步" : ""
        return "\(sessions.count) 个会话 · \(activeSessionCount) 个活跃 · 运行中 \(runningCount)\(suffix)"
    }

    private var isCatalogStale: Bool {
        !connection.state.isOnline || connection.catalogError != nil
    }

    private var canCreateSession: Bool {
        connection.state.isOnline
            && !isArchived
    }

    private var newSessionSubtitle: String? {
        if isArchived { return "项目已归档；恢复后才能新建会话" }
        if !connection.state.isOnline { return "服务器离线，暂不能新建" }
        return nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: PISpacing.s24) {
                    PICard {
                        Text(binding?.name ?? initialName)
                            .font(PIFont.navTitle)
                            .foregroundStyle(PIColor.text)
                        Text(binding?.path ?? "路径未在本机记录；服务器上的目录不会因此改变。")
                            .font(PIFont.caption)
                            .foregroundStyle(PIColor.text2)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(sessionStatisticsText)
                            .font(PIFont.meta)
                            .foregroundStyle(PIColor.text3)
                    }
                    if !connection.hasLoadedCatalog {
                        PIStatusBanner(
                            kind: .info,
                            text: "正在读取项目与会话",
                            detail: "统计和会话列表会在服务器返回完整目录后更新。"
                        )
                    } else if let catalogError = connection.catalogError {
                        PIStatusBanner(
                            kind: .warning,
                            text: "项目数据可能不是最新",
                            detail: catalogError,
                            actionTitle: connection.isRefreshingCatalog ? "正在重试…" : "重试",
                            action: { Task { await connection.refreshRemote() } }
                        )
                    } else if !connection.state.isOnline {
                        PIStatusBanner(
                            kind: .warning,
                            text: "服务器离线",
                            detail: "当前显示上次同步的会话统计，恢复连接后自动更新。"
                        )
                    }

                    PIGroup("项目名称", footer: "名称只影响本机显示；同一 Host 内不能重名。") {
                        VStack(alignment: .leading, spacing: PISpacing.s8) {
                            TextField("项目名称", text: $projectName)
                                .textFieldStyle(.roundedBorder)
                            if let nameError {
                                Text(nameError)
                                    .font(PIFont.caption)
                                    .foregroundStyle(PIColor.danger)
                            }
                            PIPrimaryButton(title: "保存名称", isEnabled: canSaveName) {
                                saveName()
                            }
                        }
                        .padding(PISpacing.s16)
                    }

                    PIGroup("会话", footer: "归档的会话仍保留在本机，可随时恢复。") {
                        if !connection.hasLoadedCatalog {
                            PIListRow(
                                title: "会话列表尚未加载",
                                subtitle: "联网后会自动读取",
                                isEnabled: false,
                                showsDivider: false
                            )
                        } else if sessions.isEmpty {
                            PIListRow(
                                title: connection.catalogError == nil
                                    && connection.state.isOnline
                                    ? "这个项目下还没有会话"
                                    : "暂时无法确认这个项目的会话",
                                subtitle: !isCatalogStale
                                    ? "用下方按钮新建"
                                    : "请先重试刷新",
                                isEnabled: false,
                                showsDivider: false
                            )
                        } else {
                            ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                                sessionRow(session, showsDivider: index < sessions.count - 1)
                            }
                        }
                    }

                    PIListRow(
                        title: "在此项目新建会话",
                        subtitle: newSessionSubtitle,
                        isEnabled: canCreateSession,
                        showsChevron: true,
                        showsDivider: false,
                        action: onNewSession
                    )
                    .background(PIColor.surface, in: RoundedRectangle(cornerRadius: PIRadius.group))

                    PIGroup("项目状态") {
                        PIListRow(
                            title: isArchived ? "恢复项目" : "归档项目",
                            subtitle: isArchived
                                ? "恢复到项目主列表"
                                : "只从主列表收起，会话与服务器内容不变",
                            showsDivider: true,
                            action: {
                                if isArchived {
                                    onRestore()
                                } else {
                                    onArchive()
                                }
                            }
                        )
                        .accessibilityIdentifier("projectDetail.archive")
                        PIDangerRow(
                            title: "从本机删除项目",
                            action: { showingDeleteConfirm = true }
                        )
                        .accessibilityIdentifier("projectDetail.delete")
                    }
                }
                .padding(.horizontal, PIMetrics.pageMargin)
                .padding(.vertical, PISpacing.s16)
            }
            .piPageBackground()
            .piDetailNavBar("项目详情")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .alert("从本机删除这个项目？", isPresented: $showingDeleteConfirm) {
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) {
                    onDelete()
                    dismiss()
                }
            } message: {
                Text("只移除本机项目记录、会话记录与缓存；服务器上的目录、文件、provider 与会话历史不会被删除。")
            }
            .onChange(of: model.projectBindings) { _, _ in
                if let current = binding?.name, projectName != current {
                    projectName = current
                }
            }
        }
    }

    private var canSaveName: Bool {
        let trimmed = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != (binding?.name ?? initialName)
    }

    private func saveName() {
        guard let hostID else { return }
        if model.renameProject(hostID: hostID, projectID: project.id, name: projectName) {
            nameError = nil
            model.showToast("项目名称已更新")
        } else {
            nameError = "项目名称不能为空，且同一 Host 内不能重名"
        }
    }

    private func sessionRow(_ session: RACPSessionSummary, showsDivider: Bool) -> some View {
        let hostID = self.hostID
        let binding = hostID.flatMap { model.sessionBinding(hostID: $0, sessionID: session.id) }
        let archived = binding?.isArchived ?? false
        let title = hostID.map {
            model.sessionDisplayTitle(hostID: $0, sessionID: session.id, fallback: session.title ?? session.id)
        } ?? (session.title ?? session.id)
        return VStack(spacing: 0) {
            HStack(spacing: PISpacing.s8) {
                Button {
                    if archived { restoreSession(session) } else { onOpenSession(session) }
                } label: {
                    VStack(alignment: .leading, spacing: PISpacing.s4) {
                        Text(title)
                            .font(PIFont.listTitle)
                            .foregroundStyle(PIColor.text)
                        Text(archived ? "已归档" : (session.status ?? "idle"))
                            .font(PIFont.caption)
                            .foregroundStyle(archived ? PIColor.text3 : PIColor.text2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(minHeight: PIMetrics.minHitTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("projectDetail.session.\(session.id)")
                if archived {
                    Button("恢复") { restoreSession(session) }
                        .font(PIFont.captionStrong)
                        .foregroundStyle(PIColor.accent)
                        .accessibilityIdentifier("projectDetail.restoreSession.\(session.id)")
                }
            }
            .padding(.horizontal, PISpacing.s16)
            .padding(.vertical, PISpacing.s12)
            if showsDivider { PIRowDivider() }
        }
    }

    private func restoreSession(_ session: RACPSessionSummary) {
        guard let hostID else { return }
        model.setSessionArchived(hostID: hostID, sessionID: session.id, archived: false)
        onOpenSession(session)
    }
}
