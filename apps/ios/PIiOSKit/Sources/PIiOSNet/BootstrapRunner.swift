import Foundation
import PIiOSCore

/// The subset of an SSH transport needed by the bootstrap orchestration.
///
/// `SSHTransport` is intentionally extended in this file without changing it,
/// so the App can pass the exact connection used for both `exec` polling and
/// the pairing callback.
public protocol BootstrapCommandTransport: AnyObject {
    func exec(
        _ command: String,
        stdin: Data?,
        timeout: TimeInterval
    ) async throws -> SSHExecResult
    func close() async
}

extension SSHTransport: BootstrapCommandTransport {}

/// Device credentials returned by the pairing callback. The token remains in
/// memory; callers persist it to Keychain and must never log this value.
public struct BootstrapPairedDevice: Equatable, Sendable {
    public let deviceId: String
    public let deviceToken: String
    public let roles: [String]

    public init(deviceId: String, deviceToken: String, roles: [String]) {
        self.deviceId = deviceId
        self.deviceToken = deviceToken
        self.roles = roles
    }

    public var redactedDescription: String {
        "设备 \(deviceId)（令牌已隐藏）"
    }
}

/// Performs `connection/pair` on the same transport used for bootstrap polling.
///
/// A concrete App adapter can capture its `SSHTransport` and use it to open the
/// `direct-tcpip` channel. Keeping this as an async protocol avoids a second SSH
/// connection and lets tests use a deterministic transport double.
public protocol BootstrapPairingCallback {
    func pair(
        using transport: any BootstrapCommandTransport,
        material: BootstrapPairingMaterial,
        deviceLabel: String?
    ) async throws -> BootstrapPairedDevice
}

/// Reconnects with the newly paired device token and confirms RACP readiness.
public protocol BootstrapDeviceVerificationCallback {
    func verify(
        using transport: any BootstrapCommandTransport,
        port: Int,
        device: BootstrapPairedDevice
    ) async throws -> RACPServerInfo
}

public struct BootstrapRunnerConfiguration: Sendable {
    public var pollInterval: TimeInterval
    /// Excludes user interaction time spent inside pairing/verification callbacks.
    public var overallTimeout: TimeInterval
    public var stallThreshold: TimeInterval
    public var commandTimeout: TimeInterval
    public var pairingCallbackTimeout: TimeInterval
    public var verificationCallbackTimeout: TimeInterval
    /// New PI-adaptor installs must use a token produced by this attempt.
    /// Legacy `ppt1` support exists only for an explicitly selected
    /// compatibility flow and must never be enabled by the default installer.
    public var allowLegacyPPT1: Bool

    public init(
        pollInterval: TimeInterval = 1,
        overallTimeout: TimeInterval = 15 * 60,
        stallThreshold: TimeInterval = BootstrapStallDetector.defaultThreshold,
        commandTimeout: TimeInterval = 30,
        pairingCallbackTimeout: TimeInterval = 2 * 60,
        verificationCallbackTimeout: TimeInterval = 60,
        allowLegacyPPT1: Bool = false
    ) {
        self.pollInterval = max(0.01, pollInterval)
        self.overallTimeout = max(0.01, overallTimeout)
        self.stallThreshold = max(0, stallThreshold)
        self.commandTimeout = max(1, commandTimeout)
        self.pairingCallbackTimeout = max(0.1, pairingCallbackTimeout)
        self.verificationCallbackTimeout = max(0.1, verificationCallbackTimeout)
        self.allowLegacyPPT1 = allowLegacyPPT1
    }
}

public enum BootstrapRunnerEvent: Equatable, Sendable {
    case state(BootstrapStateFile)
    case transitionIssues([BootstrapTransitionIssue])
    case stalled(message: String)
    case pairingStarted
    case pairingCompleted(deviceId: String)
    case verificationStarted
    case verificationCompleted
}

public enum BootstrapCallbackFailure: Equatable, Sendable {
    case pairing
    case verification
}

public struct BootstrapRunSuccess: Equatable, Sendable {
    public let state: BootstrapStateFile
    public let device: BootstrapPairedDevice
    public let port: Int
    public let serverInfo: RACPServerInfo
}

public struct BootstrapRunFailure: Equatable, Sendable {
    public let state: BootstrapStateFile
    public let code: BootstrapFailureCode
    public let callbackFailure: BootstrapCallbackFailure?
    /// A non-secret explanation for a client-side callback failure. This is
    /// deliberately returned separately from `state.error`, whose shape belongs
    /// to the remote script.
    public let detail: String?

    public init(
        state: BootstrapStateFile,
        code: BootstrapFailureCode,
        callbackFailure: BootstrapCallbackFailure? = nil,
        detail: String? = nil
    ) {
        self.state = state
        self.code = code
        self.callbackFailure = callbackFailure
        self.detail = detail
    }
}

public enum BootstrapRunResult: Equatable, Sendable {
    case succeeded(BootstrapRunSuccess)
    case failed(BootstrapRunFailure)
    case unsupported(BootstrapUnsupportedReason)
}

public enum BootstrapRunnerError: Error, Equatable, CustomStringConvertible {
    case malformedProbe
    case architectureMismatch(expected: BootstrapArtifactTarget, actual: BootstrapArtifactTarget)
    case remoteCommandFailed(command: String, exitStatus: Int)
    case malformedState(String)
    case malformedPairingFile
    case timedOut

    public var description: String {
        switch self {
        case .malformedProbe:
            return "服务器平台探测输出不完整"
        case let .architectureMismatch(expected, actual):
            return "发布产物架构 \(expected.rawValue) 与服务器架构 \(actual.rawValue) 不一致"
        case let .remoteCommandFailed(command, exitStatus):
            return "远端安装命令失败（退出码 \(exitStatus)）：\(command)"
        case let .malformedState(detail):
            return "bootstrap 状态文件无法解析：\(detail)"
        case .malformedPairingFile:
            return "配对文件格式不正确"
        case .timedOut:
            return "bootstrap 超过 15 分钟仍未完成"
        }
    }
}

enum BootstrapRuntimeIdentityError: Error, Equatable {
    case nameMismatch(
        expected: String,
        actual: String,
        expectedVersion: String,
        actualVersion: String,
        port: Int,
        unitName: String
    )
    case versionMismatch(
        expected: String,
        actual: String,
        serverName: String,
        port: Int,
        unitName: String
    )

    var displayText: String {
        switch self {
        case let .nameMismatch(
            expected,
            actual,
            expectedVersion,
            actualVersion,
            port,
            unitName
        ):
            return "运行身份不匹配：期望 \(expected) \(expectedVersion)，实际 \(actual) \(actualVersion)；"
                + "服务 \(unitName)，端口 \(port)。"
        case let .versionMismatch(expected, actual, serverName, port, unitName):
            return "运行版本不匹配：\(serverName) 期望 \(expected)，实际 \(actual)；"
                + "服务 \(unitName)，端口 \(port)。"
        }
    }
}

/// Runs the remote bootstrap state machine without owning UI or persistence.
///
/// The caller supplies the same SSH transport for probe, polling, pairing and
/// verification. Secret material appears only in memory and in owner-only
/// remote files; it is never included in events or command strings.
public final class BootstrapRunner {
    public typealias EventHandler = @Sendable (BootstrapRunnerEvent) async -> Void
    public typealias Sleeper = @Sendable (TimeInterval) async throws -> Void
    public typealias NowProvider = @Sendable () -> Date

    private let transport: any BootstrapCommandTransport
    private let pairing: any BootstrapPairingCallback
    private let verifier: any BootstrapDeviceVerificationCallback
    private let configuration: BootstrapRunnerConfiguration
    private let eventHandler: EventHandler?
    private let sleeper: Sleeper
    private let now: NowProvider

    public init(
        transport: any BootstrapCommandTransport,
        pairing: any BootstrapPairingCallback,
        verifier: any BootstrapDeviceVerificationCallback,
        configuration: BootstrapRunnerConfiguration = BootstrapRunnerConfiguration(),
        eventHandler: EventHandler? = nil,
        sleeper: @escaping Sleeper = { seconds in
            let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
            try await Task.sleep(nanoseconds: nanoseconds)
        },
        now: @escaping NowProvider = { Date() }
    ) {
        self.transport = transport
        self.pairing = pairing
        self.verifier = verifier
        self.configuration = configuration
        self.eventHandler = eventHandler
        self.sleeper = sleeper
        self.now = now
    }

    public func run(
        configuration scriptConfiguration: BootstrapScriptConfiguration,
        deviceLabel: String? = nil
    ) async throws -> BootstrapRunResult {
        do {
            let result = try await runOwned(
                configuration: scriptConfiguration,
                deviceLabel: deviceLabel
            )
            await transport.close()
            return result
        } catch {
            await transport.close()
            throw error
        }
    }

    private func runOwned(
        configuration scriptConfiguration: BootstrapScriptConfiguration,
        deviceLabel: String?
    ) async throws -> BootstrapRunResult {
        let probe = try await exec(BootstrapRemoteCommand.probe, stdin: nil)
        let identity = try parseProbe(probe.stdoutText)
        let decision = BootstrapPlatformProbe.decide(
            unameSystem: identity.platform,
            unameMachine: identity.architecture
        )
        guard case let .supported(actualTarget) = decision else {
            if case let .unsupported(reason) = decision {
                return .unsupported(reason)
            }
            throw BootstrapRunnerError.malformedProbe
        }
        guard actualTarget == scriptConfiguration.release.target else {
            throw BootstrapRunnerError.architectureMismatch(
                expected: scriptConfiguration.release.target,
                actual: actualTarget
            )
        }
        guard BootstrapPlatformProbe.target(forUnameMachine: scriptConfiguration.hostArchitecture)
                == actualTarget else {
            throw BootstrapRunnerError.architectureMismatch(
                expected: scriptConfiguration.release.target,
                actual: actualTarget
            )
        }

        let script = BootstrapScriptBuilder.build(scriptConfiguration)
        _ = try await exec(
            BootstrapRemoteCommand.installScript,
            stdin: Data(script.utf8)
        )
        _ = try await exec(BootstrapRemoteCommand.launch, stdin: nil)

        var previousState: BootstrapStateFile?
        var stallDetector = BootstrapStallDetector(threshold: configuration.stallThreshold)
        var announcedStall: String?
        var pairAttempted = false
        var pairingFailure: BootstrapCallbackFailure?
        var callbackFailureDetail: String?
        var verifyAttempted = false
        var pairedDevice: BootstrapPairedDevice?
        var verifiedServerInfo: RACPServerInfo?
        var activeElapsed: TimeInterval = 0
        var activeSegmentStart: Date? = now()

        while true {
            try Task.checkCancellation()

            let stateData = try await exec(BootstrapRemoteCommand.readState, stdin: nil).stdout
            if let state = try decodeState(stateData), state.attemptId == scriptConfiguration.attemptId {
                if state != previousState {
                    let issues = BootstrapStateValidator.issues(previous: previousState, current: state)
                    if !issues.isEmpty {
                        await emit(.transitionIssues(issues))
                    }
                    await emit(.state(state))
                    previousState = state
                }

                switch state.status {
                case .ok:
                    if state.step == .done,
                       let pairedDevice,
                       let verifiedServerInfo {
                        return .succeeded(
                            BootstrapRunSuccess(
                                state: state,
                                device: pairedDevice,
                                port: scriptConfiguration.port,
                                serverInfo: verifiedServerInfo
                            )
                        )
                    }
                case .failed:
                    return .failed(
                        BootstrapRunFailure(
                            state: state,
                            code: state.failureCode ?? .unknown(""),
                                callbackFailure: pairingFailure,
                                detail: callbackFailureDetail
                        )
                    )
                case .running:
                    break
                }

                if !pairAttempted,
                   (state.step == .startPair || state.step == .pair) {
                    if let end = activeSegmentStart {
                        activeElapsed += now().timeIntervalSince(end)
                        activeSegmentStart = nil
                    }
                    let result = try await pair(
                        deviceLabel: deviceLabel,
                        allowLegacyPPT1: configuration.allowLegacyPPT1
                    )
                    switch result {
                    case .notReady:
                        break
                    case let .paired(device):
                        pairAttempted = true
                        pairedDevice = device
                        _ = try await exec(BootstrapRemoteCommand.writePairingOK, stdin: nil)
                        await emit(.pairingCompleted(deviceId: device.deviceId))
                    case let .failed(detail):
                        pairAttempted = true
                        pairingFailure = .pairing
                        callbackFailureDetail = detail
                        _ = try? await exec(BootstrapRemoteCommand.writePairingFailed, stdin: nil)
                    }
                    activeSegmentStart = now()
                }

                if !verifyAttempted,
                   state.step == .verifyDevice,
                   let pairedDevice {
                    verifyAttempted = true
                    if let end = activeSegmentStart {
                        activeElapsed += now().timeIntervalSince(end)
                        activeSegmentStart = nil
                    }
                    await emit(.verificationStarted)
                    do {
                        let serverInfo = try await withTimeout(
                            seconds: configuration.verificationCallbackTimeout
                        ) {
                            try await self.verifier.verify(
                                using: self.transport,
                                port: scriptConfiguration.port,
                                device: pairedDevice
                            )
                        }
                        try Self.validateRuntimeIdentity(
                            serverInfo,
                            expectedName: scriptConfiguration.release.serverName,
                            expectedVersion: scriptConfiguration.release.version,
                            port: scriptConfiguration.port,
                            unitName: scriptConfiguration.release.unitName
                        )
                        verifiedServerInfo = serverInfo
                        _ = try await exec(BootstrapRemoteCommand.writeVerificationOK, stdin: nil)
                        await emit(.verificationCompleted)
                    } catch {
                        pairingFailure = .verification
                        callbackFailureDetail = Self.verificationFailureDetail(
                            error,
                            port: scriptConfiguration.port,
                            unitName: scriptConfiguration.release.unitName
                        )
                        _ = try? await exec(BootstrapRemoteCommand.writeVerificationFailed, stdin: nil)
                    }
                    activeSegmentStart = now()
                }
            }

            if let end = activeSegmentStart {
                let elapsed = activeElapsed + now().timeIntervalSince(end)
                if elapsed >= configuration.overallTimeout {
                    _ = try? await exec(BootstrapRemoteCommand.cancel, stdin: nil)
                    throw BootstrapRunnerError.timedOut
                }
            }

            let observedAt = now()
            // 只在「活动段」内做停滞检测：配对/校验回调期间（activeSegmentStart == nil）
            // 是刻意暂停总超时的等待（用户在核对指纹、输入 sudo、网络慢），
            // 此时不推进属于预期，不应弹「连续 5 分钟没有任何进展」的假恢复提示。
            if let state = previousState, activeSegmentStart != nil {
                switch stallDetector.observe(state.progressSample(at: observedAt)) {
                case .progressing:
                    announcedStall = nil
                case let .stalled(_, message):
                    if announcedStall != message {
                        announcedStall = message
                        await emit(.stalled(message: message))
                    }
                }
            }

            try await sleeper(configuration.pollInterval)
        }
    }

    private enum PairAttempt {
        case notReady
        case paired(BootstrapPairedDevice)
        case failed(String)
    }

    private func pair(
        deviceLabel: String?,
        allowLegacyPPT1: Bool
    ) async throws -> PairAttempt {
        let rawPairing = try await exec(
            BootstrapRemoteCommand.readPairing,
            stdin: nil
        ).stdout
        guard !rawPairing.isEmpty else {
            // The state can be observed immediately before the owner-only file
            // is atomically renamed into place.
            return .notReady
        }
        let material: BootstrapPairingMaterial
        do {
            material = try JSONDecoder().decode(BootstrapPairingMaterial.self, from: rawPairing)
            guard material.token.hasPrefix("ppt2.")
                    || (allowLegacyPPT1 && material.token.hasPrefix("ppt1.")) else {
                return .failed(
                    "本次 PI-adaptor 安装只接受当前进程生成的 ppt2 配对令牌；已拒绝旧 ppt1 令牌。"
                )
            }
            _ = try BootstrapPairingMaterial(
                token: material.token,
                expiresAt: material.expiresAt,
                host: material.host,
                port: material.port,
                allowLegacyPPT1: allowLegacyPPT1
            )
        } catch {
            throw BootstrapRunnerError.malformedPairingFile
        }

        await emit(.pairingStarted)
        do {
            let device = try await withTimeout(
                seconds: configuration.pairingCallbackTimeout
            ) {
                try await self.pairing.pair(
                    using: self.transport,
                    material: material,
                    deviceLabel: deviceLabel
                )
            }
            return .paired(device)
        } catch {
            return .failed("客户端配对失败：\(error.localizedDescription)")
        }
    }

    private static func validateRuntimeIdentity(
        _ info: RACPServerInfo,
        expectedName: String,
        expectedVersion: String,
        port: Int,
        unitName: String
    ) throws {
        if info.serverName != expectedName {
            throw BootstrapRuntimeIdentityError.nameMismatch(
                expected: expectedName,
                actual: info.serverName,
                expectedVersion: expectedVersion,
                actualVersion: info.serverVersion,
                port: port,
                unitName: unitName
            )
        }
        if info.serverVersion != expectedVersion {
            throw BootstrapRuntimeIdentityError.versionMismatch(
                expected: expectedVersion,
                actual: info.serverVersion,
                serverName: info.serverName,
                port: port,
                unitName: unitName
            )
        }
    }

    private static func verificationFailureDetail(
        _ error: Error,
        port: Int,
        unitName: String
    ) -> String {
        if let mismatch = error as? BootstrapRuntimeIdentityError {
            return mismatch.displayText
        }
        return "设备身份与 ping 验证失败；目标 \(unitName)，端口 \(port)。\(error.localizedDescription)"
    }

    private struct ProbeIdentity {
        let platform: String
        let architecture: String
    }

    private func parseProbe(_ stdout: String) throws -> ProbeIdentity {
        var platform: String?
        var architecture: String?
        for line in stdout.components(separatedBy: .newlines) {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            if parts[0] == "platform" { platform = parts[1] }
            if parts[0] == "arch" { architecture = parts[1] }
        }
        guard let platform, let architecture,
              !platform.isEmpty, !architecture.isEmpty else {
            throw BootstrapRunnerError.malformedProbe
        }
        return ProbeIdentity(platform: platform, architecture: architecture)
    }

    private func decodeState(_ data: Data) throws -> BootstrapStateFile? {
        let trimmed = data.drop(while: { $0 == 0x0A || $0 == 0x0D || $0 == 0x20 || $0 == 0x09 })
        guard !trimmed.isEmpty else { return nil }
        do {
            return try JSONDecoder().decode(BootstrapStateFile.self, from: Data(trimmed))
        } catch {
            throw BootstrapRunnerError.malformedState(String(describing: error))
        }
    }

    private func exec(_ command: String, stdin: Data?) async throws -> SSHExecResult {
        let result = try await transport.exec(
            command,
            stdin: stdin,
            timeout: configuration.commandTimeout
        )
        guard result.exitStatus == 0 else {
            throw BootstrapRunnerError.remoteCommandFailed(
                command: command,
                exitStatus: result.exitStatus
            )
        }
        return result
    }

    private func emit(_ event: BootstrapRunnerEvent) async {
        await eventHandler?(event)
    }

    private struct CallbackTimedOut: Error {}

    /// Set-once gate for the resume race. The lock lives behind a synchronous
    /// method so the async task bodies below never call `NSLock` directly from
    /// an async context (a Swift 6 error).
    private final class ResumeGate: @unchecked Sendable {
        private let lock = NSLock()
        private var resumed = false

        /// Returns `true` only to the single caller that wins the race and must resume.
        func claimIfFirst() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if resumed { return false }
            resumed = true
            return true
        }
    }

    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let gate = ResumeGate()
        return try await withCheckedThrowingContinuation { continuation in
            var task: Task<Void, Never>?
            var timer: Task<Void, Never>?

            task = Task {
                do {
                    let value = try await operation()
                    if gate.claimIfFirst() {
                        timer?.cancel()
                        continuation.resume(returning: value)
                    }
                } catch {
                    if gate.claimIfFirst() {
                        timer?.cancel()
                        continuation.resume(throwing: error)
                    }
                }
            }

            let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
            timer = Task {
                try? await Task.sleep(nanoseconds: nanoseconds)
                if gate.claimIfFirst() {
                    task?.cancel()
                    continuation.resume(throwing: CallbackTimedOut())
                }
            }
        }
    }
}
