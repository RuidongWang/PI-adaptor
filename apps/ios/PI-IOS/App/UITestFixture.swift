import Foundation
import PIiOSCore
import PIiOSNet

/// FROZEN fixture contract: DEBUG + exact PI_IOS_UI_FIXTURE_SCENARIO only.
/// These are synthetic projections, never successful server responses.
/// offline-two-hosts starts on B; online-two-sessions supplies a read-only
/// in-memory catalog for sidebar interactions, without a transport or credentials.
struct UITestFixture {
    struct Catalog {
        let projects: [RACPProjectSummary]
        let sessions: [RACPSessionSummary]
        let info: RACPServerInfo
    }

    let state: PersistedState
    let cache: OfflineSessionCacheSnapshot
    var catalog: Catalog? = nil
    var catalogs: [UUID: Catalog] = [:]
    var sessionSnapshots: [String: RACPSessionView] = [:]
    var providerBindingStatuses: [String: ProviderBindingStatus] = [:]
    var supportsFixtureInterrupt = false
    var hostUnitSnapshot: HostUnitSnapshot? = nil
    var connectionState: RACPTunnelState? = nil

    static var current: Self? {
#if DEBUG
        switch ProcessInfo.processInfo.environment["PI_IOS_UI_FIXTURE_SCENARIO"] {
        case "offline-two-hosts": return offlineTwoHosts()
        case "offline-cache-205": return offlineCache205()
        case "online-two-sessions": return onlineTwoSessions()
        case "online-reading-two-sessions": return onlineReadingTwoSessions()
        case "online-large-tool-result": return onlineLargeToolResult()
        case "online-tool-result-body": return onlineToolResultBody()
        case "online-long-history-pending-approval": return onlineLongHistoryPendingApproval()
        case "online-project-lifecycle": return onlineProjectLifecycle()
        case "online-upstream-import": return onlineUpstreamImport()
        case "online-model-config": return onlineModelConfig()
        case "online-host-unit-active": return onlineHostUnitActive()
        case "online-host-unit-stopped": return onlineHostUnitStopped()
        case "online-two-hosts": return onlineTwoHosts()
        default: return nil
        }
#else
        return nil
#endif
    }

#if DEBUG
    private static func onlineReadingTwoSessions() -> Self {
        var fixture = onlineTwoSessions()
        for summary in fixture.catalog!.sessions {
            var snapshot = RACPSessionView.empty
            snapshot.sessionId = summary.id
            snapshot.summary = summary
            snapshot.revision = 1
            snapshot.replayComplete = true
            snapshot.cursor = RACPCursor(epoch: "fixture-reading-\(summary.id)", sequence: 40)
            snapshot.items = (1...40).map { index in
                let number = String(format: "%03d", index)
                let id = "reading-\(summary.id)-\(number)"
                return RACPItem(id: id, payload: .object([
                    "id": .string(id),
                    "role": .string("assistant"),
                    "text": .string("Reading \(summary.id) item \(number)\nStable synthetic history for reading-position verification.\nThis message belongs only to \(summary.id)."),
                ]))
            }
            fixture.sessionSnapshots[summary.id] = snapshot
        }
        return fixture
    }

    private static func onlineLargeToolResult() -> Self {
        var fixture = onlineTwoSessions()
        let summary = fixture.catalog!.sessions.first(where: { $0.id == "S1" })!
        var snapshot = RACPSessionView.empty
        snapshot.sessionId = summary.id
        snapshot.summary = summary
        snapshot.revision = 1
        snapshot.replayComplete = true
        snapshot.cursor = RACPCursor(epoch: "fixture-large-tool", sequence: 1)
        let text = String(repeating: "0123456789abcdef", count: 256 * 1024)
        snapshot.items = [
            RACPItem(id: "large-tool", payload: .object([
                "id": .string("large-tool"),
                "kind": .string("tool"),
                "role": .string("tool"),
                "toolName": .string("large-shell"),
                "status": .string("completed"),
                "text": .string(text),
            ])),
        ]
        fixture.sessionSnapshots[summary.id] = snapshot
        return fixture
    }

    /// 长历史 + 一张待审批卡片：审批卡片区在滚动内容最前面，而自动滚动一律滚到最底部。
    /// 这个夹具复刻真实故障现场——工具卡片写着「工具执行中…」，审批卡却被顶出视口上千点，
    /// 用户没法点头，工具就永远是「执行中」。
    private static func onlineLongHistoryPendingApproval() -> Self {
        var fixture = onlineReadingTwoSessions()
        let summary = fixture.catalog!.sessions.first(where: { $0.id == "S1" })!
        guard var snapshot = fixture.sessionSnapshots[summary.id] else { return fixture }
        snapshot.runningTurnId = "turn-pending-approval"
        snapshot.pendingApprovals = [
            try! RACPApprovalRequest(payload: .object([
                "id": .string("approval-bash-1"),
                "revision": .number(7),
                "kind": .string("tool"),
                "title": .string("bash"),
                "toolName": .string("bash"),
                "input": .object(["command": .string("echo test")])
            ]))
        ]
        snapshot.items.append(
            RACPItem(id: "call_pending", payload: .object([
                "id": .string("call_pending"),
                "itemType": .string("tool"),
                "kind": .string("tool"),
                "role": .string("tool"),
                "toolName": .string("bash"),
                "content": .object([
                    "itemId": .string("call_pending"),
                    "toolName": .string("bash"),
                    "input": .object(["command": .string("echo test")])
                ])
            ]))
        )
        fixture.sessionSnapshots[summary.id] = snapshot
        return fixture
    }


    /// 工具卡片正文（回归：卡片只显示「服务器没有返回工具输出正文。」）。
    ///
    /// 载荷按契约 §7.2 的真实帧形状给：`toolName` 来自 `tool.started`，
    /// 正文来自 `tool.completed` 的 `result`（Pi 的 `AgentToolResult`），
    /// 两条信息都落在同一条 `item.id` 上。
    private static func onlineToolResultBody() -> Self {
        var fixture = onlineTwoSessions()
        let summary = fixture.catalog!.sessions.first(where: { $0.id == "S1" })!
        var snapshot = RACPSessionView.empty
        snapshot.sessionId = summary.id
        snapshot.summary = summary
        snapshot.revision = 1
        snapshot.replayComplete = true
        snapshot.cursor = RACPCursor(epoch: "fixture-tool-body", sequence: 2)
        snapshot.items = [
            // 已完成：正文只存在于 content.result.content[].text。
            RACPItem(id: "call_done", payload: .object([
                "id": .string("call_done"),
                "itemType": .string("tool"),
                "kind": .string("tool"),
                "role": .string("tool"),
                "toolName": .string("bash"),
                "status": .string("completed"),
                "turnId": .string("turn_1"),
                "content": .object([
                    "itemId": .string("call_done"),
                    "status": .string("completed"),
                    "result": .object([
                        "content": .array([
                            .object(["type": .string("text"), "text": .string("hello-from-tool")])
                        ])
                    ])
                ])
            ])),
            // 运行中：还没有任何输出，卡片不得声称「服务器没有返回工具输出正文。」。
            RACPItem(id: "call_running", payload: .object([
                "id": .string("call_running"),
                "itemType": .string("tool"),
                "kind": .string("tool"),
                "role": .string("tool"),
                "toolName": .string("bash"),
                "turnId": .string("turn_1"),
                "content": .object([
                    "itemId": .string("call_running"),
                    "toolName": .string("bash"),
                    "input": .object(["command": .string("sleep 30")])
                ])
            ])),
        ]
        fixture.sessionSnapshots[summary.id] = snapshot
        return fixture
    }

    private static func onlineProjectLifecycle() -> Self {
        let hostID = UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!
        let time = Date(timeIntervalSince1970: 1_704_164_640)
        let projects = try! JSONDecoder().decode(
            RACPProjectListResult.self,
            from: Data(#"{"projects":[{"id":"P1","label":"Alpha Workspace","archived":false},{"id":"P2","label":"Beta Workspace","archived":false}]}"#.utf8)
        ).projects
        let sessions = try! JSONDecoder().decode(
            RACPSessionListResult.self,
            from: Data(#"{"sessions":[{"id":"S1","title":"Alpha One","projectId":"P1","status":"idle","revision":1},{"id":"S2","title":"Alpha Two","projectId":"P1","status":"idle","revision":1},{"id":"S3","title":"Beta One","projectId":"P2","status":"idle","revision":1}]}"#.utf8)
        ).sessions
        let host = HostRecord(
            id: hostID,
            name: "Fixture Lifecycle Host",
            host: "fixture-lifecycle.invalid",
            port: 22,
            username: "fixture",
            authKind: .privateKey,
            createdAt: time,
            isCurrent: true,
            pairedAt: time
        )
        let state = PersistedState(
            hosts: [host],
            lastSessionId: "S1",
            lastProjectId: "P1",
            projectBindings: [
                StoredProjectBinding(
                    hostID: hostID, projectID: "P1", path: "/fixture/alpha",
                    name: "Alpha Workspace", createdAt: time, updatedAt: time
                ),
                StoredProjectBinding(
                    hostID: hostID, projectID: "P2", path: "/fixture/beta",
                    name: "Beta Workspace", createdAt: time, updatedAt: time
                ),
            ],
            sessionBindings: sessions.enumerated().map { index, session in
                StoredSessionBinding(
                    hostID: hostID,
                    sessionID: session.id,
                    projectID: session.projectId,
                    messageCount: index + 1,
                    lastActivityAt: time.addingTimeInterval(Double(index) * 60),
                    lastKnownRevision: 1,
                    updatedAt: time
                )
            },
            lastSessionByHost: [hostID.uuidString: "S1"],
            lastProjectByHost: [hostID.uuidString: "P1"]
        )
        var fixture = Self(
            state: state,
            cache: OfflineSessionCacheSnapshot(),
            catalog: Catalog(
                projects: projects,
                sessions: sessions,
                info: RACPServerInfo(
                    protocolVersion: "1",
                    serverName: "Fixture Lifecycle",
                    serverVersion: "fixture-only",
                    hostId: hostID.uuidString,
                    connectionId: "fixture-lifecycle",
                    roles: []
                )
            )
        )
        for summary in sessions {
            var snapshot = RACPSessionView.empty
            snapshot.sessionId = summary.id
            snapshot.summary = summary
            snapshot.revision = 1
            snapshot.replayComplete = true
            snapshot.cursor = RACPCursor(epoch: "fixture-lifecycle-\(summary.id)", sequence: 1)
            snapshot.items = [
                RACPItem(id: "fixture-lifecycle-item-\(summary.id)", payload: .object([
                    "id": .string("fixture-lifecycle-item-\(summary.id)"),
                    "role": .string("assistant"),
                    "text": .string("Lifecycle history for \(summary.id)"),
                ])),
            ]
            fixture.sessionSnapshots[summary.id] = snapshot
        }
        return fixture
    }

    private static func onlineUpstreamImport() -> Self {
        let fixture = onlineProjectLifecycle()
        var state = fixture.state
        state.projectBindings = []
        state.sessionBindings = []
        state.lastProjectByHost = [:]
        state.lastSessionByHost = [:]
        state.lastProjectId = nil
        state.lastSessionId = nil
        return Self(
            state: state,
            cache: fixture.cache,
            catalog: fixture.catalog,
            sessionSnapshots: fixture.sessionSnapshots
        )
    }

    private static func onlineModelConfig() -> Self {
        let fixture = onlineProjectLifecycle()
        var state = fixture.state
        let hostID = state.hosts[0].id
        state.modelProviders = [
            StoredModelProvider(
                providerId: "prv_alpha",
                hostID: hostID,
                name: "Alpha Models",
                baseURL: "https://alpha.invalid",
                apiStyle: "chat_completions",
                models: [
                    StoredModelBinding(spec: ProviderModelSpec(
                        id: "alpha-pro",
                        contextWindow: 200_000,
                        maxTokens: 8_192,
                        thinkingLevels: ["off", "low", "high"],
                        defaultThinkingLevel: "low",
                        alias: "Alpha Pro"
                    )),
                ],
                defaultModelId: "alpha-pro",
                importedAt: Date(timeIntervalSince1970: 1_704_164_640)
            ),
            StoredModelProvider(
                providerId: "prv_beta",
                hostID: hostID,
                name: "Beta Models",
                baseURL: "https://beta.invalid",
                apiStyle: "chat_completions",
                models: [
                    StoredModelBinding(spec: ProviderModelSpec(
                        id: "beta-basic",
                        contextWindow: 32_000,
                        maxTokens: 4_096,
                        thinkingLevels: [],
                        alias: "Beta Basic"
                    )),
                ],
                defaultModelId: "beta-basic",
                importedAt: Date(timeIntervalSince1970: 1_704_164_640)
            ),
        ]
        var snapshots = fixture.sessionSnapshots
        if var running = snapshots["S2"] {
            running.activeItems = [
                RACPItem(id: "running-s2", payload: .object([
                    "id": .string("running-s2"),
                    "role": .string("assistant"),
                    "text": .string("S2 is running"),
                ])),
            ]
            running.runningTurnId = "turn-s2"
            snapshots["S2"] = running
        }
        return Self(
            state: state,
            cache: fixture.cache,
            catalog: fixture.catalog,
            sessionSnapshots: snapshots,
            providerBindingStatuses: [
                "S1": ProviderBindingStatus(
                    sessionId: "S1",
                    pinnedProviderId: "prv_alpha",
                    pinnedModelId: "alpha-pro",
                    pinnedThinkingLevel: "low",
                    effectiveProviderId: "prv_alpha",
                    effectiveModelId: "alpha-pro",
                    available: true,
                    unavailableReason: nil,
                    unknownInputs: [],
                    observedAt: "2026-10-30T00:00:00Z"
                ),
                "S2": ProviderBindingStatus(
                    sessionId: "S2",
                    pinnedProviderId: "prv_beta",
                    pinnedModelId: "beta-basic",
                    pinnedThinkingLevel: nil,
                    effectiveProviderId: "prv_beta",
                    effectiveModelId: "beta-basic",
                    available: true,
                    unavailableReason: nil,
                    unknownInputs: [],
                    observedAt: "2026-10-30T00:00:00Z"
                ),
            ],
            supportsFixtureInterrupt: true
        )
    }

    private static func onlineHostUnitActive() -> Self {
        var fixture = onlineProjectLifecycle()
        fixture.hostUnitSnapshot = HostUnitSnapshot(
            loadState: "loaded",
            activeState: "active",
            unitFileState: "enabled"
        )
        fixture.connectionState = .online
        return fixture
    }

    private static func onlineHostUnitStopped() -> Self {
        var fixture = onlineProjectLifecycle()
        fixture.hostUnitSnapshot = HostUnitSnapshot(
            loadState: "loaded",
            activeState: "inactive",
            unitFileState: "disabled"
        )
        fixture.connectionState = .offline(reason: "pi-adaptor systemd unit inactive")
        return fixture
    }

    private static func onlineTwoHosts() -> Self {
        let hostA = UUID(uuidString: "AAAAAAAA-1111-AAAA-1111-AAAAAAAAAAAA")!
        let hostB = UUID(uuidString: "BBBBBBBB-2222-BBBB-2222-BBBBBBBBBBBB")!
        let time = Date(timeIntervalSince1970: 1_704_164_640)
        let hosts = [
            HostRecord(
                id: hostA, name: "Fixture Online Host A", host: "fixture-oa.invalid",
                port: 22, username: "fixture", authKind: .privateKey,
                createdAt: time, isCurrent: false, pairedAt: time
            ),
            HostRecord(
                id: hostB, name: "Fixture Online Host B", host: "fixture-ob.invalid",
                port: 22, username: "fixture", authKind: .privateKey,
                createdAt: time, isCurrent: true, pairedAt: time
            ),
        ]
        let projectA = try! JSONDecoder().decode(
            RACPProjectListResult.self,
            from: Data(#"{"projects":[{"id":"A-project","label":"Host A Project","archived":false}]}"#.utf8)
        ).projects
        let projectB = try! JSONDecoder().decode(
            RACPProjectListResult.self,
            from: Data(#"{"projects":[{"id":"B-project","label":"Host B Project","archived":false}]}"#.utf8)
        ).projects
        let sessionA = try! JSONDecoder().decode(
            RACPSessionListResult.self,
            from: Data(#"{"sessions":[{"id":"A-session","title":"Host A Session","projectId":"A-project","status":"idle","revision":1}]}"#.utf8)
        ).sessions
        let sessionB = try! JSONDecoder().decode(
            RACPSessionListResult.self,
            from: Data(#"{"sessions":[{"id":"B-session","title":"Host B Session","projectId":"B-project","status":"idle","revision":1}]}"#.utf8)
        ).sessions
        let catalogA = Catalog(
            projects: projectA, sessions: sessionA,
            info: RACPServerInfo(
                protocolVersion: "1", serverName: "Fixture Online A",
                serverVersion: "fixture-only", hostId: hostA.uuidString,
                connectionId: "fixture-online-a", roles: []
            )
        )
        let catalogB = Catalog(
            projects: projectB, sessions: sessionB,
            info: RACPServerInfo(
                protocolVersion: "1", serverName: "Fixture Online B",
                serverVersion: "fixture-only", hostId: hostB.uuidString,
                connectionId: "fixture-online-b", roles: []
            )
        )
        let state = PersistedState(
            hosts: hosts,
            modelProviders: [
                StoredModelProvider(
                    providerId: "prv_host_a",
                    hostID: hostA,
                    name: "Host A Models",
                    baseURL: "https://host-a.invalid",
                    apiStyle: "chat_completions",
                    models: [StoredModelBinding(spec: ProviderModelSpec(
                        id: "model-a", contextWindow: 32_000, maxTokens: 4_096,
                        thinkingLevels: [], alias: "Model A"
                    ))],
                    defaultModelId: "model-a",
                    importedAt: time
                ),
                StoredModelProvider(
                    providerId: "prv_host_b",
                    hostID: hostB,
                    name: "Host B Models",
                    baseURL: "https://host-b.invalid",
                    apiStyle: "chat_completions",
                    models: [StoredModelBinding(spec: ProviderModelSpec(
                        id: "model-b", contextWindow: 64_000, maxTokens: 8_096,
                        thinkingLevels: [], alias: "Model B"
                    ))],
                    defaultModelId: "model-b",
                    importedAt: time
                ),
            ],
            lastSessionId: "B-session",
            lastProjectId: "B-project",
            projectBindings: [
                StoredProjectBinding(
                    hostID: hostA, projectID: "A-project", path: "/fixture/a",
                    name: "Host A Project", createdAt: time, updatedAt: time
                ),
                StoredProjectBinding(
                    hostID: hostB, projectID: "B-project", path: "/fixture/b",
                    name: "Host B Project", createdAt: time, updatedAt: time
                ),
            ],
            sessionBindings: [
                StoredSessionBinding(
                    hostID: hostA, sessionID: "A-session", projectID: "A-project",
                    lastActivityAt: time, lastKnownRevision: 1, updatedAt: time
                ),
                StoredSessionBinding(
                    hostID: hostB, sessionID: "B-session", projectID: "B-project",
                    lastActivityAt: time, lastKnownRevision: 1, updatedAt: time
                ),
            ],
            lastSessionByHost: [hostA.uuidString: "A-session", hostB.uuidString: "B-session"],
            lastProjectByHost: [hostA.uuidString: "A-project", hostB.uuidString: "B-project"]
        )
        var snapshots: [String: RACPSessionView] = [:]
        for (summary, title) in [(sessionA[0], "Host A Session"), (sessionB[0], "Host B Session")] {
            var snapshot = RACPSessionView.empty
            snapshot.sessionId = summary.id
            snapshot.summary = summary
            snapshot.revision = 1
            snapshot.replayComplete = true
            snapshot.cursor = RACPCursor(epoch: "fixture-\(summary.id)", sequence: 1)
            snapshot.items = [
                RACPItem(id: "\(summary.id)-item", payload: .object([
                    "id": .string("\(summary.id)-item"),
                    "role": .string("assistant"),
                    "text": .string("\(title) history"),
                ])),
            ]
            snapshots[summary.id] = snapshot
        }
        return Self(
            state: state,
            cache: OfflineSessionCacheSnapshot(),
            catalogs: [hostA: catalogA, hostB: catalogB],
            sessionSnapshots: snapshots,
            providerBindingStatuses: [
                "A-session": ProviderBindingStatus(
                    sessionId: "A-session", pinnedProviderId: "prv_host_a",
                    pinnedModelId: "model-a", pinnedThinkingLevel: nil,
                    effectiveProviderId: "prv_host_a", effectiveModelId: "model-a",
                    available: true, unavailableReason: nil, unknownInputs: [],
                    observedAt: "2026-10-30T00:00:00Z"
                ),
                "B-session": ProviderBindingStatus(
                    sessionId: "B-session", pinnedProviderId: "prv_host_b",
                    pinnedModelId: "model-b", pinnedThinkingLevel: nil,
                    effectiveProviderId: "prv_host_b", effectiveModelId: "model-b",
                    available: true, unavailableReason: nil, unknownInputs: [],
                    observedAt: "2026-10-30T00:00:00Z"
                ),
            ]
        )
    }

    private static func onlineTwoSessions() -> Self {
        let hostID = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
        let time = Date(timeIntervalSince1970: 1_704_164_640)
        let projectID = "fixture-online-project"
        let projects = try! JSONDecoder().decode(RACPProjectListResult.self, from: Data(#"{"projects":[{"id":"fixture-online-project","label":"Fixture Workspace","archived":false}]}"#.utf8)).projects
        let sessions = try! JSONDecoder().decode(RACPSessionListResult.self, from: Data(#"{"sessions":[{"id":"S1","title":"Fixture S1 Alpha","projectId":"fixture-online-project","status":"idle","revision":1},{"id":"S2","title":"Fixture S2 Beta","projectId":"fixture-online-project","status":"running","revision":1}]}"#.utf8)).sessions
        let host = HostRecord(
            id: hostID, name: "Fixture Online Host", host: "fixture-online.invalid",
            port: 22, username: "fixture", authKind: .privateKey,
            createdAt: time, isCurrent: true, pairedAt: time
        )
        let state = PersistedState(
            hosts: [host], lastSessionId: "S1", lastProjectId: projectID,
            projectBindings: [StoredProjectBinding(
                hostID: hostID, projectID: projectID, path: "/fixture/online",
                name: "Fixture Workspace", createdAt: time, updatedAt: time
            )],
            sessionBindings: sessions.enumerated().map { index, session in
                StoredSessionBinding(
                    hostID: hostID, sessionID: session.id, projectID: projectID,
                    messageCount: index + 1,
                    lastActivityAt: time.addingTimeInterval(Double(index) * 60),
                    lastKnownRevision: 1, updatedAt: time
                )
            },
            lastSessionByHost: [hostID.uuidString: "S1"],
            lastProjectByHost: [hostID.uuidString: projectID]
        )
        return Self(
            state: state, cache: OfflineSessionCacheSnapshot(),
            catalog: Catalog(
                projects: projects, sessions: sessions,
                info: RACPServerInfo(
                    protocolVersion: "1", serverName: "UI Fixture",
                    serverVersion: "fixture-only", hostId: hostID.uuidString,
                    connectionId: "fixture-connection", roles: []
                )
            )
        )
    }
#endif

    private static func offlineTwoHosts() -> Self {
#if DEBUG
        let hostA = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let hostB = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let originalTime = Date(timeIntervalSince1970: 1_704_164_640)
        var state = PersistedState()
        var cache = OfflineSessionCacheSnapshot()

        for (hostID, suffix) in [(hostA, "A"), (hostB, "B")] {
            let projectID = "fixture-project-\(suffix)"
            let sessionID = "fixture-session-\(suffix)"
            state.hosts.append(HostRecord(
                id: hostID,
                name: "Fixture Host \(suffix)",
                host: "fixture-\(suffix.lowercased()).invalid",
                port: 22,
                username: "fixture",
                authKind: .privateKey,
                createdAt: originalTime,
                isCurrent: hostID == hostB,
                pairedAt: originalTime
            ))
            state.projectBindings.append(StoredProjectBinding(
                hostID: hostID, projectID: projectID, path: "/fixture/\(suffix)",
                name: "Fixture Project \(suffix)",
                createdAt: originalTime, updatedAt: originalTime
            ))
            state.lastProjectByHost[hostID.uuidString] = projectID
            state.lastSessionByHost[hostID.uuidString] = sessionID

            for id in [sessionID, "fixture-shared-session"] {
                let shared = id == "fixture-shared-session"
                let title = "Fixture \(suffix) \(shared ? "shared" : "private") title"
                // The newest cache row intentionally differs from lastSessionByHost.
                let time = originalTime.addingTimeInterval(shared ? 60 : 0)
                state.sessionBindings.append(StoredSessionBinding(
                    hostID: hostID, sessionID: id, projectID: projectID,
                    titleOverride: title, lastActivityAt: time, updatedAt: time
                ))
                cache.entries.append(OfflineSessionCacheEntry(
                    id: "fixture-item", sessionId: id, hostID: hostID,
                    text: "Fixture \(suffix) \(shared ? "shared" : "private") history", createdAt: time
                ))
                cache.cursors.append(OfflineSessionCursor(
                    hostID: hostID, sessionId: id, epoch: "fixture-\(suffix)",
                    sequence: 7, updatedAt: time
                ))
                cache.approvals.append(OfflineSessionApproval(
                    id: "fixture-approval", sessionId: id, hostID: hostID,
                    payload: .object(["summary": .string("Fixture \(suffix) approval")]),
                    revision: 7, status: "pending", decision: nil, createdAt: time
                ))
                cache.drafts.append(OfflineSessionDraft(
                    hostID: hostID, sessionId: id, text: "Fixture \(suffix) unsent draft",
                    idempotencyKey: "fixture-\(suffix)-\(id)", updatedAt: time
                ))
            }
        }
        state.lastSessionId = state.lastSessionByHost[hostB.uuidString]
        state.lastProjectId = state.lastProjectByHost[hostB.uuidString]
        return Self(state: state, cache: cache)
#else
        fatalError("UI test fixtures are unavailable in release builds")
#endif
    }

    private static func offlineCache205() -> Self {
#if DEBUG
        let hostID = UUID(uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")!
        let time = Date(timeIntervalSince1970: 1_704_164_640)
        let projectID = "fixture-cache-project"
        let sessionID = "fixture-cache-session"
        let host = HostRecord(
            id: hostID,
            name: "Fixture Cache Host",
            host: "fixture-cache.invalid",
            port: 22,
            username: "fixture",
            authKind: .privateKey,
            createdAt: time,
            isCurrent: true,
            pairedAt: time
        )
        var state = PersistedState(
            hosts: [host],
            lastSessionId: sessionID,
            lastProjectId: projectID,
            projectBindings: [
                StoredProjectBinding(
                    hostID: hostID,
                    projectID: projectID,
                    path: "/fixture/cache",
                    name: "Fixture Cache Project",
                    createdAt: time,
                    updatedAt: time
                ),
            ],
            sessionBindings: [
                StoredSessionBinding(
                    hostID: hostID,
                    sessionID: sessionID,
                    projectID: projectID,
                    lastActivityAt: time,
                    updatedAt: time
                ),
            ],
            lastSessionByHost: [hostID.uuidString: sessionID],
            lastProjectByHost: [hostID.uuidString: projectID]
        )
        state.offlineCacheLimit = 200
        var cache = OfflineSessionCacheSnapshot()
        cache.entries = (1...205).map { index in
            let number = String(format: "%03d", index)
            return OfflineSessionCacheEntry(
                id: "cache-item-\(number)",
                sessionId: sessionID,
                hostID: hostID,
                text: "Cache item \(number)",
                createdAt: time.addingTimeInterval(Double(index))
            )
        }
        cache.cursors = [
            OfflineSessionCursor(
                hostID: hostID,
                sessionId: sessionID,
                epoch: "fixture-cache",
                sequence: 205,
                updatedAt: time
            ),
        ]
        return Self(state: state, cache: cache)
#else
        fatalError("UI test fixtures are unavailable in release builds")
#endif
    }
}
