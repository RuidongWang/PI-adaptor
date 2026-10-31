import Foundation
import UIKit
import PIiOSCore
import PIiOSNet

typealias HostUnitSnapshot = PIiOSCore.HostUnitSnapshot

enum ConnectionPairingError: LocalizedError {
    case missingCredential
    case missingHostPort
    case invalidToken
    case keychainWriteFailed

    var errorDescription: String? {
        switch self {
        case .missingCredential:
            return "本机没有这台服务器的凭证：请先在服务器页保存并测试连接"
        case .missingHostPort:
            return "未填写 pi-host 端口，无法建立配对隧道"
        case .invalidToken:
            return "配对令牌格式不正确：应以 ppt1. 或 ppt2. 开头，且不能包含空白字符"
        case .keychainWriteFailed:
            return "配对成功，但设备令牌未能写入 Keychain；请检查应用签名后重试"
        }
    }
}

enum ConnectionLifecycleError: LocalizedError {
    case connectionChanged

    var errorDescription: String? {
        "连接已切换或断开，请在新连接上重试"
    }
}

enum HostUnitProbeError: LocalizedError {
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let detail):
            return detail.isEmpty ? "无法读取 Host systemd 状态" : detail
        }
    }
}

enum HostInstallError: LocalizedError {
    case invalidReleaseVersion
    case probeFailed(String)
    case malformedProbe
    case emptySudoPassword
    case sudoFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidReleaseVersion:
            return "内置的 pi-host Release 版本或仓库配置不合法"
        case .probeFailed(let detail):
            return detail.isEmpty ? "无法探测服务器平台" : detail
        case .malformedProbe:
            return "服务器平台探测输出不完整"
        case .emptySudoPassword:
            return "请输入 sudo 密码；空密码不会发送到服务器"
        case .sudoFailed(let detail):
            return detail.isEmpty ? "sudo 授权失败，pi-host unit 未启动" : detail
        }
    }
}

struct HostInstallRunOutcome: Sendable {
    let result: BootstrapRunResult
    let releaseVersion: String
    let attemptId: String
}

/// 指纹核对页的数据（S-04「核对指纹」状态）。
struct HostKeyPrompt: Identifiable, Equatable {
    let id = UUID()
    var operationID: UUID
    var account: String
    var address: String
    var key: SSHHostKey
    var status: HostKeyTrustStatus
}

/// 隧道 + RACP 的连接状态容器。界面只读这里的状态，不自行推断「在线」。
@MainActor
final class ConnectionModel: ObservableObject {
    static let deviceRevokedMessage = "服务器已撤销该设备的访问权限"

    nonisolated static let defaultHostInstallReleaseVersion = PiHostRelease.patchedReleaseVersion
    nonisolated static let defaultHostInstallReleaseBaseURL =
        ProcessInfo.processInfo.environment["PI_IOS_HOST_RELEASE_BASE_URL"]
            ?? PiHostRelease.defaultPatchedBaseURL

    @Published private(set) var state: RACPTunnelState = .offline(reason: nil)
    @Published private(set) var projects: [RACPProjectSummary] = []
    @Published private(set) var sessions: [RACPSessionSummary] = []
    @Published private(set) var info: RACPServerInfo?
    @Published private(set) var lastError: String?
    /// Invoked when the loopback pi-host port is discovered over SSH so the owner
    /// (AppModel) can persist it onto the host record.
    var onResolvedHostPort: ((UUID, Int) -> Void)?
    @Published private(set) var hasLoadedCatalog = false
    @Published private(set) var isRefreshingCatalog = false
    @Published private(set) var catalogError: String?
    /// 「保存并测试连接」的结果文案；nil 表示没有测过。
    @Published private(set) var testResult: String?
    @Published private(set) var isTesting = false
    @Published var hostKeyPrompt: HostKeyPrompt?

    private var client: RACPClient?
    var activeClient: RACPClient? { client }
    private var updateTask: Task<Void, Never>?
    private var hostCatalogRefreshTask: Task<Void, Never>?
    private var hostCatalogRefreshToken: UUID?
    private var hostCatalogRefreshPending = false
    private var brokers: [UUID: HostKeyPromptBroker] = [:]
    private var connectionBrokerID: UUID?
    private var connectedAccount: String?
    private var connectionGeneration = 0
    private var connectionIntentGeneration = 0
    private var catalogGeneration = 0
    private(set) var cacheHostID: UUID?
    private var offlineCacheLimit = PersistedState.defaultOfflineCacheLimit
    private var cacheStore: SessionCacheStore
    /// 每次真实 RACP client 建立时更新；缓存迟到写入据此拒绝旧连接结果。
    private var cacheClientID = UUID()
    private struct PendingDraftWrite {
        let lease: OfflineSessionCacheWriteLease
        let sessionID: String
        let text: String
        let idempotencyKey: String?
    }
    private var pendingDraftWrite: PendingDraftWrite?
    private var draftWriteTask: Task<Void, Never>?
    private var sessionCacheWriteTask: Task<Void, Never>?
    private var sessionCacheWritePending = false
    private var cacheFlushTask: Task<Void, Never>?
    private var cacheFlushGeneration = 0
    var currentCatalogHostID: UUID? { cacheHostID }
    /// 会话内的读写（发送、审批、排队、配置）全部走它。
    let session: SessionController
    private let usesUITestFixture: Bool
    private var fixtureProviderBindingStatuses: [String: ProviderBindingStatus] = [:]
    private var fixtureHostUnitSnapshot: HostUnitSnapshot?
    private var fixtureCatalogs: [UUID: UITestFixture.Catalog] = [:]
    private var fixtureConnectionState: RACPTunnelState?

    init(fixture: UITestFixture? = nil) {
        usesUITestFixture = fixture != nil
        if let fixture {
            fixtureProviderBindingStatuses = fixture.providerBindingStatuses
            fixtureHostUnitSnapshot = fixture.hostUnitSnapshot
            fixtureCatalogs = fixture.catalogs
            fixtureConnectionState = fixture.connectionState
            cacheStore = SessionCacheStore(
                offlineCacheLimit: PersistedState.defaultOfflineCacheLimit,
                inMemory: fixture.cache
            )
            session = SessionController(requestKeys: SessionRequestKeyStore(fileURL: nil))
#if DEBUG
            session.configureUITestSnapshots(fixture.sessionSnapshots)
#endif
            if let catalog = fixture.catalog {
                projects = catalog.projects
                sessions = catalog.sessions
                info = catalog.info
                hasLoadedCatalog = true
                state = .online
            }
            if let fixtureConnectionState {
                state = fixtureConnectionState
            }
        } else {
            cacheStore = SessionCacheStore(offlineCacheLimit: PersistedState.defaultOfflineCacheLimit)
            session = SessionController()
        }
        session.onDraftChanged = { [weak self] sessionID, text, idempotencyKey in
            self?.scheduleDraftCache(
                sessionID: sessionID,
                text: text,
                idempotencyKey: idempotencyKey
            )
        }
        session.onSessionWillChange = { [weak self] in
            await self?.flushPendingCacheWrites()
        }
#if DEBUG
        session.configureUITestInterruption(enabled: fixture?.supportsFixtureInterrupt == true)
#endif
    }

    /// 设置里的「离线缓存上限」变化时同步给缓存层（AC-15.1）。
    func updateOfflineCacheLimit(_ limit: Int) {
        offlineCacheLimit = limit
        cacheStore = cacheStore.withOfflineCacheLimit(limit)
    }

    func setCacheHostID(_ hostID: UUID?) {
        cacheHostID = hostID
        if let hostID, let catalog = fixtureCatalogs[hostID] {
            applyFixtureCatalog(catalog)
        }
    }

    var cacheItemLimit: Int { cacheStore.itemLimit }

    // MARK: - 测试连接（SSH）

    /// 「保存并测试连接」：走真实的 SSH 握手 + 认证 + 一次 `exec`，返回可展示的结果。
    ///
    /// 不做假成功：任何一步失败都返回错误原文；指纹首次出现时会挂起等用户核对（AC-02.1）。
    func testConnection(record: HostRecord, credential: SSHCredential) async -> String {
        isTesting = true
        defer { isTesting = false }
        let account = KeychainStore.account(username: record.username, host: record.host, port: record.port)
        let pinned = KeychainStore.loadHostKey(account: account)
        let (operationID, promptBroker) = makeHostKeyBroker(
            account: account,
            address: record.address
        )
        defer { releaseHostKeyBroker(operationID) }

        let request = SSHConnectionRequest(
            host: record.host,
            port: record.port,
            username: record.username,
            credential: credential,
            pinnedHostKey: pinned
        )
        do {
            let transport = try await SSHTransport.connect(request, confirmer: promptBroker)
            let result = try await transport.exec("true", timeout: 15)
            await transport.close()
            let fingerprint = transport.presentedHostKey?.fingerprint ?? pinned?.fingerprint ?? "未知"
            let message: String
            if result.exitStatus == 0 {
                message = "SSH 连接成功，主机指纹 \(fingerprint)"
            } else {
                message = "SSH 已连接，但远端命令返回退出码 \(result.exitStatus)："
                    + ConnectionDiagnosticRedactor.redact(result.stderrText)
            }
            testResult = message
            return message
        } catch {
            let message = ConnectionErrorText.describe(error)
            testResult = message
            return message
        }
    }

    // MARK: - pi-host 配对

    /// 使用服务器 `pi-host --pair` 输出的一次性令牌完成 RACP 配对。
    ///
    /// `pairOnce` 只交换设备凭证并立即断开；调用方随后必须用已保存的设备令牌重新建连。
    func pair(record: HostRecord, credential: SSHCredential, pairingToken: String) async throws {
        guard let token = RACPPairingToken.normalize(pairingToken) else {
            throw ConnectionPairingError.invalidToken
        }
        await disconnect()

        let account = KeychainStore.account(username: record.username, host: record.host, port: record.port)
        let pinned = KeychainStore.loadHostKey(account: account)
        guard let hostPort = await resolveHostPort(
            record: record,
            credential: credential,
            account: account,
            pinned: pinned
        ) else {
            throw ConnectionPairingError.missingHostPort
        }
        let (operationID, promptBroker) = makeHostKeyBroker(
            account: account,
            address: record.address
        )
        defer { releaseHostKeyBroker(operationID) }

        let client = RACPClient(
            configuration: RACPConfiguration(
                ssh: SSHConnectionRequest(
                    host: record.host,
                    port: record.port,
                    username: record.username,
                    credential: credential,
                    pinnedHostKey: pinned
                ),
                hostPort: hostPort,
                deviceToken: token
            ),
            confirmer: promptBroker
        )
        let result = try await client.pairOnce(deviceLabel: UIDevice.current.name)
        guard KeychainStore.savePairing(
            deviceId: result.deviceId,
            deviceToken: result.deviceToken,
            hostID: record.id
        ) else {
            throw ConnectionPairingError.keychainWriteFailed
        }
    }

    // MARK: - pi-host 安装

    /// Runs the real remote bootstrap state machine over one SSH transport.
    ///
    /// The same transport is passed to the pairing and device-verification
    /// adapters. This is an isolated/test-injected operation; callers must not
    /// invoke it against a production Host without explicit user action.
    func installHost(
        record: HostRecord,
        port: Int,
        releaseVersion: String = ConnectionModel.defaultHostInstallReleaseVersion,
        /// 强制重装：忽略服务器上的 `.release.sha256` 复用判定，重新下载并激活。
        force: Bool = false,
        eventHandler: BootstrapRunner.EventHandler? = nil
    ) async throws -> HostInstallRunOutcome {
        guard (1...65_535).contains(port) else {
            throw BootstrapScriptError.invalidPort
        }
        let account = KeychainStore.account(
            username: record.username,
            host: record.host,
            port: record.port
        )
        guard let credential = KeychainStore.loadCredential(account: account) else {
            throw ConnectionPairingError.missingCredential
        }

        let connection = try await connectSSH(
            record: record,
            credential: credential,
            account: account
        )
        let transport = connection.transport
        defer { releaseHostKeyBroker(connection.operationID) }

        let probe: SSHExecResult
        do {
            probe = try await transport.exec(
                BootstrapRemoteCommand.probe,
                timeout: 15
            )
        } catch {
            await transport.close()
            throw error
        }
        guard probe.exitStatus == 0 else {
            await transport.close()
            throw HostInstallError.probeFailed(probe.stderrText)
        }
        let identity = try parseBootstrapProbe(probe.stdoutText)
        let decision = BootstrapPlatformProbe.decide(
            unameSystem: identity.platform,
            unameMachine: identity.architecture
        )
        guard case let .supported(target) = decision else {
            await transport.close()
            if case let .unsupported(reason) = decision {
                return HostInstallRunOutcome(
                    result: .unsupported(reason),
                    releaseVersion: releaseVersion,
                    attemptId: ""
                )
            }
            throw HostInstallError.malformedProbe
        }
        let release = releaseVersion == PiHostRelease.patchedReleaseVersion
            ? PiHostRelease.patched(
                target: target,
                baseURL: ConnectionModel.defaultHostInstallReleaseBaseURL
            )
            : PiHostRelease(version: releaseVersion, target: target)
        guard let release else {
            await transport.close()
            throw HostInstallError.invalidReleaseVersion
        }

        let attemptId = "ios-\(UUID().uuidString.lowercased())"
        let scriptConfiguration = try BootstrapScriptConfiguration(
            release: release,
            attemptId: attemptId,
            hostArchitecture: identity.architecture,
            port: port,
            force: force
        )
        let pairingAdapter = BootstrapInstallPairingAdapter(persist: { device in
            guard KeychainStore.savePairing(
                deviceId: device.deviceId,
                deviceToken: device.deviceToken,
                hostID: record.id
            ) else {
                throw BootstrapInstallAdapterError.persistenceFailed
            }
        })
        let verificationAdapter = BootstrapInstallVerificationAdapter()
        let runner = BootstrapRunner(
            transport: transport,
            pairing: pairingAdapter,
            verifier: verificationAdapter,
            eventHandler: eventHandler
        )
        let result = try await runner.run(
            configuration: scriptConfiguration,
            deviceLabel: UIDevice.current.name
        )
        return HostInstallRunOutcome(
            result: result,
            releaseVersion: release.version,
            attemptId: attemptId
        )
    }

    /// Reads the owner-only bootstrap log through a fresh SSH `exec`. The
    /// remote launcher never writes the pairing FIFO/token to this file.
    func hostInstallLog(record: HostRecord) async throws -> String {
        let account = KeychainStore.account(
            username: record.username,
            host: record.host,
            port: record.port
        )
        guard let credential = KeychainStore.loadCredential(account: account) else {
            throw ConnectionPairingError.missingCredential
        }
        let connection = try await connectSSH(
            record: record,
            credential: credential,
            account: account
        )
        defer { releaseHostKeyBroker(connection.operationID) }
        do {
            let result = try await connection.transport.exec(
                BootstrapInstallDiagnostics.logCommand,
                timeout: 20
            )
            await connection.transport.close()
            guard result.exitStatus == 0 else {
                throw HostUnitProbeError.commandFailed(result.stderrText)
            }
            let text = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "服务器上还没有 bootstrap 日志。" : text
        } catch {
            await connection.transport.close()
            throw error
        }
    }

    /// Grants the one privilege required by the user-unit installation path:
    /// `loginctl enable-linger`. The password goes over SSH stdin only.
    func authorizeHostInstall(record: HostRecord, sudoPassword: String) async throws {
        guard !sudoPassword.isEmpty else { throw HostInstallError.emptySudoPassword }
        let account = KeychainStore.account(
            username: record.username,
            host: record.host,
            port: record.port
        )
        guard let credential = KeychainStore.loadCredential(account: account) else {
            throw ConnectionPairingError.missingCredential
        }
        let connection = try await connectSSH(
            record: record,
            credential: credential,
            account: account
        )
        defer { releaseHostKeyBroker(connection.operationID) }
        do {
            let result = try await connection.transport.exec(
                BootstrapInstallDiagnostics.enableLingerCommand,
                stdin: Data((sudoPassword + "\n").utf8),
                timeout: 20
            )
            await connection.transport.close()
            guard result.exitStatus == 0 else {
                throw HostInstallError.sudoFailed(result.stderrText)
            }
        } catch {
            await connection.transport.close()
            throw error
        }
    }

    private func parseBootstrapProbe(
        _ output: String
    ) throws -> (platform: String, architecture: String) {
        var platform: String?
        var architecture: String?
        for line in output.components(separatedBy: .newlines) {
            let fields = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard fields.count == 2 else { continue }
            if fields[0] == "platform" { platform = fields[1] }
            if fields[0] == "arch" { architecture = fields[1] }
        }
        guard let platform, let architecture,
              !platform.isEmpty, !architecture.isEmpty else {
            throw HostInstallError.malformedProbe
        }
        return (platform, architecture)
    }

    // MARK: - 模型服务

    /// Probe the provider's `/models` endpoint from the SSH host. The API key is
    /// sent over SSH stdin and never enters a command line, URL, or log.
    func discoverModels(
        record: HostRecord,
        baseURL: String,
        apiKey: String
    ) async throws -> [DiscoveredModel] {
        let deadline = Date().addingTimeInterval(RemoteProviderOperations.userVisibleTimeout)
        let account = KeychainStore.account(username: record.username, host: record.host, port: record.port)
        guard let credential = KeychainStore.loadCredential(account: account) else {
            throw ConnectionPairingError.missingCredential
        }
        let url = try ModelListParser.modelsURL(baseURL: baseURL)
        let connection = try await connectSSH(
            record: record,
            credential: credential,
            account: account,
            timeout: remainingProviderBudget(deadline)
        )
        let transport = connection.transport
        defer { releaseHostKeyBroker(connection.operationID) }
        do {
            let models = try await RemoteProviderOperations.discoverModels(
                transport: transport,
                requestURL: url,
                apiKey: apiKey,
                timeout: remainingProviderBudget(deadline)
            )
            await transport.close()
            return models
        } catch {
            await transport.close()
            throw error
        }
    }

    func importProvider(
        record: HostRecord,
        payload: Data
    ) async throws -> ProviderImportReceipt {
        let deadline = Date().addingTimeInterval(RemoteProviderOperations.userVisibleTimeout)
        let account = KeychainStore.account(username: record.username, host: record.host, port: record.port)
        guard let credential = KeychainStore.loadCredential(account: account) else {
            throw ConnectionPairingError.missingCredential
        }
        let connection = try await connectSSH(
            record: record,
            credential: credential,
            account: account,
            timeout: remainingProviderBudget(deadline)
        )
        let transport = connection.transport
        defer { releaseHostKeyBroker(connection.operationID) }
        do {
            let receipt = try await RemoteProviderOperations.importProviders(
                transport: transport,
                payload: payload,
                timeout: remainingProviderBudget(deadline)
            )
            await transport.close()
            return receipt
        } catch {
            await transport.close()
            throw error
        }
    }

    func removeProvider(
        record: HostRecord,
        providerId: String
    ) async throws -> ProviderRemoveReceipt {
        let deadline = Date().addingTimeInterval(RemoteProviderOperations.userVisibleTimeout)
        let account = KeychainStore.account(username: record.username, host: record.host, port: record.port)
        guard let credential = KeychainStore.loadCredential(account: account) else {
            throw ConnectionPairingError.missingCredential
        }
        let connection = try await connectSSH(
            record: record,
            credential: credential,
            account: account,
            timeout: remainingProviderBudget(deadline)
        )
        let transport = connection.transport
        defer { releaseHostKeyBroker(connection.operationID) }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let payload = try encoder.encode(ProviderRemovePayload(providerId: providerId))
            let receipt = try await RemoteProviderOperations.removeProvider(
                transport: transport,
                payload: payload,
                timeout: remainingProviderBudget(deadline)
            )
            await transport.close()
            return receipt
        } catch {
            await transport.close()
            throw error
        }
    }

    func providerBindingStatus(
        record: HostRecord,
        sessionId: String
    ) async throws -> ProviderBindingReceipt {
        if usesUITestFixture {
            guard let status = fixtureProviderBindingStatuses[sessionId] else {
                return .unparseable(reason: "UI fixture 未提供该会话的 provider 绑定")
            }
            return .success(status)
        }
        let deadline = Date().addingTimeInterval(RemoteProviderOperations.userVisibleTimeout)
        let account = KeychainStore.account(username: record.username, host: record.host, port: record.port)
        guard let credential = KeychainStore.loadCredential(account: account) else {
            throw ConnectionPairingError.missingCredential
        }
        let connection = try await connectSSH(
            record: record,
            credential: credential,
            account: account,
            timeout: remainingProviderBudget(deadline)
        )
        let transport = connection.transport
        defer { releaseHostKeyBroker(connection.operationID) }
        do {
            let receipt = try await RemoteProviderOperations.bindingStatus(
                transport: transport,
                sessionId: sessionId,
                timeout: remainingProviderBudget(deadline)
            )
            await transport.close()
            return receipt
        } catch {
            await transport.close()
            throw error
        }
    }

    // MARK: - Host v2 additive features

    private struct HostV2SkillList: Decodable {
        var skills: [RACPV2Skill]
    }

    private struct HostV2SkillEnvelope: Decodable {
        var skill: RACPV2Skill
    }

    private struct HostV2DeleteEnvelope: Decodable {
        var deleted: Bool
    }

    private struct HostV2ProviderList: Decodable {
        var providers: [RACPV2Provider]
    }

    private struct HostV2ProviderEnvelope: Decodable {
        var provider: RACPV2Provider
    }

    private struct HostV2SessionGet: Decodable {
        struct Session: Decodable {
            var providerId: String?
            var modelId: String?
            var thinkingLevel: String?
        }
        var session: Session
    }

    /// v2 equivalent of the legacy SSL `provider-binding-status` probe: read the
    /// session's pinned provider/model, then verify it against the Host store.
    func hostV2BindingStatus(sessionId: String) async throws -> ProviderBindingStatus {
        guard let client, state.isOnline else { throw RACPV2Error.notConnected }
        let observedAt = ISO8601DateFormatter().string(from: Date())
        func status(
            providerId: String?,
            modelId: String?,
            available: Bool?,
            reason: String?,
            effective: Bool
        ) -> ProviderBindingStatus {
            ProviderBindingStatus(
                sessionId: sessionId,
                pinnedProviderId: providerId,
                pinnedModelId: modelId,
                pinnedThinkingLevel: nil,
                effectiveProviderId: effective ? providerId : nil,
                effectiveModelId: effective ? modelId : nil,
                available: available,
                unavailableReason: reason,
                unknownInputs: [],
                observedAt: observedAt
            )
        }
        let result: HostV2SessionGet = try await client.v2Request(
            method: RACPV2Method.sessionGet.rawValue,
            params: .object(["sessionId": .string(sessionId)])
        )
        let providerId = result.session.providerId
        let modelId = result.session.modelId
        guard let providerId, !providerId.isEmpty, let modelId, !modelId.isEmpty else {
            return status(providerId: providerId, modelId: modelId, available: false, reason: "no_candidate", effective: false)
        }
        let providers = try await listHostProviders()
        guard let provider = providers.first(where: { $0.id == providerId }) else {
            return status(providerId: providerId, modelId: modelId, available: false, reason: "provider_missing", effective: false)
        }
        guard provider.models.contains(where: { $0.id == modelId }) else {
            return status(providerId: providerId, modelId: modelId, available: false, reason: "model_removed", effective: false)
        }
        if provider.authKind != "none", !provider.hasApiKey {
            return status(providerId: providerId, modelId: modelId, available: false, reason: "secret_missing", effective: false)
        }
        return status(providerId: providerId, modelId: modelId, available: true, reason: nil, effective: true)
    }

    func listHostSkills() async throws -> [RACPV2Skill] {
        guard let client, state.isOnline else {
            throw RACPV2Error.notConnected
        }
        let result: HostV2SkillList = try await client.v2Request(
            method: RACPV2Method.skillList.rawValue,
            params: .object([:])
        )
        return result.skills
    }

    func installHostSkill(source: JSONValue, replace: Bool = false) async throws -> RACPV2Skill {
        guard let client, state.isOnline else {
            throw RACPV2Error.notConnected
        }
        let result: HostV2SkillEnvelope = try await client.v2Request(
            method: RACPV2Method.skillInstall.rawValue,
            params: .object([
                "source": source,
                "replace": .bool(replace),
                "context": .object([
                    "requestId": .string("req_\(UUID().uuidString)"),
                    "idempotencyKey": .string("skill_install_\(UUID().uuidString)")
                ])
            ])
        )
        return result.skill
    }

    func deleteHostSkill(id: String) async throws {
        guard let client, state.isOnline else {
            throw RACPV2Error.notConnected
        }
        let _: HostV2DeleteEnvelope = try await client.v2Request(
            method: RACPV2Method.skillDelete.rawValue,
            params: .object([
                "skillId": .string(id),
                "confirmSkillId": .string(id),
                "context": .object([
                    "requestId": .string("req_\(UUID().uuidString)"),
                    "idempotencyKey": .string("skill_delete_\(UUID().uuidString)")
                ])
            ])
        )
    }

    func listHostProviders() async throws -> [RACPV2Provider] {
        guard let client, state.isOnline else {
            throw RACPV2Error.notConnected
        }
        let result: HostV2ProviderList = try await client.v2Request(
            method: RACPV2Method.providerList.rawValue,
            params: .object([:])
        )
        return result.providers
    }

    func createHostProvider(
        name: String,
        baseURL: String,
        apiKey: String,
        modelID: String
    ) async throws -> RACPV2Provider {
        guard let client, state.isOnline else {
            throw RACPV2Error.notConnected
        }
        let model: JSONValue = .object([
            "id": .string(modelID),
            "displayName": .string(modelID),
            "contextWindow": .number(128000),
            "maxTokens": .number(16384),
            "thinkingLevels": .array([]),
            "defaultThinkingLevel": .null,
            "supportsImages": .bool(false)
        ])
        let result: HostV2ProviderEnvelope = try await client.v2Request(
            method: RACPV2Method.providerCreate.rawValue,
            params: .object([
                "provider": .object([
                    "name": .string(name),
                    "vendorKey": .string("v2-\(UUID().uuidString)"),
                    "type": .string("openai_compatible"),
                    "protocol": .string("openai_completions"),
                    "baseUrl": .string(baseURL),
                    "authKind": .string("api_key"),
                    "apiKey": .string(apiKey),
                    "models": .array([model])
                ]),
                "context": .object([
                    "requestId": .string("req_\(UUID().uuidString)"),
                    "idempotencyKey": .string("provider_create_\(UUID().uuidString)")
                ])
            ])
        )
        return result.provider
    }

    /// Mirror a provider (with its full model list and API key) into the v2 Host
    /// provider store.
    ///
    /// The v2 Host resolves a session's provider/model only from its own store
    /// (`provider/list`). Providers imported over the legacy SSH path live in a
    /// different store, so a session bound to them can never run. Mirroring keeps
    /// both stores in sync and returns the Host-side id to record locally.
    func registerHostProvider(
        name: String,
        vendorKey: String,
        baseURL: String,
        apiKey: String,
        models: [ProviderModelSpec]
    ) async throws -> RACPV2Provider {
        guard let client, state.isOnline else {
            throw RACPV2Error.notConnected
        }
        guard !models.isEmpty else {
            throw RACPV2Error.protocolViolation("provider has no models")
        }
        let modelValues: [JSONValue] = models.map { spec in
            .object([
                "id": .string(spec.id),
                "displayName": .string(spec.alias ?? spec.id),
                "contextWindow": .number(Double(spec.contextWindow)),
                "maxTokens": .number(Double(spec.maxTokens)),
                "thinkingLevels": .array(spec.thinkingLevels.map { .string($0) }),
                "defaultThinkingLevel": spec.defaultThinkingLevel.map { .string($0) } ?? .null,
                "supportsImages": .bool(spec.supportsImages ?? false)
            ])
        }
        let result: HostV2ProviderEnvelope = try await client.v2Request(
            method: RACPV2Method.providerCreate.rawValue,
            params: .object([
                "provider": .object([
                    "name": .string(name),
                    "vendorKey": .string(vendorKey),
                    "type": .string("openai_compatible"),
                    "protocol": .string("openai_completions"),
                    "baseUrl": .string(baseURL),
                    "authKind": .string("api_key"),
                    "apiKey": .string(apiKey),
                    "models": .array(modelValues)
                ]),
                "context": .object([
                    "requestId": .string("req_\(UUID().uuidString)"),
                    "idempotencyKey": .string("provider_create_\(UUID().uuidString)")
                ])
            ])
        )
        return result.provider
    }

    /// Encode one provider model for the v2 wire. Defaults only apply when the
    /// Host-side provider has no models yet; otherwise callers pass the existing
    /// values through unchanged so nothing is silently overwritten.
    private static func providerModelJSON(
        id: String,
        displayName: String? = nil,
        contextWindow: Int = 128_000,
        maxTokens: Int = 16_384,
        thinkingLevels: [String] = [],
        defaultThinkingLevel: String? = nil,
        supportsImages: Bool = false
    ) -> JSONValue {
        .object([
            "id": .string(id),
            "displayName": .string(displayName ?? id),
            "contextWindow": .number(Double(contextWindow)),
            "maxTokens": .number(Double(maxTokens)),
            "thinkingLevels": .array(thinkingLevels.map { .string($0) }),
            "defaultThinkingLevel": defaultThinkingLevel.map { .string($0) } ?? .null,
            "supportsImages": .bool(supportsImages)
        ])
    }

    func updateHostProvider(
        id: String,
        name: String,
        baseURL: String,
        apiKey: String?,
        modelID: String
    ) async throws -> RACPV2Provider {
        guard let client, state.isOnline else {
            throw RACPV2Error.notConnected
        }
        // Load the provider as it currently exists on the Host and change only the
        // fields this form actually owns. Sending a synthesised single-model
        // payload would silently drop every other model and overwrite capability
        // fields (context window, output limit, thinking levels, image support)
        // that the form never displayed.
        guard let existing = try await listHostProviders().first(where: { $0.id == id }) else {
            throw RACPV2Error.protocolViolation("provider no longer exists on the Host")
        }
        let models: [JSONValue]
        if existing.models.isEmpty {
            models = [Self.providerModelJSON(id: modelID)]
        } else {
            models = existing.models.enumerated().map { index, model in
                // The form edits the primary (first) model id only.
                let editsPrimary = index == 0 && !modelID.isEmpty && model.id != modelID
                return Self.providerModelJSON(
                    id: editsPrimary ? modelID : model.id,
                    displayName: editsPrimary ? modelID : model.displayName,
                    contextWindow: model.contextWindow,
                    maxTokens: model.maxTokens,
                    thinkingLevels: model.thinkingLevels,
                    defaultThinkingLevel: model.defaultThinkingLevel,
                    supportsImages: model.supportsImages
                )
            }
        }
        var providerFields: [String: JSONValue] = [
            "name": .string(name),
            "vendorKey": .string(existing.vendorKey),
            "type": .string(existing.type),
            "protocol": .string(existing.protocolName),
            "baseUrl": .string(baseURL),
            // Omitting apiKey keeps the stored secret; the provider stays api_key.
            "authKind": .string(existing.authKind),
            "models": .array(models)
        ]
        if let apiKey, !apiKey.isEmpty {
            providerFields["apiKey"] = .string(apiKey)
            providerFields["authKind"] = .string("api_key")
        }
        let result: HostV2ProviderEnvelope = try await client.v2Request(
            method: RACPV2Method.providerUpdate.rawValue,
            params: .object([
                "providerId": .string(id),
                "provider": .object(providerFields),
                "context": .object([
                    "requestId": .string("req_\(UUID().uuidString)"),
                    "idempotencyKey": .string("provider_update_\(UUID().uuidString)")
                ])
            ])
        )
        return result.provider
    }

    func deleteHostProvider(id: String) async throws {
        guard let client, state.isOnline else {
            throw RACPV2Error.notConnected
        }
        let _: HostV2DeleteEnvelope = try await client.v2Request(
            method: RACPV2Method.providerDelete.rawValue,
            params: .object([
                "providerId": .string(id),
                "confirmProviderId": .string(id),
                "context": .object([
                    "requestId": .string("req_\(UUID().uuidString)"),
                    "idempotencyKey": .string("provider_delete_\(UUID().uuidString)")
                ])
            ])
        )
    }

    func hostUnitSnapshot(record: HostRecord) async throws -> HostUnitSnapshot {
        if usesUITestFixture {
            guard let fixtureHostUnitSnapshot else {
                throw HostUnitParseError.missingField("fixture HostUnitSnapshot")
            }
            return fixtureHostUnitSnapshot
        }
        let account = KeychainStore.account(username: record.username, host: record.host, port: record.port)
        guard let credential = KeychainStore.loadCredential(account: account) else {
            throw ConnectionPairingError.missingCredential
        }
        let connection = try await connectSSH(
            record: record,
            credential: credential,
            account: account
        )
        defer { releaseHostKeyBroker(connection.operationID) }
        let result: SSHExecResult
        do {
            result = try await connection.transport.exec(
                "systemctl --user show pi-host.service --property=LoadState,ActiveState,UnitFileState",
                timeout: 15
            )
        } catch {
            await connection.transport.close()
            throw error
        }
        await connection.transport.close()
        guard result.exitStatus == 0 else {
            throw HostUnitProbeError.commandFailed(result.stderrText)
        }
        do {
            return try HostUnitSnapshotParser.parse(result.stdoutText)
        } catch {
            throw RACPClientError.malformedFrame(error.localizedDescription)
        }
    }

    private func makeHostKeyBroker(
        account: String,
        address: String
    ) -> (UUID, HostKeyPromptBroker) {
        for broker in brokers.values {
            broker.cancel()
        }
        hostKeyPrompt = nil
        let operationID = UUID()
        let broker = HostKeyPromptBroker(
            operationID: operationID,
            account: account,
            address: address,
            onPrompt: { [weak self] prompt in
                Task { @MainActor in
                    guard let self,
                          self.brokers[operationID]?.isCancelled == false
                    else { return }
                    self.hostKeyPrompt = prompt
                }
            }
        )
        brokers[operationID] = broker
        return (operationID, broker)
    }

    /// Resolve the loopback RACP port to tunnel to.
    ///
    /// Requirement: the user must not configure a host port. Prefer a recorded
    /// value, otherwise discover it over SSH (see `HostPortResolver`). Returns
    /// nil when the value cannot be determined so the caller reports an explicit
    /// offline reason rather than silently tunneling to a guessed port — a guess
    /// could reach a different Host sharing the machine.
    private func resolveHostPort(
        record: HostRecord,
        credential: SSHCredential,
        account: String,
        pinned: SSHHostKey?
    ) async -> Int? {
        if let port = record.hostPort, (1...65_535).contains(port) {
            return port
        }
        let (operationID, promptBroker) = makeHostKeyBroker(account: account, address: record.address)
        defer { releaseHostKeyBroker(operationID) }
        do {
            let transport = try await SSHTransport.connect(
                SSHConnectionRequest(
                    host: record.host,
                    port: record.port,
                    username: record.username,
                    credential: credential,
                    pinnedHostKey: pinned
                ),
                confirmer: promptBroker,
                timeout: 15
            )
            let result = try await transport.exec(HostPortResolver.probeCommand, timeout: 15)
            await transport.close()
            if let port = HostPortResolver.resolve(stdout: result.stdoutText) {
                onResolvedHostPort?(record.id, port)
                return port
            }
        } catch {
            return nil
        }
        return nil
    }

    private func releaseHostKeyBroker(_ operationID: UUID) {
        brokers.removeValue(forKey: operationID)
        if connectionBrokerID == operationID {
            connectionBrokerID = nil
        }
        if hostKeyPrompt?.operationID == operationID {
            hostKeyPrompt = nil
        }
    }

    private func connectSSH(
        record: HostRecord,
        credential: SSHCredential,
        account: String,
        timeout: TimeInterval = 20
    ) async throws -> (transport: SSHTransport, operationID: UUID) {
        let pinned = KeychainStore.loadHostKey(account: account)
        let (operationID, promptBroker) = makeHostKeyBroker(
            account: account,
            address: record.address
        )
        do {
            let transport = try await SSHTransport.connect(
                SSHConnectionRequest(
                    host: record.host,
                    port: record.port,
                    username: record.username,
                    credential: credential,
                    pinnedHostKey: pinned
                ),
                confirmer: promptBroker,
                timeout: timeout
            )
            return (transport, operationID)
        } catch {
            releaseHostKeyBroker(operationID)
            throw error
        }
    }

    private func remainingProviderBudget(_ deadline: Date) -> TimeInterval {
        max(0.1, deadline.timeIntervalSinceNow)
    }

    private func applyFixtureCatalog(_ catalog: UITestFixture.Catalog?) {
        guard let catalog else { return }
        projects = catalog.projects
        sessions = catalog.sessions
        info = catalog.info
        hasLoadedCatalog = true
        catalogError = nil
        state = fixtureConnectionState ?? .online
    }

    // MARK: - RACP 隧道

    /// 建立隧道并拉取 `project/list` / `session/list`。
    ///
    /// 前提是 Keychain 里已有凭证与设备令牌；缺任何一项都直接给出原因，不假装在线。
    func connect(record: HostRecord) async {
        connectionIntentGeneration &+= 1
        let intent = connectionIntentGeneration
        await disconnectCurrent(expectedIntent: intent)
        guard intent == connectionIntentGeneration,
              cacheHostID == record.id
        else { return }
        if usesUITestFixture {
            applyFixtureCatalog(fixtureCatalogs[record.id])
            return
        }
        guard record.pairedAt != nil else {
            state = .offline(reason: "本机记录尚未配对：请先完成 pi-host 配对")
            return
        }
        let account = KeychainStore.account(username: record.username, host: record.host, port: record.port)
        guard let credential = KeychainStore.loadCredential(account: account) else {
            state = .offline(reason: "本机没有保存这台服务器的凭证：请先在服务器页「保存并测试连接」")
            return
        }
        guard let token = KeychainStore.loadDeviceToken(hostID: record.id) else {
            state = .offline(reason: "本机没有设备令牌：请到服务器页用一次性令牌完成配对")
            return
        }
        let pinned = KeychainStore.loadHostKey(account: account)
        guard let hostPort = await resolveHostPort(
            record: record,
            credential: credential,
            account: account,
            pinned: pinned
        ) else {
            state = .offline(reason: "无法确定 pi-host 端口：SSH 探测失败且未记录端口")
            return
        }
        // `resolveHostPort` 是一次跨 await 的端口探测：期间用户可能已切到另一台
        // Host。安装 client 前必须重新核对连接意图与 Host 身份，否则 A 的迟到结果
        // 会取代 B，使界面上的当前 Host 与实际连接错位。
        guard intent == connectionIntentGeneration, cacheHostID == record.id else { return }
        let (operationID, promptBroker) = makeHostKeyBroker(
            account: account,
            address: record.address
        )
        connectionBrokerID = operationID
        connectedAccount = account
        let configuration = RACPConfiguration(
            ssh: SSHConnectionRequest(
                host: record.host,
                port: record.port,
                username: record.username,
                credential: credential,
                pinnedHostKey: pinned
            ),
            hostPort: hostPort,
            deviceToken: token
        )
        let newClient = RACPClient(configuration: configuration, confirmer: promptBroker)
        client = newClient
        connectionGeneration &+= 1
        cacheClientID = UUID()
        let generation = connectionGeneration
        invalidateCatalogLoads()
        session.bind(client: newClient, online: false)
        let stream = await newClient.start()
        guard self.client === newClient, connectionGeneration == generation else {
            releaseHostKeyBroker(operationID)
            await newClient.stop()
            return
        }
        updateTask = Task { [weak self] in
            for await update in stream {
                await self?.apply(update, client: newClient, generation: generation)
            }
        }
    }

    func disconnect() async {
        connectionIntentGeneration &+= 1
        await disconnectCurrent(expectedIntent: connectionIntentGeneration)
    }

    /// Only close the connection if the Host that requested teardown is still active.
    /// A stale Host action must never disconnect the connection installed by a newer switch.
    func disconnect(ifHostID expectedHostID: UUID) async {
        guard cacheHostID == expectedHostID else { return }
        connectionIntentGeneration &+= 1
        await disconnectCurrent(
            expectedIntent: connectionIntentGeneration,
            expectedHostID: expectedHostID
        )
    }

    private func disconnectCurrent(
        expectedIntent: Int,
        expectedHostID: UUID? = nil
    ) async {
        let generation = connectionGeneration
        await flushPendingCacheWrites()
        guard expectedIntent == connectionIntentGeneration,
              connectionGeneration == generation,
              expectedHostID == nil || cacheHostID == expectedHostID
        else { return }
        connectionGeneration &+= 1
        cacheClientID = UUID()
        invalidateCatalogLoads()
        cancelHostCatalogRefresh()
        updateTask?.cancel()
        updateTask = nil
        let oldClient = client
        client = nil
        for broker in brokers.values {
            broker.cancel()
        }
        hostKeyPrompt = nil
        if let connectionBrokerID {
            brokers.removeValue(forKey: connectionBrokerID)
        }
        connectionBrokerID = nil
        session.bind(client: nil, online: false)
        connectedAccount = nil
        projects = []
        sessions = []
        info = nil
        hasLoadedCatalog = false
        catalogError = nil
        state = .offline(reason: nil)
        if let oldClient {
            await oldClient.stop()
        }
    }

    func waitUntilOnline(timeout: TimeInterval = 30) async -> Bool {
        if usesUITestFixture { return state.isOnline }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeout))
        while clock.now < deadline {
            guard !Task.isCancelled else { return false }
            if state.isOnline { return true }
            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                return false
            }
        }
        return state.isOnline
    }

    /// 重新拉取项目与会话列表（只在在线时可用）。
    @discardableResult
    func refreshRemote(timeout: TimeInterval = 30) async -> Bool {
        guard let client else { return false }
        let connection = connectionGeneration
        catalogGeneration &+= 1
        let generation = catalogGeneration
        isRefreshingCatalog = true
        defer {
            if catalogGeneration == generation {
                isRefreshingCatalog = false
            }
        }
        do {
            // Split the caller's total budget across the two sequential catalog calls.
            let perRequestTimeout = max(0.1, timeout / 2)
            let remoteProjects = try await client.listProjects(timeout: perRequestTimeout)
            let remoteSessions = try await client.listSessions(timeout: perRequestTimeout)
            guard self.client === client,
                  connectionGeneration == connection,
                  catalogGeneration == generation
            else { return false }
            projects = remoteProjects
            sessions = remoteSessions
            hasLoadedCatalog = true
            catalogError = nil
            lastError = nil
            // 权威目录已完整到达：把缓存里权威列表已不存在的会话清掉，否则另一台
            // 设备删除会话后，本机刷新时虽不再显示，随后离线又会从缓存里把它翻出来。
            reconcileOfflineCache(with: remoteSessions)
            return true
        } catch {
            guard self.client === client,
                  connectionGeneration == connection,
                  catalogGeneration == generation
            else { return false }
            let message = ConnectionErrorText.describe(error)
            catalogError = message
            lastError = ConnectionErrorText.describe(error)
            return false
        }
    }

    /// `project/browse`：逐级浏览服务器目录（AC-08.4）。
    func browseProject(path: String?) async throws -> RACPProjectBrowseResult {
        guard let client, state.isOnline else { throw RACPClientError.notConnected }
        let connection = connectionGeneration
        let result = try await client.browseProject(path: path)
        guard self.client === client, connectionGeneration == connection else {
            throw ConnectionLifecycleError.connectionChanged
        }
        return result
    }

    /// `project/register`：把服务器目录注册为项目（AC-08.4）。
    func registerProject(path: String) async throws -> RACPProjectSummary {
        guard let client, state.isOnline else { throw RACPClientError.notConnected }
        invalidateCatalogLoads()
        let connection = connectionGeneration
        let project = try await client.registerProject(path: path)
        guard self.client === client, connectionGeneration == connection else {
            throw ConnectionLifecycleError.connectionChanged
        }
        // 注册回执本身已足以更新项目页；随后 refreshRemote 只负责补齐其他项。
        projects = ProjectCatalogRules.upsert(project, in: projects)
        return project
    }

    private func invalidateCatalogLoads() {
        catalogGeneration &+= 1
        isRefreshingCatalog = false
    }

    /// `session/create`：在项目中新建会话（AC-08.2）。
    func createSession(title: String?, projectId: String?) async throws -> RACPSessionSummary {
        guard let client, state.isOnline else { throw RACPClientError.notConnected }
        let connection = connectionGeneration
        let created = try await client.createSession(
            title: title,
            projectId: projectId,
            permissionMode: nil
        )
        guard self.client === client, connectionGeneration == connection else {
            throw ConnectionLifecycleError.connectionChanged
        }
        return created
    }

    func respondHostKey(_ confirmation: HostKeyConfirmation, operationID: UUID) {
        guard let prompt = hostKeyPrompt,
              prompt.operationID == operationID,
              let broker = brokers[prompt.operationID]
        else { return }
        if confirmation == .trust, prompt.status == .firstUse {
            // 首次固定：写 Keychain 并记一条本地审计事件（AC-02.3 的固定动作）。
            _ = KeychainStore.saveHostKey(prompt.key, account: prompt.account)
            HostKeyAuditLog.append(
                HostKeyAuditEvent(
                    kind: .pinned,
                    hostAddress: prompt.address,
                    fingerprint: prompt.key.fingerprint
                )
            )
        }
        hostKeyPrompt = nil
        broker.respond(confirmation)
    }

    /// AC-02.3 的两步操作第一步：显式移除旧指纹（第二步是重新连接并确认新指纹）。
    func removeHostKeyPin(account: String, address: String, previousFingerprint: String?) {
        KeychainStore.deleteHostKey(account: account)
        HostKeyAuditLog.append(
            HostKeyAuditEvent(
                kind: .pinRemoved,
                hostAddress: address,
                fingerprint: previousFingerprint ?? "",
                previousFingerprint: previousFingerprint
            )
        )
    }

    // MARK: - 更新流

    private func apply(
        _ update: RACPClientUpdate,
        client: RACPClient,
        generation: Int
    ) async {
        guard self.client === client, connectionGeneration == generation else { return }
        switch update {
        case .state(let newState):
            let sanitizedState = Self.sanitizedForDisplay(newState)
            state = sanitizedState
            session.setOnline(sanitizedState.isOnline)
            if sanitizedState.isOnline {
                await refreshRemote()
                await session.refreshView()
                scheduleCacheSessionState()
            } else {
                cancelHostCatalogRefresh()
            }
        case .ready(let serverInfo):
            info = serverInfo
        case .hostChanged:
            scheduleHostCatalogRefresh(client: client, generation: generation)
        case .sessionChanged:
            await session.refreshView()
            scheduleCacheSessionState()
        case .event:
            break
        case .error(let code, _):
            lastError = ConnectionFailureClassifier.userMessage(forRACPCode: code)
        }
    }

    private static func sanitizedForDisplay(_ state: RACPTunnelState) -> RACPTunnelState {
        switch state {
        case .offline(let reason):
            return .offline(reason: reason.map {
                ConnectionFailureClassifier.classify(message: $0).userMessage
            })
        case .reconnecting(let attempt, let delay, let reason):
            return .reconnecting(
                attempt: attempt,
                delay: delay,
                reason: ConnectionFailureClassifier.classify(message: reason).userMessage
            )
        default:
            return state
        }
    }

    /// Host 事件可能一帧一个，但目录只需要每个短窗口刷新一次；刷新期间继续到达的
    /// 变更会合并成下一批，避免 N 个会话 revision 触发 N 次 `project/list` + `session/list`。
    private func scheduleHostCatalogRefresh(client: RACPClient, generation: Int) {
        guard self.client === client, connectionGeneration == generation else { return }
        hostCatalogRefreshPending = true
        guard hostCatalogRefreshTask == nil else { return }

        let token = UUID()
        hostCatalogRefreshToken = token
        hostCatalogRefreshTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  self.hostCatalogRefreshToken == token,
                  self.client === client,
                  self.connectionGeneration == generation
            else { return }

            while self.hostCatalogRefreshPending {
                self.hostCatalogRefreshPending = false
                await self.refreshRemote()

                guard self.hostCatalogRefreshToken == token,
                      self.client === client,
                      self.connectionGeneration == generation,
                      self.hostCatalogRefreshPending
                else { break }
                do {
                    try await Task.sleep(for: .milliseconds(200))
                } catch {
                    break
                }
            }

            guard self.hostCatalogRefreshToken == token else { return }
            self.hostCatalogRefreshTask = nil
            self.hostCatalogRefreshToken = nil
            self.hostCatalogRefreshPending = false
        }
    }

    private func cancelHostCatalogRefresh() {
        hostCatalogRefreshTask?.cancel()
        hostCatalogRefreshTask = nil
        hostCatalogRefreshToken = nil
        hostCatalogRefreshPending = false
    }

    // MARK: - 撤销本机配对（AC-03.1）

    /// 用 `connection/pair` 保存下来的 `deviceId` 调 `session/revoke`。
    ///
    /// 只有服务器确认 `revoked == true` 才算撤销成功；离线、缺设备 ID、服务器拒绝都要如实报告，
    /// 不能因为「本机已删掉凭证」就当成服务器侧已撤销。
    func revokeThisDevice(host: HostRecord) async -> String {
        guard cacheHostID == host.id else {
            return "目标服务器不是当前连接：未发送撤销请求"
        }
        let account = KeychainStore.account(username: host.username, host: host.host, port: host.port)
        guard let deviceId = KeychainStore.loadDeviceId(hostID: host.id) else {
            return "本机没有保存的 deviceId：无法向服务器撤销，只清除了本地凭证"
        }
        guard let client, state.isOnline else {
            return "隧道未连接：改动只在服务器确认后才生效，请先连接再撤销"
        }
        do {
            let revoked = try await client.revokeDevice(deviceId: deviceId)
            return revoked
                ? Self.deviceRevokedMessage
                : "服务器返回未撤销（设备可能早已被撤销）"
        } catch {
            return "撤销失败：\(ConnectionErrorText.describe(error))"
        }
    }

    // MARK: - 离线缓存读取（AC-15.1）

    /// 该会话在缓存里的条目（新→旧）。离线时用它显示历史，并标注「可能不是最新」。
    func cachedEntries(sessionId: String) -> [SessionCacheStore.Entry] {
        cachedSession(sessionId: sessionId)?.entries ?? []
    }

    /// 会话的完整只读缓存：items、cursor、审批卡与草稿。
    func cachedSession(sessionId: String) -> OfflineCachedSession? {
        cacheStore.loadSnapshot().cachedSession(hostID: cacheHostID, sessionID: sessionId)
    }

    /// 缓存里出现过的会话 id（新→旧），离线时可以据此进入只读历史。
    func cachedSessionIds() -> [String] {
        cacheStore.loadSnapshot().sessionIDs(hostID: cacheHostID)
    }

    /// Drop cached sessions the authoritative catalog no longer lists for the
    /// active host. Only call with a freshly fetched, complete list — a partial
    /// or filtered list would purge sessions that still exist.
    private func reconcileOfflineCache(with remoteSessions: [RACPSessionSummary]) {
        guard let hostID = cacheHostID else { return }
        let authoritative = Set(remoteSessions.map(\.id))
        let stale = cacheStore.loadSnapshot()
            .sessionIDs(hostID: hostID)
            .filter { !authoritative.contains($0) }
        removeCachedSessions(stale)
    }

    func removeCachedSessions(_ sessionIDs: [String]) {
        guard !sessionIDs.isEmpty else { return }
        let removed = Set(sessionIDs)
        guard let hostID = cacheHostID else { return }
        var snapshot = cacheStore.loadSnapshot()
        for sessionID in removed {
            snapshot.removeSessionAndDraft(hostID: hostID, sessionID: sessionID)
        }
        cacheStore.save(snapshot)
    }

    func removeCachedHost(_ hostID: UUID) {
        cacheStore.removeHost(hostID)
    }

    /// 把权威会话快照写进离线缓存：items、cursor、pending approvals 一起替换；
    /// 草稿由输入框的 change sink 独立维护。异步读取前后都校验租约，旧连接结果不能落盘。
    private func cacheSessionState() async {
        guard let client,
              let hostID = cacheHostID,
              let sessionID = session.attachedSessionId
        else { return }
        let generation = connectionGeneration
        let clientID = cacheClientID
        let lease = OfflineSessionCacheWriteLease(
            clientID: clientID,
            connectionGeneration: generation,
            hostID: hostID,
            sessionID: sessionID
        )
        let view = await client.sessionView()
        guard self.client === client,
              connectionGeneration == generation,
              cacheClientID == clientID,
              isCurrentCacheWrite(lease),
              view.sessionId == sessionID
        else { return }

        let now = Date()
        let existingSnapshot = cacheStore.loadSnapshot()
        let existingSession = existingSnapshot.cachedSession(
            hostID: hostID,
            sessionID: sessionID
        )
        // 视图是权威快照（`hasMoreHistory == false` 表示它已包含完整历史）时，
        // 不能用「缓存旧条目 ∪ 新视图」合并：快照重建后已从权威状态消失的条目
        // 会被旧缓存重新带回来。只有在分页未取完（可能还有更老的历史）时才保留
        // 合并语义。
        let existingEntries = view.hasMoreHistory ? (existingSession?.entries ?? []) : []
        let existingDates = Dictionary(
            existingEntries.map { ($0.id, $0.createdAt) },
            uniquingKeysWith: { max($0, $1) }
        )
        var entriesWithOriginalDate: [(entry: SessionCacheStore.Entry, hasOriginalDate: Bool)] = []
        for item in view.items {
            let originalDate = Self.cacheCreatedAt(from: item)
            let entry = SessionCacheStore.Entry(
                id: item.id,
                sessionId: sessionID,
                hostID: hostID,
                text: item.text ?? "",
                createdAt: originalDate ?? existingDates[item.id] ?? now,
                kind: item.kind,
                role: item.role,
                toolName: item.toolName,
                status: item.status,
                epoch: view.cursor?.epoch,
                sequence: item.payload.value(at: ["sequence"])?.intValue
                    ?? view.cursor?.sequence
            )
            entriesWithOriginalDate.append((entry, originalDate != nil))
        }
        let entries = OfflineSessionCachePolicy.merged(
            existingEntries,
            with: entriesWithOriginalDate.map(\.entry)
        )
        let keysWithOriginalDates = Set(
            entriesWithOriginalDate
                .filter { $0.hasOriginalDate }
                .map {
                    OfflineSessionCachePolicy.itemKey(
                        hostID: hostID,
                        sessionID: sessionID,
                        itemID: $0.entry.id
                    )
                }
        )
        // 旧版本曾把“缓存写入时间”当消息时间；一旦服务端给出原始时间，必须用原时间替换它，
        // 不能被 merge 的“较新时间优先”规则挡住。
        let retained = entries.filter {
            let key = OfflineSessionCachePolicy.itemKey(
                hostID: $0.hostID,
                sessionID: $0.sessionId,
                itemID: $0.id
            )
            return !keysWithOriginalDates.contains(key)
        }
        let newEntries = OfflineSessionCachePolicy.merged(
            retained,
            with: entriesWithOriginalDate.map(\.entry)
        )

        var next = existingSnapshot
        if let draft = existingSession?.draft {
            next.removeSession(hostID: hostID, sessionID: sessionID)
            next.drafts.removeAll {
                $0.hostID == hostID && $0.sessionId == sessionID
            }
            next.drafts.append(draft)
        } else {
            next.removeSession(hostID: hostID, sessionID: sessionID)
        }
        next.entries.append(contentsOf: newEntries)
        if let summary = session.attachedSummary {
            next.sessions.append(
                SessionCacheStore.Session(
                    hostID: hostID,
                    id: sessionID,
                    title: summary.title,
                    projectID: summary.projectId,
                    mode: session.sessionMode.rawValue,
                    permissionMode: session.permissionMode.rawValue,
                    modelID: session.selectedModelId,
                    providerID: session.selectedProviderId,
                    epoch: view.cursor?.epoch,
                    sequence: view.cursor?.sequence,
                    updatedAt: now
                )
            )
        }
        if let cursor = view.cursor {
            next.cursors.append(
                SessionCacheStore.Cursor(
                    hostID: hostID,
                    sessionId: sessionID,
                    epoch: cursor.epoch,
                    sequence: cursor.sequence,
                    updatedAt: now
                )
            )
        }
        next.approvals.append(contentsOf: view.pendingApprovals.map { card in
            SessionCacheStore.Approval(
                id: card.id,
                sessionId: sessionID,
                hostID: hostID,
                payload: CacheFieldPolicy.redactedForCache(card.payload),
                revision: card.revision,
                status: card.status ?? "pending",
                decision: card.payload.value(at: ["decision"])?.stringValue,
                createdAt: Self.cacheCreatedAt(from: card.payload) ?? now
            )
        })

        guard isCurrentCacheWrite(lease) else { return }
        cacheStore.save(next)
    }

    /// Coalesce streaming/history and keystroke cache writes so disk I/O is not
    /// performed on every event or character.
    private func scheduleCacheSessionState() {
        sessionCacheWritePending = true
        guard sessionCacheWriteTask == nil else { return }
        sessionCacheWriteTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            guard let self else { return }
            self.sessionCacheWritePending = false
            await self.cacheSessionState()
            guard !Task.isCancelled else { return }
            self.sessionCacheWriteTask = nil
            if self.sessionCacheWritePending {
                self.scheduleCacheSessionState()
            }
        }
    }

    private func scheduleDraftCache(
        sessionID: String,
        text: String,
        idempotencyKey: String?
    ) {
        guard let lease = currentCacheWriteLease(sessionID: sessionID),
              isCurrentDraftWrite(lease)
        else { return }
        pendingDraftWrite = PendingDraftWrite(
            lease: lease,
            sessionID: sessionID,
            text: text,
            idempotencyKey: idempotencyKey
        )
        guard draftWriteTask == nil else { return }
        draftWriteTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            guard let self else { return }
            self.flushPendingDraftWrite()
            self.draftWriteTask = nil
        }
    }

    private func flushPendingDraftWrite() {
        guard let pending = pendingDraftWrite else { return }
        pendingDraftWrite = nil
        guard isCurrentDraftWrite(pending.lease) else { return }
        var snapshot = cacheStore.loadSnapshot()
        snapshot.drafts.removeAll {
            $0.hostID == pending.lease.hostID && $0.sessionId == pending.sessionID
        }
        if !pending.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let idempotencyKey = pending.idempotencyKey else { return }
            snapshot.drafts.append(
                SessionCacheStore.Draft(
                    hostID: pending.lease.hostID,
                    sessionId: pending.sessionID,
                    text: pending.text,
                    idempotencyKey: idempotencyKey,
                    updatedAt: Date()
                )
            )
        }
        cacheStore.save(snapshot)
    }

    /// Flush both coalesced caches before backgrounding, disconnecting, or switching sessions.
    func flushPendingCacheWrites() async {
        cacheFlushGeneration &+= 1
        let generation = cacheFlushGeneration
        let previous = cacheFlushTask
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            await self.performCacheFlush()
        }
        cacheFlushTask = task
        await task.value
        if cacheFlushGeneration == generation {
            cacheFlushTask = nil
        }
    }

    private func performCacheFlush() async {
        draftWriteTask?.cancel()
        draftWriteTask = nil
        flushPendingDraftWrite()

        let hadPendingSessionWrite = sessionCacheWriteTask != nil || sessionCacheWritePending
        sessionCacheWriteTask?.cancel()
        sessionCacheWriteTask = nil
        sessionCacheWritePending = false
        if hadPendingSessionWrite {
            await cacheSessionState()
        }
    }

    private func currentCacheWriteLease(
        sessionID: String
    ) -> OfflineSessionCacheWriteLease? {
        guard client != nil, let hostID = cacheHostID else { return nil }
        return OfflineSessionCacheWriteLease(
            clientID: cacheClientID,
            connectionGeneration: connectionGeneration,
            hostID: hostID,
            sessionID: sessionID
        )
    }

    private func isCurrentCacheWrite(_ lease: OfflineSessionCacheWriteLease) -> Bool {
        client != nil
            && lease.isCurrent(
                clientID: cacheClientID,
                connectionGeneration: connectionGeneration,
                hostID: cacheHostID,
                sessionID: session.attachedSessionId
            )
    }

    private func isCurrentDraftWrite(_ lease: OfflineSessionCacheWriteLease) -> Bool {
        client != nil
            && lease.isCurrentHost(
                clientID: cacheClientID,
                connectionGeneration: connectionGeneration,
                hostID: cacheHostID
            )
    }

    private static func cacheCreatedAt(from item: RACPItem) -> Date? {
        cacheCreatedAt(from: item.payload)
    }

    private static func cacheCreatedAt(from payload: JSONValue) -> Date? {
        for key in ["createdAt", "created_at"] {
            guard let value = payload.value(at: [key]) else { continue }
            switch value {
            case .number(let raw):
                return dateFromEpoch(raw)
            case .string(let raw):
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if let epoch = Double(trimmed), let date = dateFromEpoch(epoch) {
                    return date
                }
                let fractional = ISO8601DateFormatter()
                fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = fractional.date(from: trimmed) { return date }
                return ISO8601DateFormatter().date(from: trimmed)
            default:
                continue
            }
        }
        return nil
    }

    private static func dateFromEpoch(_ raw: Double) -> Date? {
        guard raw.isFinite, raw > 0 else { return nil }
        // 同时接受秒与毫秒时间戳；1e11 秒在现实中不会出现。
        let seconds = raw >= 100_000_000_000 ? raw / 1_000 : raw
        return Date(timeIntervalSince1970: seconds)
    }
}

// MARK: - 指纹核对的挂起点

/// 把手握期间的主机指纹判定转成「等界面回答」的 async 调用（AC-02.1）。
///
/// `matches` 不打扰用户；`firstUse` / `changed` 都要界面参与，`changed` 只允许拒绝（AC-02.2）。
final class HostKeyPromptBroker: HostKeyConfirming, @unchecked Sendable {
    private let lock = NSLock()
    private let operationID: UUID
    private let account: String
    private let address: String
    private let onPrompt: @Sendable (HostKeyPrompt) -> Void
    private var pending: CheckedContinuation<HostKeyConfirmation, Never>?
    private var cancelled = false

    init(
        operationID: UUID,
        account: String,
        address: String,
        onPrompt: @escaping @Sendable (HostKeyPrompt) -> Void
    ) {
        self.operationID = operationID
        self.account = account
        self.address = address
        self.onPrompt = onPrompt
    }

    func confirmHostKey(_ key: SSHHostKey, status: HostKeyTrustStatus) async -> HostKeyConfirmation {
        lock.lock()
        let isCancelled = cancelled
        lock.unlock()
        if isCancelled { return .reject }
        if status == .matches {
            return .trust
        }
        if case .changed = status {
            // AC-02.2：指纹变化一律拒绝，不提供「一键忽略」。
            return .reject
        }
        return await withCheckedContinuation { continuation in
            lock.lock()
            if cancelled {
                lock.unlock()
                continuation.resume(returning: .reject)
                return
            }
            pending = continuation
            lock.unlock()
            onPrompt(
                HostKeyPrompt(
                    operationID: operationID,
                    account: account,
                    address: address,
                    key: key,
                    status: status
                )
            )
        }
    }

    func respond(_ confirmation: HostKeyConfirmation) {
        lock.lock()
        let continuation = pending
        pending = nil
        lock.unlock()
        continuation?.resume(returning: confirmation)
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let continuation = pending
        pending = nil
        lock.unlock()
        continuation?.resume(returning: .reject)
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

/// 错误 → 用户可读文案（不含任何凭证内容，AC-G2）。
enum ConnectionErrorText {
    static func describe(_ error: Error) -> String {
        if let error = error as? SSHTransportError {
            return describeSSH(error)
        }
        if let error = error as? SSHPrivateKeyError {
            return "凭据无法使用：" + ConnectionDiagnosticRedactor.redact(error.description)
        }
        if let error = error as? RACPClientError {
            return describeRACP(error)
        }
        if let error = error as? RACPWebSocketError {
            return describeWebSocket(error)
        }
        return ConnectionDiagnosticRedactor.redact(error.localizedDescription)
    }

    private static func describeSSH(_ error: SSHTransportError) -> String {
        let kind: ConnectionFailureKind
        switch error {
        case .invalidPrivateKey:
            return "认证失败（401）："
                + ConnectionDiagnosticRedactor.redact(error.description)
        case .hostKeyUnreadable, .hostKeyRejected, .hostKeyAlgorithmUnsupported:
            kind = .hostKey
        case .authenticationFailed:
            kind = .authentication
        case .timedOut:
            kind = .timeout
        case .channelClosed, .closedByPeer:
            kind = .offline
        case .tunnelRefused:
            kind = .remoteUnavailable
        case .networkFailure(_, let detail):
            kind = ConnectionFailureClassifier.classify(
                code: "ssh.networkFailure",
                message: detail
            )
        }
        return kind.userMessage
    }

    private static func describeRACP(_ error: RACPClientError) -> String {
        switch error {
        case .notConnected:
            return ConnectionFailureKind.offline.userMessage
        case .protocolMismatch, .malformedFrame:
            return ConnectionFailureKind.protocolViolation.userMessage
        case .timedOut:
            return ConnectionFailureKind.timeout.userMessage
        case .server(let code, _):
            return ConnectionFailureClassifier.userMessage(forRACPCode: code)
        }
    }

    private static func describeWebSocket(_ error: RACPWebSocketError) -> String {
        switch error {
        case .upgradeRejected(let status):
            return ConnectionFailureClassifier.classify(
                code: "websocket.upgradeRejected",
                httpStatus: status
            ).userMessage
        case .protocolViolation:
            return ConnectionFailureKind.protocolViolation.userMessage
        case .closed:
            return ConnectionFailureKind.offline.userMessage
        }
    }
}

/// 主机指纹审计日志（AC-02.3）：只记指纹与时间，不含任何凭证。
enum HostKeyAuditLog {
    private static let fileURL: URL? = SessionCacheStore.defaultURL()?
        .deletingLastPathComponent()
        .appendingPathComponent("hostkey-audit-v1.json")

    static func append(_ event: HostKeyAuditEvent) {
        guard let fileURL else { return }
        var events: [HostKeyAuditEvent] = []
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([HostKeyAuditEvent].self, from: data) {
            events = decoded
        }
        events.append(event)
        if let data = try? JSONEncoder().encode(events.suffix(200).map { $0 }) {
            try? data.write(to: fileURL, options: [.atomic])
        }
    }
}
