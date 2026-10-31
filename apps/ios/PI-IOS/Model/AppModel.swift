import Foundation
import Combine
import SwiftUI
import PIiOSCore
import PIiOSNet

/// 应用状态：三个根页的导航状态、本机服务器记录、本机偏好、提示。
///
/// 本机记录 + 偏好 + 提示；隧道/RACP 的实时状态在 `connection`（`ConnectionModel`）里，
/// 界面只读它的真实值，不自行推断在线。
@MainActor
final class AppModel: ObservableObject {
    /// 三个一级入口（information-architecture.md §1「根」）。
    enum Root: String, CaseIterable, Identifiable {
        case projects
        case conversation
        case settings

        var id: String { rawValue }

        var title: String {
            switch self {
            case .projects: return "项目"
            case .conversation: return "会话"
            case .settings: return "设置"
            }
        }
    }

    @Published private(set) var hosts: [HostRecord] = []
    @Published private(set) var offlineCacheLimit: Int = PersistedState.defaultOfflineCacheLimit
    @Published private(set) var modelProviders: [StoredModelProvider] = []
    @Published private(set) var projectBindings: [StoredProjectBinding] = []
    @Published private(set) var sessionBindings: [StoredSessionBinding] = []
    @Published private(set) var lastSessionByHost: [String: String] = [:]
    @Published private(set) var lastProjectByHost: [String: String] = [:]
    @Published private(set) var collapsedProjectGroups: [String] = []
    @Published private(set) var projectBrowserPaths: [String: String] = [:]
    private var readingPositionsByHost: [String: [String: ConversationReadingPosition]] = [:]
    /// 本机状态文件读取异常时的说明；nil 表示正常。
    @Published private(set) var loadWarning: String?
    /// 最近一次写入本机文件失败的原因；nil 表示正常。
    @Published private(set) var saveError: String?

    /// 隧道与 RACP 的实时状态（服务器页测试连接、设置页状态、项目页列表都读它）。
    let connection: ConnectionModel
    let usesUITestFixture: Bool
    private var tunnelObservation: AnyCancellable?
    private var remoteObservation: AnyCancellable?
    private var hostSwitchGeneration = 0
    private var foregroundNotificationTransitionID: UUID?
    private var deferredStatePersistenceTask: Task<Void, Never>?
    private var canPersistLoadedState = true
    private var pendingHostID: UUID?
    private var providerConnectionGeneration = 0
    private var providerIdentityGeneration = 0
    private var foregroundResumeTracker = ForegroundResumeTracker()
    @Published private(set) var resumedSessionUpdates = ForegroundSessionUpdateMarkers()

    @Published var root: Root = .settings
    @Published var isSidebarOpen = false
    @Published var toast: PIToast?
    /// 上次打开的会话与项目（AC-18.6：切回 host / 重启后恢复上下文）。
    @Published private(set) var lastSessionId: String?
    @Published private(set) var lastProjectId: String?

    init() {
        let fixture = UITestFixture.current
        usesUITestFixture = fixture != nil
        connection = ConnectionModel(fixture: fixture)
        let outcome = fixture.map { StateFile.LoadOutcome(state: $0.state, warning: nil) }
            ?? StateFile.load()
        hosts = outcome.state.hosts
        offlineCacheLimit = outcome.state.offlineCacheLimit
        modelProviders = outcome.state.modelProviders
        lastSessionId = outcome.state.lastSessionId
        lastProjectId = outcome.state.lastProjectId
        projectBindings = outcome.state.projectBindings
        sessionBindings = outcome.state.sessionBindings
        lastSessionByHost = outcome.state.lastSessionByHost
        lastProjectByHost = outcome.state.lastProjectByHost
        collapsedProjectGroups = outcome.state.collapsedProjectGroups
        projectBrowserPaths = outcome.state.projectBrowserPaths
        readingPositionsByHost = outcome.state.readingPositionsByHost
        if let host = hosts.first(where: { $0.isCurrent }) ?? hosts.first {
            if lastProjectByHost[host.id.uuidString] == nil {
                lastProjectByHost[host.id.uuidString] = outcome.state.lastProjectId
            }
            if lastSessionByHost[host.id.uuidString] == nil {
                lastSessionByHost[host.id.uuidString] = outcome.state.lastSessionId
            }
        }
        loadWarning = outcome.warning
        canPersistLoadedState = outcome.canSave
        if !usesUITestFixture {
            migrateLegacyDeviceTokens()
        }
        root = LandingRule.initialRoot(hosts: hosts)
        connection.updateOfflineCacheLimit(offlineCacheLimit)
        connection.setCacheHostID(hosts.first(where: { $0.isCurrent })?.id ?? hosts.first?.id)
        connection.onResolvedHostPort = { [weak self] hostID, port in
            self?.applyDiscoveredHostPort(hostID: hostID, port: port)
        }
        observeTunnelState()
        observeRemoteMetadata()
        if usesUITestFixture {
            root = .conversation
            isSidebarOpen = true
            return
        }
        Task { [weak self] in
            await self?.connectCurrentHostIfPaired()
        }
    }

    /// Migrate endpoint-scoped device tokens from pre-UUID builds without ever
    /// letting a second Host inherit the first Host's token.
    private func migrateLegacyDeviceTokens() {
        var changed = false
        let groups = Dictionary(grouping: hosts) { host in
            KeychainStore.account(username: host.username, host: host.host, port: host.port)
        }
        for (legacyAccount, group) in groups {
            let unscoped = group.filter { !KeychainStore.hasScopedDeviceToken(hostID: $0.id) }
            if group.count == 1,
               let host = group.first,
               host.pairedAt != nil,
               host.hostPort != nil {
                if KeychainStore.migrateLegacyDeviceToken(
                    hostID: host.id,
                    legacyAccount: legacyAccount
                ) {
                    KeychainStore.deleteLegacyDeviceToken(account: legacyAccount)
                    continue
                }
            }

            // A legacy token cannot prove which pi-host port issued it. Fail
            // closed and require each ambiguous Host to pair again.
            for host in unscoped {
                guard let index = hosts.firstIndex(where: { $0.id == host.id }),
                      hosts[index].pairedAt != nil
                else { continue }
                hosts[index].pairedAt = nil
                hosts[index].tunnelUpAt = nil
                changed = true
            }
            // The ambiguous legacy value must not survive until deleting a Host
            // later makes the group look attributable again.
            KeychainStore.deleteLegacyDeviceToken(account: legacyAccount)
        }
        if changed {
            persist()
            if loadWarning == nil {
                loadWarning = "旧版本的部分设备令牌无法唯一归属到 Host，已要求重新配对。"
            }
        }
    }

    /// 记住当前项目（切换 host 后用于恢复）。
    func rememberProject(_ projectId: String?) {
        lastProjectId = projectId
        guard let hostID = currentHost?.id else {
            persist()
            return
        }
        if let projectId {
            lastProjectByHost[hostID.uuidString] = projectId
        } else {
            lastProjectByHost.removeValue(forKey: hostID.uuidString)
        }
        persist()
    }

    /// 记住当前会话（切换 host 后用于恢复）。
    func rememberSession(_ sessionId: String?) {
        lastSessionId = sessionId
        guard let hostID = currentHost?.id else {
            persist()
            return
        }
        if let sessionId {
            foregroundResumeTracker.open(hostID: hostID, sessionID: sessionId)
            resumedSessionUpdates.open(hostID: hostID, sessionID: sessionId)
            lastSessionByHost[hostID.uuidString] = sessionId
            if let index = sessionBindings.firstIndex(where: {
                $0.hostID == hostID && $0.sessionID == sessionId
            }) {
                sessionBindings[index].lastOpenedAt = Date()
                sessionBindings[index].isUnread = false
                sessionBindings[index].updatedAt = Date()
            }
        } else {
            lastSessionByHost.removeValue(forKey: hostID.uuidString)
        }
        persist()
    }

    /// 离线缓存行被显式点选时，把它记在该 Host 名下。
    ///
    /// 不能靠“缓存列表第一条”猜会话；同一进程切换 Host 或重启后都要按 Host 恢复用户的选择。
    func selectCachedSession(hostID: UUID, sessionID: String) {
        guard hosts.contains(where: { $0.id == hostID }) else { return }
        foregroundResumeTracker.open(hostID: hostID, sessionID: sessionID)
        resumedSessionUpdates.open(hostID: hostID, sessionID: sessionID)
        if let index = sessionBindings.firstIndex(where: {
            $0.hostID == hostID && $0.sessionID == sessionID
        }) {
            sessionBindings[index].isUnread = false
        }
        lastSessionId = sessionID
        lastSessionByHost[hostID.uuidString] = sessionID
        persist()
    }

    func cachedSessionSelectionID(for hostID: UUID) -> String? {
        lastSessionByHost[hostID.uuidString]
    }

    func captureBackgroundBaseline() {
        let snapshot = foregroundSnapshot()
        foregroundResumeTracker.capture(snapshot)
        guard let snapshot else {
            foregroundNotificationTransitionID = nil
            return
        }
        let transitionID = UUID()
        foregroundNotificationTransitionID = transitionID
        LocalNotificationCoordinator.shared.beginForegroundTransition(
            id: transitionID,
            baseline: notificationBaseline(from: snapshot)
        )
    }

    var hasPendingForegroundResume: Bool { foregroundResumeTracker.hasPendingResume }

    func resumeFromBackground() async {
        guard !Task.isCancelled, let ticket = foregroundResumeTracker.beginResume() else { return }
        defer { foregroundResumeTracker.retry(ticket) }
        let deadline = Date().addingTimeInterval(30)
        let hostID = ticket.baseline.hostID
        guard let host = currentHost, host.id == hostID else {
            foregroundResumeTracker.capture(nil)
            return
        }
        guard host.pairedAt != nil else {
            foregroundResumeTracker.capture(nil)
            foregroundNotificationTransitionID = nil
            return
        }
        if !connection.state.isOnline {
            let generation = hostSwitchGeneration &+ 1
            await setCurrentHost(id: hostID, waitForOnline: false)
            guard hostSwitchGeneration == generation else { return }
        }
        let generation = hostSwitchGeneration
        let onlineBudget = max(0.1, deadline.timeIntervalSinceNow)
        guard !Task.isCancelled,
              await connection.waitUntilOnline(timeout: onlineBudget),
              hostSwitchGeneration == generation, currentHost?.id == hostID,
              await connection.refreshRemote(
                  timeout: max(0.1, deadline.timeIntervalSinceNow)
              ),
              !Task.isCancelled, hostSwitchGeneration == generation, currentHost?.id == hostID
        else { return }
        // Merge synchronously: the Combine observer schedules its merge on a later turn.
        mergeRemoteMetadata(
            hostID: hostID,
            projects: connection.projects,
            sessions: connection.sessions
        )
        if connection.session.attachedSessionId == nil,
           let sessionID = lastSessionByHost[hostID.uuidString] {
            await connection.session.attach(sessionId: sessionID)
        } else {
            await connection.session.refreshView()
        }

        guard !Task.isCancelled,
              hostSwitchGeneration == generation, currentHost?.id == hostID,
              let snapshot = foregroundSnapshot()
        else { return }
        let updates = foregroundResumeTracker.complete(ticket, current: snapshot)
        resumedSessionUpdates.record(updates)
        if let transitionID = foregroundNotificationTransitionID {
            foregroundNotificationTransitionID = nil
            await LocalNotificationCoordinator.shared.completeForegroundTransition(
                id: transitionID,
                current: notificationSnapshot(from: snapshot)
            )
        } else if !updates.isEmpty {
            await LocalNotificationCoordinator.shared.notifyUpdates(count: updates.count)
        }
    }

    private func notificationBaseline(
        from snapshot: ForegroundResumeSnapshot
    ) -> BackgroundNotificationBaseline {
        BackgroundNotificationBaseline(
            hostID: snapshot.hostID,
            sessionRevisions: snapshot.sessions.compactMapValues(\.revision),
            pendingApprovalIDs: Set(
                snapshot.sessions.values.compactMap(\.pendingApprovalIDs).flatMap { $0 }
            )
        )
    }

    private func notificationSnapshot(
        from snapshot: ForegroundResumeSnapshot
    ) -> BackgroundNotificationSnapshot {
        BackgroundNotificationSnapshot(
            hostID: snapshot.hostID,
            sessionRevisions: snapshot.sessions.compactMapValues(\.revision),
            pendingApprovalIDs: Set(
                snapshot.sessions.values.compactMap(\.pendingApprovalIDs).flatMap { $0 }
            )
        )
    }

    private func foregroundSnapshot() -> ForegroundResumeSnapshot? {
        guard let hostID = currentHost?.id else { return nil }
        var sessions: [String: ForegroundSessionState] = [:]
        if !connection.hasLoadedCatalog {
            for binding in sessionBindings where binding.hostID == hostID && !binding.isDeleted {
                sessions[binding.sessionID] = ForegroundSessionState(revision: binding.lastKnownRevision)
            }
        }
        for session in connection.sessions where sessionBinding(hostID: hostID, sessionID: session.id)?.isDeleted != true {
            sessions[session.id] = ForegroundSessionState(revision: session.revision, status: session.status)
        }
        let view = connection.session.view
        if let sessionID = connection.session.attachedSessionId, view.sessionId == sessionID,
           sessionBinding(hostID: hostID, sessionID: sessionID)?.isDeleted != true {
            var state = sessions[sessionID] ?? ForegroundSessionState(revision: view.revision)
            state.revision = max(state.revision ?? view.revision, view.revision)
            state.pendingApprovalIDs = Set(view.pendingApprovals.map(\.id))
            sessions[sessionID] = state
        }
        return ForegroundResumeSnapshot(hostID: hostID, sessions: sessions)
    }

    func hasSessionUpdate(hostID: UUID, sessionID: String) -> Bool {
        resumedSessionUpdates.contains(HostSessionReference(hostID: hostID, sessionID: sessionID))
            || sessionBinding(hostID: hostID, sessionID: sessionID)?.isUnread == true
    }

    func lastProjectID(for hostID: UUID) -> String? {
        lastProjectByHost[hostID.uuidString]
    }

    func lastSessionID(for hostID: UUID) -> String? {
        lastSessionByHost[hostID.uuidString]
    }

    // MARK: - 本机项目元数据

    func projectBinding(hostID: UUID, projectID: String) -> StoredProjectBinding? {
        projectBindings.first { $0.hostID == hostID && $0.projectID == projectID }
    }

    func projectBinding(hostID: UUID, path: String) -> StoredProjectBinding? {
        projectBindings.first { $0.hostID == hostID && $0.path == path }
    }

    func projectDisplayName(
        hostID: UUID,
        projectID: String,
        fallback: String
    ) -> String {
        if let local = projectBinding(hostID: hostID, projectID: projectID)?.name
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !local.isEmpty {
            return local
        }
        return fallback
    }

    func currentProjectDisplayName(projectID: String, fallback: String) -> String {
        guard let hostID = currentHost?.id else { return fallback }
        return projectDisplayName(hostID: hostID, projectID: projectID, fallback: fallback)
    }

    @discardableResult
    func recordProjectBinding(
        hostID: UUID,
        projectID: String,
        path: String?,
        name: String
    ) -> StoredProjectBinding {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let previous = projectBindings.first { binding in
            binding.hostID == hostID
                && (binding.projectID == projectID || (path != nil && binding.path == path))
        }
        projectBindings.removeAll { binding in
            guard binding.hostID == hostID else { return false }
            if binding.projectID == projectID { return true }
            guard let path, let oldPath = binding.path else { return false }
            return oldPath == path
        }
        let binding = StoredProjectBinding(
            hostID: hostID,
            projectID: projectID,
            path: path,
            name: normalizedName,
            source: .local,
            isArchived: false,
            isDeleted: false,
            createdAt: previous?.createdAt ?? Date(),
            updatedAt: Date()
        )
        projectBindings.append(binding)
        persist()
        return binding
    }

    func isProjectArchived(hostID: UUID, projectID: String) -> Bool {
        projectBinding(hostID: hostID, projectID: projectID)?.isArchived ?? false
    }

    func isProjectDeleted(hostID: UUID, projectID: String) -> Bool {
        projectBinding(hostID: hostID, projectID: projectID)?.isDeleted ?? false
    }

    func setProjectArchived(hostID: UUID, projectID: String, archived: Bool) {
        guard let index = projectBindings.firstIndex(where: {
            $0.hostID == hostID && $0.projectID == projectID
        }) else { return }
        projectBindings[index].isArchived = archived
        projectBindings[index].updatedAt = Date()
        if archived, lastProjectByHost[hostID.uuidString] == projectID {
            lastProjectByHost.removeValue(forKey: hostID.uuidString)
        }
        persist()
    }

    /// Returns cached session ids that callers should evict with the project.
    @discardableResult
    func deleteProjectLocally(hostID: UUID, projectID: String) -> [String] {
        let removedSessionIDs = sessionBindings
            .filter { $0.hostID == hostID && $0.projectID == projectID }
            .map(\.sessionID)
        if let index = projectBindings.firstIndex(where: {
            $0.hostID == hostID && $0.projectID == projectID
        }) {
            projectBindings[index].isDeleted = true
            projectBindings[index].isArchived = true
            projectBindings[index].updatedAt = Date()
        }
        for index in sessionBindings.indices where
            sessionBindings[index].hostID == hostID
                && sessionBindings[index].projectID == projectID {
            sessionBindings[index].isDeleted = true
            sessionBindings[index].isPinned = false
            sessionBindings[index].pinOrder = nil
            sessionBindings[index].updatedAt = Date()
        }
        for sessionID in removedSessionIDs {
            readingPositionsByHost[hostID.uuidString]?.removeValue(forKey: sessionID)
        }
        if readingPositionsByHost[hostID.uuidString]?.isEmpty == true {
            readingPositionsByHost.removeValue(forKey: hostID.uuidString)
        }
        if lastProjectByHost[hostID.uuidString] == projectID {
            lastProjectByHost.removeValue(forKey: hostID.uuidString)
        }
        if let lastSession = lastSessionByHost[hostID.uuidString],
           removedSessionIDs.contains(lastSession) {
            lastSessionByHost.removeValue(forKey: hostID.uuidString)
        }
        persist()
        return removedSessionIDs
    }

    @discardableResult
    func renameProject(hostID: UUID, projectID: String, name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let duplicate = projectBindings.contains {
            $0.hostID == hostID
                && $0.projectID != projectID
                && !$0.isDeleted
                && $0.name == trimmed
        }
        guard !duplicate else { return false }
        guard let index = projectBindings.firstIndex(where: {
            $0.hostID == hostID && $0.projectID == projectID
        }) else { return false }
        projectBindings[index].name = trimmed
        projectBindings[index].updatedAt = Date()
        persist()
        return true
    }

    func projectBrowserPath(hostID: UUID) -> String? {
        projectBrowserPaths[hostID.uuidString]
    }

    func rememberProjectBrowserPath(hostID: UUID, path: String) {
        guard projectBrowserPaths[hostID.uuidString] != path else { return }
        projectBrowserPaths[hostID.uuidString] = path
        persist()
    }

    // MARK: - 本机会话元数据

    func sessionBinding(hostID: UUID, sessionID: String) -> StoredSessionBinding? {
        sessionBindings.first { $0.hostID == hostID && $0.sessionID == sessionID }
    }

    func readingPosition(
        hostID: UUID,
        sessionID: String
    ) -> ConversationReadingPosition? {
        readingPositionsByHost[hostID.uuidString]?[sessionID]
    }

    func rememberReadingPosition(
        hostID: UUID,
        sessionID: String,
        lastVisibleItemID: String?,
        isNearBottom: Bool
    ) {
        let normalizedItemID = lastVisibleItemID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let next = ConversationReadingPosition(
            lastVisibleItemID: normalizedItemID?.isEmpty == false ? normalizedItemID : nil,
            isNearBottom: isNearBottom
        )
        let hostKey = hostID.uuidString
        let current = readingPositionsByHost[hostKey]?[sessionID]
        guard current != next else { return }
        readingPositionsByHost[hostKey, default: [:]][sessionID] = next
        deferredStatePersistenceTask?.cancel()
        deferredStatePersistenceTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            self?.persist()
            self?.deferredStatePersistenceTask = nil
        }
    }

    func flushPersistentState() {
        deferredStatePersistenceTask?.cancel()
        deferredStatePersistenceTask = nil
        persist()
    }

    func sessionDisplayTitle(
        hostID: UUID,
        sessionID: String,
        fallback: String
    ) -> String {
        let override = sessionBinding(hostID: hostID, sessionID: sessionID)?
            .titleOverride?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let override, !override.isEmpty { return override }
        return fallback
    }

    func recordCreatedSession(
        hostID: UUID,
        sessionID: String,
        projectID: String?,
        title: String?,
        now: Date = Date()
    ) {
        sessionBindings.removeAll { $0.hostID == hostID && $0.sessionID == sessionID }
        sessionBindings.append(
            StoredSessionBinding(
                hostID: hostID,
                sessionID: sessionID,
                projectID: projectID,
                titleOverride: title,
                source: .local,
                isArchived: false,
                lastOpenedAt: now,
                lastActivityAt: now,
                updatedAt: now
            )
        )
        persist()
    }

    func updateSessionActivity(
        hostID: UUID,
        sessionID: String,
        messageCount: Int,
        markRead: Bool = true
    ) {
        guard let index = sessionBindings.firstIndex(where: {
            $0.hostID == hostID && $0.sessionID == sessionID
        }) else { return }
        sessionBindings[index].messageCount = messageCount
        sessionBindings[index].lastActivityAt = Date()
        if markRead {
            sessionBindings[index].isUnread = false
        }
        sessionBindings[index].updatedAt = Date()
        persist()
    }

    @discardableResult
    func renameSession(hostID: UUID, sessionID: String, title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard let index = sessionBindings.firstIndex(where: {
            $0.hostID == hostID && $0.sessionID == sessionID
        }) else { return false }
        sessionBindings[index].titleOverride = trimmed
        sessionBindings[index].updatedAt = Date()
        persist()
        return true
    }

    func setSessionArchived(hostID: UUID, sessionID: String, archived: Bool) {
        guard let index = sessionBindings.firstIndex(where: {
            $0.hostID == hostID && $0.sessionID == sessionID
        }) else { return }
        sessionBindings[index].isArchived = archived
        if archived {
            sessionBindings[index].isPinned = false
            sessionBindings[index].pinOrder = nil
        }
        sessionBindings[index].updatedAt = Date()
        persist()
    }

    func pinSession(hostID: UUID, sessionID: String) {
        guard let index = sessionBindings.firstIndex(where: {
            $0.hostID == hostID && $0.sessionID == sessionID
        }), !sessionBindings[index].isPinned else { return }
        let projectID = sessionBindings[index].projectID
        let maxOrder = sessionBindings
            .filter {
                $0.hostID == hostID
                    && $0.projectID == projectID
                    && $0.isPinned
                    && !$0.isDeleted
            }
            .compactMap(\.pinOrder)
            .max() ?? -1
        sessionBindings[index].isPinned = true
        sessionBindings[index].pinOrder = maxOrder + 1
        sessionBindings[index].updatedAt = Date()
        persist()
    }

    func unpinSession(hostID: UUID, sessionID: String) {
        guard let index = sessionBindings.firstIndex(where: {
            $0.hostID == hostID && $0.sessionID == sessionID
        }) else { return }
        sessionBindings[index].isPinned = false
        sessionBindings[index].pinOrder = nil
        sessionBindings[index].updatedAt = Date()
        normalizePinOrders(hostID: hostID, projectID: sessionBindings[index].projectID)
        persist()
    }

    func movePinnedSession(
        hostID: UUID,
        projectID: String?,
        sessionID: String,
        before targetID: String
    ) {
        let group = sessionBindings
            .filter {
                $0.hostID == hostID
                    && $0.projectID == projectID
                    && $0.isPinned
                    && !$0.isDeleted
                    && !$0.isArchived
            }
        let orders = Dictionary(uniqueKeysWithValues: group.compactMap { item in
            item.pinOrder.map { (item.sessionID, $0) }
        })
        let moved = SessionOrderingPolicy.movePinned(
            group.map(\.sessionID),
            pinnedOrders: orders,
            sourceID: sessionID,
            before: targetID
        )
        guard moved != orders else { return }
        for (id, order) in moved {
            guard let index = sessionBindings.firstIndex(where: {
                $0.hostID == hostID && $0.sessionID == id
            }) else { continue }
            sessionBindings[index].pinOrder = order
        }
        persist()
    }

    private func normalizePinOrders(hostID: UUID, projectID: String?) {
        let pinned = sessionBindings
            .filter {
                $0.hostID == hostID
                    && $0.projectID == projectID
                    && $0.isPinned
                    && !$0.isDeleted
            }
            .sorted { ($0.pinOrder ?? Int.max) < ($1.pinOrder ?? Int.max) }
        for (order, item) in pinned.enumerated() {
            guard let index = sessionBindings.firstIndex(where: { $0.id == item.id }) else { continue }
            sessionBindings[index].pinOrder = order
        }
    }

    func isProjectGroupCollapsed(hostID: UUID, projectID: String) -> Bool {
        collapsedProjectGroups.contains("\(hostID.uuidString):\(projectID)")
    }

    func toggleProjectGroup(hostID: UUID, projectID: String) {
        let key = "\(hostID.uuidString):\(projectID)"
        if let index = collapsedProjectGroups.firstIndex(of: key) {
            collapsedProjectGroups.remove(at: index)
        } else {
            collapsedProjectGroups.append(key)
        }
        persist()
    }

    /// 当前服务器：`isCurrent` 优先，其次第一条（不合成「幽灵」记录）。
    var currentHost: HostRecord? {
        hosts.first(where: { $0.isCurrent }) ?? hosts.first
    }

    var isCurrentHostPaired: Bool { currentHost?.pairedAt != nil }

    var currentModelProviders: [StoredModelProvider] {
        guard let hostID = currentHost?.id else { return [] }
        return modelProviders
            .filter { $0.hostID == hostID }
            .sorted { $0.importedAt > $1.importedAt }
    }

    var currentModelGroups: [ProviderModelGroup] {
        currentModelGrouping.groups
    }

    var currentModelGrouping: ModelGroupingResult {
        groupModelsByProviderDetailed(
            currentModelProviders.map { provider in
                ProviderRecord(
                    providerId: provider.providerId,
                    name: provider.name,
                    models: provider.records(defaultModelId: provider.defaultModelId)
                )
            }
        )
    }

    var currentModelDiagnostics: [ModelGroupingDiagnostic] {
        currentModelGrouping.diagnostics
    }

    var defaultModelLabel: String {
        guard let provider = currentModelProviders.first(where: { $0.defaultModelId != nil }),
              let modelId = provider.defaultModelId,
              let model = provider.models.first(where: { $0.id == modelId })
        else { return "未配置" }
        return "\(provider.name) · \(model.displayName)"
    }

    // MARK: - 导航

    func openSidebar() { isSidebarOpen = true }

    func closeSidebar() { isSidebarOpen = false }

    func switchRoot(_ target: Root) {
        root = target
        isSidebarOpen = false
    }

    /// 抽屉里点「设置」并希望落在服务器列表时使用：切根并保持抽屉关闭。
    func showSettings() { switchRoot(.settings) }

    // MARK: - 主机记录

    @discardableResult
    func addHost(_ draft: HostDraft) -> HostRecord? {
        let errors = HostValidator.validate(draft)
        guard errors.isValid else { return nil }
        let host = draft.host.piTrimmed
        let record = HostRecord(
            id: UUID(),
            name: draft.name.piTrimmed.isEmpty ? host : draft.name.piTrimmed,
            host: host,
            port: Int(draft.port.piTrimmed) ?? 22,
            username: draft.username.piTrimmed,
            authKind: draft.authKind,
            createdAt: Date(),
            isCurrent: hosts.isEmpty,
            pairedAt: nil,
            tunnelUpAt: nil,
            hostPort: Int(draft.hostPort.piTrimmed),
            keyFileName: draft.keyFileName
        )
        hosts.append(record)
        persist()
        return record
    }

    @discardableResult
    func updateHost(id: UUID, with draft: HostDraft) -> Bool {
        guard let index = hosts.firstIndex(where: { $0.id == id }) else { return false }
        // 编辑态不要求重新输入凭证：未接 Keychain 前凭证不落盘，改名称/端口也应能保存。
        let errors = HostValidator.validate(draft, requiresSecret: false)
        guard errors.isValid else { return false }
        let host = draft.host.piTrimmed
        let previousHost = hosts[index].host
        let previousPort = hosts[index].port
        let previousUsername = hosts[index].username
        let previousHostPort = hosts[index].hostPort
        let previousAuthKind = hosts[index].authKind
        let wasCurrent = hosts[index].isCurrent
        let previousAccount = KeychainStore.account(
            username: previousUsername,
            host: previousHost,
            port: previousPort
        )
        let newPort = Int(draft.port.piTrimmed) ?? hosts[index].port
        let serverIdentityChanged = previousHost != host
            || previousPort != newPort
            || previousUsername != draft.username.piTrimmed
        hosts[index].name = draft.name.piTrimmed.isEmpty ? host : draft.name.piTrimmed
        hosts[index].host = host
        hosts[index].port = newPort
        hosts[index].username = draft.username.piTrimmed
        hosts[index].authKind = draft.authKind
        hosts[index].hostPort = Int(draft.hostPort.piTrimmed)
        hosts[index].keyFileName = draft.keyFileName
        if (serverIdentityChanged || previousHostPort != hosts[index].hostPort
            || previousAuthKind != hosts[index].authKind),
           wasCurrent || pendingHostID == id {
            providerIdentityGeneration &+= 1
            if wasCurrent { foregroundResumeTracker.capture(nil) }
        }
        if previousHostPort != hosts[index].hostPort {
            hosts[index].pairedAt = nil
            hosts[index].tunnelUpAt = nil
            hosts[index].installReceipt = nil
            // 同一 SSH 服务器上的另一个 pi-host 端口是**另一个端点**，其项目、
            // 会话、缓存与配对都不属于新端点。仅清配对状态会把旧端点的数据留在
            // 同一 hostKey 下混显（契约 §数据隔离：不得混显、不得跨 host 回填）。
            clearHostDerivedData(id, detachSession: wasCurrent)
            KeychainStore.deleteDeviceToken(
                hostID: id,
                legacyAccount: previousAccount,
                deleteLegacy: false
            )
        }
        if serverIdentityChanged {
            hosts[index].pairedAt = nil
            hosts[index].tunnelUpAt = nil
            hosts[index].installReceipt = nil
            // 同一 UUID 现在指向另一台服务器，所有由旧服务器派生的本机数据都必须失效。
            clearHostDerivedData(id, detachSession: wasCurrent)
            let anotherHostUsesOldAccount = hosts.contains { other in
                other.id != id
                    && KeychainStore.account(
                        username: other.username,
                        host: other.host,
                        port: other.port
                    ) == previousAccount
            }
            if !anotherHostUsesOldAccount {
                KeychainStore.deleteDeviceToken(
                    hostID: id,
                    legacyAccount: previousAccount,
                    deleteLegacy: true
                )
                KeychainStore.deleteHostKey(account: previousAccount)
            } else {
                KeychainStore.deleteDeviceToken(
                    hostID: id,
                    legacyAccount: previousAccount,
                    deleteLegacy: false
                )
            }
        }
        persist()
        return true
    }

    @discardableResult
    func deleteHost(id: UUID) async -> Bool {
        guard let host = hosts.first(where: { $0.id == id }) else { return false }
        let wasCurrent = host.isCurrent
        if wasCurrent || pendingHostID == id {
            hostSwitchGeneration &+= 1
            let generation = hostSwitchGeneration
            if wasCurrent {
                await connection.disconnect(ifHostID: id)
            }
            guard hostSwitchGeneration == generation,
                  hosts.contains(where: { $0.id == id })
            else { return false }
        }
        // 删除 host 只删本地记录与凭证（契约 §2.4），不动服务器上的任何东西。
        let account = KeychainStore.account(username: host.username, host: host.host, port: host.port)
        let anotherHostUsesAccount = hosts.contains { other in
            other.id != id
                && KeychainStore.account(
                    username: other.username,
                    host: other.host,
                    port: other.port
                ) == account
        }
        if !anotherHostUsesAccount {
            KeychainStore.deleteCredential(account: account)
            KeychainStore.deleteHostKey(account: account)
        }
        KeychainStore.deleteDeviceToken(
            hostID: id,
            legacyAccount: account,
            deleteLegacy: !anotherHostUsesAccount
        )
        clearHostDerivedData(id, detachSession: wasCurrent)
        hosts.removeAll { $0.id == id }
        if wasCurrent, !hosts.isEmpty {
            hosts[0].isCurrent = true
            connection.setCacheHostID(hosts[0].id)
        } else if hosts.isEmpty {
            connection.setCacheHostID(nil)
        }
        if pendingHostID == id { pendingHostID = nil }
        persist()
        return true
    }

    /// 清掉某个 Host UUID 下的全部派生数据，但保留 Host 身份记录本身。
    ///
    /// `deleteHost` 与“当前 Host 改成另一台服务器”共用这份规则，避免只清凭证却继续展示
    /// 旧服务器的模型、项目、会话与离线历史。
    private func clearHostDerivedData(_ id: UUID, detachSession: Bool) {
        let hostKey = id.uuidString
        let clearsCurrentContext = currentHost?.id == id
        modelProviders.removeAll { $0.hostID == id }
        projectBindings.removeAll { $0.hostID == id }
        sessionBindings.removeAll { $0.hostID == id }
        resumedSessionUpdates.removeHost(id)
        if clearsCurrentContext { foregroundResumeTracker.capture(nil) }
        connection.removeCachedHost(id)
        lastProjectByHost.removeValue(forKey: hostKey)
        lastSessionByHost.removeValue(forKey: hostKey)
        collapsedProjectGroups.removeAll { $0.hasPrefix("\(hostKey):") }
        projectBrowserPaths.removeValue(forKey: hostKey)
        readingPositionsByHost.removeValue(forKey: hostKey)
        if clearsCurrentContext {
            lastProjectId = nil
            lastSessionId = nil
            if detachSession {
                connection.session.detach()
            }
        }
    }

    /// 修改连接身份前先原子关闭旧 client，避免界面显示新地址但操作仍打到旧服务器。
    func prepareHostIdentityChange(id: UUID) async -> Int? {
        guard currentHost?.id == id else { return nil }
        hostSwitchGeneration &+= 1
        let generation = hostSwitchGeneration
        pendingHostID = id
        await connection.disconnect(ifHostID: id)
        guard hostSwitchGeneration == generation else { return nil }
        return generation
    }

    func finishHostIdentityChange(id: UUID, generation: Int) {
        guard hostSwitchGeneration == generation, pendingHostID == id else { return }
        pendingHostID = nil
    }

    func canApplyHostIdentityChange(id: UUID, generation: Int) -> Bool {
        hostSwitchGeneration == generation && currentHost?.id == id
    }

    func beginHostOperation(hostID: UUID) -> Int {
        hostSwitchGeneration &+= 1
        pendingHostID = hostID
        return hostSwitchGeneration
    }

    func canApplyHostOperation(_ generation: Int, hostID: UUID) -> Bool {
        hostSwitchGeneration == generation
            && hosts.contains(where: { $0.id == hostID })
    }

    /// 配对成功后更新本机记录；设备令牌本身只存 Keychain。
    func markHostPaired(id: UUID) {
        guard let index = hosts.firstIndex(where: { $0.id == id }) else { return }
        hosts[index].pairedAt = Date()
        persist()
    }

    /// Bootstrap success is persisted only after the runner has paired, saved
    /// the token to Keychain, restarted the user unit, and verified `ping` with
    /// that device token.
    @discardableResult
    func completeHostInstallation(
        id: UUID,
        expectedHost: String,
        expectedPort: Int,
        expectedUsername: String,
        port: Int,
        version: String,
        attemptId: String,
        completedAt: Date = Date()
    ) -> Bool {
        guard let index = hosts.firstIndex(where: { $0.id == id }) else { return false }
        guard hosts[index].host == expectedHost,
              hosts[index].port == expectedPort,
              hosts[index].username == expectedUsername else {
            saveError = "安装完成时服务器身份已变化，未把旧安装结果写回当前记录"
            return false
        }
        hosts[index].hostPort = port
        hosts[index].pairedAt = completedAt
        hosts[index].installReceipt = HostInstallReceipt(
            version: version,
            hostPort: port,
            attemptId: attemptId,
            completedAt: completedAt
        )
        return persist()
    }

    /// Write a port discovered over SSH back onto the host record (requirement:
    /// the user must not configure a host port). The device token stays valid
    /// because this is the same Host the client just resolved.
    func applyDiscoveredHostPort(hostID: UUID, port: Int) {
        guard (1...65_535).contains(port),
              let index = hosts.firstIndex(where: { $0.id == hostID }),
              hosts[index].hostPort != port
        else { return }
        hosts[index].hostPort = port
        persist()
    }

    func providerOperationContext(for host: HostRecord) -> ProviderOperationContext? {
        guard let current = currentHost, current.id == host.id,
              current.host == host.host, current.port == host.port,
              current.username == host.username, current.hostPort == host.hostPort,
              current.authKind == host.authKind,
              pendingHostID == nil
        else { return nil }
        return ProviderOperationContext(
            hostID: host.id, address: host.host, sshPort: host.port, username: host.username,
            hostPort: host.hostPort, authKind: host.authKind.rawValue,
            hostGeneration: hostSwitchGeneration, identityGeneration: providerIdentityGeneration,
            connectionGeneration: providerConnectionGeneration
        )
    }

    /// The locally stored provider for a Host-side provider id, if any. Used to
    /// carry forward the legacy mapping when the v2 record is edited in place.
    func storedProvider(hostID: UUID, providerId: String) -> StoredModelProvider? {
        modelProviders.first { $0.hostID == hostID && $0.providerId == providerId }
    }

    func canApplyProviderOperation(_ context: ProviderOperationContext) -> Bool {
        context.canApply(to: currentHost.flatMap { providerOperationContext(for: $0) })
    }

    @discardableResult
    func recordImportedProvider(
        context: ProviderOperationContext,
        input: ProviderCreateInput,
        providerId: String,
        serverDefaultSet: Bool,
        legacyProviderId: String? = nil,
        hostV2Mirror: Bool? = nil
    ) -> Bool {
        guard canApplyProviderOperation(context) else { return false }
        let hostID = context.hostID
        let previousDefault = modelProviders.first {
            $0.hostID == hostID && $0.providerId == providerId
        }?.defaultModelId
        let defaultModelId = currentModelProviders.isEmpty && serverDefaultSet
            ? input.defaultModelId
            : previousDefault.flatMap { id in input.models.contains(where: { $0.id == id }) ? id : nil }
        modelProviders.removeAll { $0.hostID == hostID && $0.providerId == providerId }
        modelProviders.append(
            StoredModelProvider(
                providerId: providerId,
                legacyProviderId: legacyProviderId,
                hostV2Mirror: hostV2Mirror,
                hostID: hostID,
                name: input.name,
                baseURL: input.baseUrl ?? "",
                apiStyle: input.apiStyle ?? "chat_completions",
                models: input.models.map(StoredModelBinding.init(spec:)),
                defaultModelId: defaultModelId,
                importedAt: Date()
            )
        )
        persist()
        return true
    }

    @discardableResult
    func removeLocalProvider(id: String, context: ProviderOperationContext) -> Bool {
        guard canApplyProviderOperation(context) else { return false }
        modelProviders.removeAll { $0.id == id && $0.hostID == context.hostID }
        persist()
        return true
    }

    private func observeTunnelState() {
        tunnelObservation = connection.$state.sink { [weak self] state in
            self?.providerConnectionGeneration &+= 1
            guard state.isOnline else { return }
            Task { @MainActor in
                guard let self, let index = self.hosts.firstIndex(where: { $0.isCurrent }) else { return }
                self.hosts[index].tunnelUpAt = Date()
                self.persist()
            }
        }
    }

    private func observeRemoteMetadata() {
        remoteObservation = Publishers.CombineLatest(
            connection.$projects,
            connection.$sessions
        )
        .sink { [weak self] projects, sessions in
            guard let self else { return }
            let sourceHostID = self.connection.currentCatalogHostID
            Task { @MainActor in
                guard let sourceHostID,
                      self.currentHost?.id == sourceHostID,
                      self.connection.currentCatalogHostID == sourceHostID
                else { return }
                self.mergeRemoteMetadata(
                    hostID: sourceHostID,
                    projects: projects,
                    sessions: sessions
                )
            }
        }
    }

    private func mergeRemoteMetadata(
        hostID: UUID,
        projects: [RACPProjectSummary],
        sessions: [RACPSessionSummary]
    ) {
        let now = Date()
        var changed = false

        for project in projects {
            if let index = projectBindings.firstIndex(where: {
                $0.hostID == hostID && $0.projectID == project.id
            }) {
                if projectBindings[index].isDeleted { continue }
                if projectBindings[index].name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    projectBindings[index].name = project.label ?? project.id
                    projectBindings[index].updatedAt = now
                    changed = true
                }
            } else {
                projectBindings.append(
                    StoredProjectBinding(
                        hostID: hostID,
                        projectID: project.id,
                        path: nil,
                        name: project.label ?? project.id,
                        source: .upstream,
                        isArchived: true,
                        createdAt: now,
                        updatedAt: now
                    )
                )
                changed = true
            }
        }

        for session in sessions {
            if let index = sessionBindings.firstIndex(where: {
                $0.hostID == hostID && $0.sessionID == session.id
            }) {
                if sessionBindings[index].isDeleted { continue }
                if sessionBindings[index].projectID != session.projectId {
                    sessionBindings[index].projectID = session.projectId
                    changed = true
                }
                if sessionBindings[index].lastKnownRevision != session.revision {
                    if sessionBindings[index].lastKnownRevision != nil,
                       connection.session.attachedSessionId != session.id {
                        sessionBindings[index].isUnread = true
                    }
                    sessionBindings[index].lastKnownRevision = session.revision
                    sessionBindings[index].lastActivityAt = now
                    sessionBindings[index].updatedAt = now
                    changed = true
                }
                if connection.session.attachedSessionId == session.id,
                   sessionBindings[index].isUnread {
                    sessionBindings[index].isUnread = false
                    changed = true
                }
            } else {
                sessionBindings.append(
                    StoredSessionBinding(
                        hostID: hostID,
                        sessionID: session.id,
                        projectID: session.projectId,
                        source: .upstream,
                        isArchived: true,
                        lastActivityAt: now,
                        lastKnownRevision: session.revision,
                        updatedAt: now
                    )
                )
                changed = true
            }
        }
        if changed { persist() }
    }

    private func connectCurrentHostIfPaired() async {
        guard let host = currentHost, host.pairedAt != nil else { return }
        await setCurrentHost(id: host.id)
    }

    /// 切换当前服务器（AC-18.2）：关掉旧隧道、按新 host 的凭证重连，并恢复它上次的会话。
    func setCurrentHost(id: UUID, waitForOnline: Bool = true) async {
        guard hosts.contains(where: { $0.id == id }) else { return }
        let previousHostID = currentHost?.id
        hostSwitchGeneration &+= 1
        let generation = hostSwitchGeneration
        pendingHostID = id
        // 先清空旧连接的目录与隧道，避免旧 Host 的列表在新 Host 标记生效后到达本机元数据合并。
        if let previousHostID {
            await connection.disconnect(ifHostID: previousHostID)
        }
        guard hostSwitchGeneration == generation,
              hosts.contains(where: { $0.id == id })
        else { return }
        for index in hosts.indices {
            hosts[index].isCurrent = (hosts[index].id == id)
        }
        connection.setCacheHostID(id)
        persist()
        guard let host = currentHost else { return }
        await connection.connect(record: host)
        if hostSwitchGeneration == generation {
            pendingHostID = nil
        }
        guard hostSwitchGeneration == generation else {
            return
        }
        if waitForOnline {
            if await connection.waitUntilOnline(),
               let lastSession = lastSessionByHost[host.id.uuidString],
               hostSwitchGeneration == generation {
                await connection.session.attach(sessionId: lastSession)
            }
        }
        if hostSwitchGeneration == generation {
            pendingHostID = nil
        }
    }

    /// 撤销本机配对（AC-03.1）：先要求服务器 `session/revoke` 成功，再清本机凭证。
    ///
    /// 服务器没确认时**保留**本机凭证并如实返回结果——只删本地会让用户以为设备已被切断访问。
    @discardableResult
    func revokePairing(hostID: UUID) async -> String {
        guard let index = hosts.firstIndex(where: { $0.id == hostID }) else {
            return "这台服务器的本机记录已不存在"
        }
        let host = hosts[index]
        let revokedDeviceId = KeychainStore.loadDeviceId(hostID: hostID)
        let outcome = await connection.revokeThisDevice(host: host)
        guard outcome == ConnectionModel.deviceRevokedMessage else {
            showToast(outcome)
            return outcome
        }
        guard let index = hosts.firstIndex(where: {
            $0.id == hostID
                && $0.username == host.username
                && $0.host == host.host
                && $0.port == host.port
                && $0.hostPort == host.hostPort
        }),
        KeychainStore.loadDeviceId(hostID: hostID) == revokedDeviceId
        else {
            let stale = "Host 配置已变化：撤销回执未改动新的本机记录"
            showToast(stale)
            return stale
        }
        let account = KeychainStore.account(username: host.username, host: host.host, port: host.port)
        let anotherHostUsesAccount = hosts.contains { other in
            other.id != hostID
                && KeychainStore.account(
                    username: other.username,
                    host: other.host,
                    port: other.port
                ) == account
        }
        // 主机指纹属于服务器身份，撤销配对不删它（否则会静默失去 TOFU 保护）。
        // SSH 凭证按服务器端点共享；撤销某台 Host 的配对不能删除其他 hostPort
        // 的 Host 仍在使用的私钥或密码。
        KeychainStore.deleteDeviceToken(
            hostID: hostID,
            legacyAccount: account,
            deleteLegacy: !anotherHostUsesAccount
        )
        if !anotherHostUsesAccount {
            KeychainStore.deleteCredential(account: account)
        }
        hosts[index].pairedAt = nil
        hosts[index].tunnelUpAt = nil
        persist()
        await connection.disconnect(ifHostID: hostID)
        showToast(outcome)
        return outcome
    }

    // MARK: - 本机偏好

    func setOfflineCacheLimit(_ limit: Int) {
        let clamped = PersistedState.clampOfflineCacheLimit(limit)
        guard clamped != offlineCacheLimit else { return }
        offlineCacheLimit = clamped
        connection.updateOfflineCacheLimit(clamped)
        persist()
    }

    /// 缓存裁剪时必须传的上限（AC-15.1）：`CacheRetention.pruneItems(items, limit: cacheRetentionLimit)`。
    /// 传设置里的值而不是用无参默认值，否则设置里选 1000 也会按 200 淘汰。
    var cacheRetentionLimit: Int { PersistedState.clampOfflineCacheLimit(offlineCacheLimit) }

    // MARK: - 提示

    func showToast(_ text: String) {
        toast = PIToast(text: text)
    }

    func dismissToast() {
        toast = nil
    }

    func dismissLoadWarning() {
        loadWarning = nil
    }

    func dismissSaveError() {
        saveError = nil
    }

    // MARK: - 持久化

    private var snapshot: PersistedState {
        PersistedState(
            hosts: hosts,
            offlineCacheLimit: offlineCacheLimit,
            modelProviders: modelProviders,
            lastSessionId: lastSessionId,
            lastProjectId: lastProjectId,
            projectBindings: projectBindings,
            sessionBindings: sessionBindings,
            lastSessionByHost: lastSessionByHost,
            lastProjectByHost: lastProjectByHost,
            collapsedProjectGroups: collapsedProjectGroups,
            projectBrowserPaths: projectBrowserPaths,
            readingPositionsByHost: readingPositionsByHost
        )
    }

    @discardableResult
    private func persist() -> Bool {
        guard !usesUITestFixture else { return true }
        guard canPersistLoadedState else {
            saveError = "本机状态读取失败且原文件仍在，已暂停保存；请重启应用重试。"
            return false
        }
        do {
            try StateFile.save(snapshot)
            saveError = nil
            return true
        } catch {
            saveError = "保存本机记录失败：\(error.localizedDescription)"
            return false
        }
    }
}
