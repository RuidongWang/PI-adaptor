import Foundation
import XCTest

@testable import PIiOSCore
@testable import PIiOSNet

final class BootstrapRunnerTests: XCTestCase {
    private let token = "ppt2." + "runner_pairing_token"
    private let issuedToken = "pdt2." + "runner_device_token"

    private func configuration(
        attemptId: String = "boot_test"
    ) throws -> BootstrapScriptConfiguration {
        let release = try XCTUnwrap(
            PiHostRelease(version: "0.21.0", target: .linuxArm64)
        )
        return try BootstrapScriptConfiguration(
            release: release,
            attemptId: attemptId,
            hostArchitecture: "arm64",
            port: 43_871,
            readyTimeoutSeconds: 30,
            pairTimeoutSeconds: 60,
            stopTimeoutSeconds: 10,
            verifyTimeoutSeconds: 30
        )
    }

    private func state(
        _ step: BootstrapStep,
        status: BootstrapStatus = .running,
        attemptId: String = "boot_test",
        downloadedBytes: Int = 0,
        error: JSONValue? = nil
    ) throws -> SSHExecResult {
        let value = BootstrapStateFile(
            attemptId: attemptId,
            step: step,
            status: status,
            host: BootstrapHostInfo(platform: "linux", arch: "arm64"),
            artifact: BootstrapArtifactInfo(
                name: "pi-adaptor-0.21.0-linux-arm64.tar.gz",
                sha256: String(repeating: "a", count: 64),
                bytes: 100,
                downloadedBytes: downloadedBytes
            ),
            service: BootstrapServiceInfo(
                unitPath: "/home/ubuntu/.config/systemd/user/pi-adaptor.service",
                state: step == .done ? "active" : "absent"
            ),
            error: error,
            updatedAt: "2026-10-29T12:00:00Z"
        )
        return SSHExecResult(
            exitStatus: 0,
            stdout: try JSONEncoder().encode(value),
            stderr: Data()
        )
    }

    private func pairingResult(token: String? = nil) -> SSHExecResult {
        let selectedToken = token ?? self.token
        let json = #"{"token":"\#(selectedToken)","expiresAt":1234,"host":"127.0.0.1","port":43871}"#
        return SSHExecResult(exitStatus: 0, stdout: Data(json.utf8), stderr: Data())
    }

    private func success() -> SSHExecResult {
        SSHExecResult(exitStatus: 0, stdout: Data(), stderr: Data())
    }

    private func recordedTransport(_ value: any BootstrapCommandTransport) -> ObjectIdentifier {
        ObjectIdentifier(value as AnyObject)
    }

    func testHappyPathUsesOneTransportForPollingPairingAndVerification() async throws {
        let transport = MockBootstrapTransport(
            responses: [
                BootstrapRemoteCommand.probe: [
                    SSHExecResult(exitStatus: 0, stdout: Data("platform=Linux\narch=aarch64\n".utf8), stderr: Data()),
                ],
                BootstrapRemoteCommand.installScript: [success()],
                BootstrapRemoteCommand.launch: [success()],
                BootstrapRemoteCommand.readState: [
                    try state(.startPair),
                    try state(.stopManual),
                    try state(.startUnit),
                    try state(.verifyDevice),
                    try state(.done, status: .ok),
                ],
                BootstrapRemoteCommand.readPairing: [pairingResult()],
                BootstrapRemoteCommand.writePairingOK: [success()],
                BootstrapRemoteCommand.writeVerificationOK: [success()],
            ]
        )
        let pairing = RecordingPairer(
            result: BootstrapPairedDevice(
                deviceId: "dev_1",
                deviceToken: issuedToken,
                roles: ["owner"]
            )
        )
        let verifier = RecordingVerifier()
        let recorder = EventRecorder()
        let runner = BootstrapRunner(
            transport: transport,
            pairing: pairing,
            verifier: verifier,
            configuration: BootstrapRunnerConfiguration(
                pollInterval: 0.001,
                overallTimeout: 10,
                stallThreshold: 300,
                commandTimeout: 2
            ),
            eventHandler: { await recorder.record($0) },
            sleeper: { _ in }
        )

        let result = try await runner.run(configuration: try configuration(), deviceLabel: "Test iPhone")

        guard case let .succeeded(success) = result else {
            return XCTFail("应成功：\(result)")
        }
        XCTAssertEqual(success.device.deviceId, "dev_1")
        XCTAssertEqual(success.port, 43_871)
        XCTAssertEqual(success.state.step, .done)
        XCTAssertEqual(success.serverInfo.serverName, "pi-adaptor")
        XCTAssertEqual(success.serverInfo.serverVersion, "0.21.0")
        XCTAssertEqual(pairing.callCount, 1)
        XCTAssertEqual(pairing.material?.token, token)
        XCTAssertEqual(pairing.deviceLabel, "Test iPhone")
        XCTAssertEqual(pairing.transportIdentity, recordedTransport(transport))
        XCTAssertEqual(verifier.callCount, 1)
        XCTAssertEqual(verifier.device?.deviceToken, issuedToken)
        XCTAssertEqual(verifier.transportIdentity, recordedTransport(transport))
        XCTAssertTrue(transport.closed)
        XCTAssertEqual(transport.count(for: BootstrapRemoteCommand.probe), 1)
        XCTAssertEqual(transport.count(for: BootstrapRemoteCommand.installScript), 1)
        XCTAssertEqual(transport.count(for: BootstrapRemoteCommand.launch), 1)

        XCTAssertFalse(transport.allCommands().contains(where: { $0.contains(token) }))
        let events = await recorder.events
        XCTAssertTrue(events.contains(.pairingStarted))
        XCTAssertTrue(events.contains(.pairingCompleted(deviceId: "dev_1")))
        XCTAssertTrue(events.contains(.verificationStarted))
        XCTAssertTrue(events.contains(.verificationCompleted))
        for event in events {
            XCTAssertFalse(String(describing: event).contains(token), "事件不得携带配对令牌")
        }
    }

    func testUnsupportedPlatformDoesNotUploadOrDownload() async throws {
        let transport = MockBootstrapTransport(
            responses: [
                BootstrapRemoteCommand.probe: [
                    SSHExecResult(exitStatus: 0, stdout: Data("platform=Darwin\narch=arm64\n".utf8), stderr: Data()),
                ],
            ]
        )
        let pairing = RecordingPairer(result: BootstrapPairedDevice(
            deviceId: "unused",
            deviceToken: "unused",
            roles: []
        ))
        let runner = BootstrapRunner(
            transport: transport,
            pairing: pairing,
            verifier: RecordingVerifier(),
            configuration: BootstrapRunnerConfiguration(
                pollInterval: 0.001,
                overallTimeout: 2,
                commandTimeout: 2
            ),
            sleeper: { _ in }
        )

        let result = try await runner.run(configuration: try configuration())

        guard case let .unsupported(reason) = result else {
            return XCTFail("macOS 必须被拒绝：\(result)")
        }
        XCTAssertTrue(reason.message.contains("仅支持 Linux"))
        XCTAssertEqual(transport.count(for: BootstrapRemoteCommand.probe), 1)
        XCTAssertEqual(transport.count(for: BootstrapRemoteCommand.installScript), 0)
        XCTAssertEqual(transport.count(for: BootstrapRemoteCommand.launch), 0)
        XCTAssertEqual(pairing.callCount, 0)
    }

    func testPairingCallbackFailureWritesFailureMarkerAndReturnsTypedFailure() async throws {
        let transport = MockBootstrapTransport(
            responses: [
                BootstrapRemoteCommand.probe: [
                    SSHExecResult(exitStatus: 0, stdout: Data("platform=Linux\narch=aarch64\n".utf8), stderr: Data()),
                ],
                BootstrapRemoteCommand.installScript: [success()],
                BootstrapRemoteCommand.launch: [success()],
                BootstrapRemoteCommand.readState: [
                    try state(.startPair),
                    try state(.pair, status: .failed, error: .object(["code": .string("pair-failed")])),
                ],
                BootstrapRemoteCommand.readPairing: [pairingResult()],
                BootstrapRemoteCommand.writePairingFailed: [success()],
            ]
        )
        let pairing = RecordingPairer(error: TestError.pairing)
        let runner = BootstrapRunner(
            transport: transport,
            pairing: pairing,
            verifier: RecordingVerifier(),
            configuration: BootstrapRunnerConfiguration(
                pollInterval: 0.001,
                overallTimeout: 2,
                commandTimeout: 2
            ),
            sleeper: { _ in }
        )

        let result = try await runner.run(configuration: try configuration())

        guard case let .failed(failure) = result else {
            return XCTFail("配对失败必须返回 failed：\(result)")
        }
        XCTAssertEqual(failure.code, .pairFailed)
        XCTAssertEqual(failure.callbackFailure, .pairing)
        XCTAssertEqual(transport.count(for: BootstrapRemoteCommand.writePairingFailed), 1)
        XCTAssertEqual(transport.count(for: BootstrapRemoteCommand.writePairingOK), 0)
    }

    func testDefaultRunnerRejectsLegacyPPT1WithoutCallingPairer() async throws {
        let transport = MockBootstrapTransport(
            responses: [
                BootstrapRemoteCommand.probe: [
                    SSHExecResult(
                        exitStatus: 0,
                        stdout: Data("platform=Linux\narch=aarch64\n".utf8),
                        stderr: Data()
                    ),
                ],
                BootstrapRemoteCommand.installScript: [success()],
                BootstrapRemoteCommand.launch: [success()],
                BootstrapRemoteCommand.readState: [
                    try state(.startPair),
                    try state(
                        .pair,
                        status: .failed,
                        error: .object(["code": .string("pair-failed")])
                    ),
                ],
                BootstrapRemoteCommand.readPairing: [
                    pairingResult(token: "ppt1." + "legacy_token_for_test"),
                ],
                BootstrapRemoteCommand.writePairingFailed: [success()],
            ]
        )
        let pairing = RecordingPairer(
            result: BootstrapPairedDevice(
                deviceId: "must_not_run",
                deviceToken: "pdt2." + "not_used",
                roles: ["owner"]
            )
        )
        let runner = BootstrapRunner(
            transport: transport,
            pairing: pairing,
            verifier: RecordingVerifier(),
            configuration: BootstrapRunnerConfiguration(
                pollInterval: 0.001,
                overallTimeout: 2,
                commandTimeout: 2
            ),
            sleeper: { _ in }
        )

        let result = try await runner.run(configuration: try configuration())

        guard case let .failed(failure) = result else {
            return XCTFail("默认 PI-adaptor 安装必须拒绝 ppt1：\(result)")
        }
        XCTAssertEqual(failure.code, .pairFailed)
        XCTAssertTrue(failure.detail?.contains("ppt1") ?? false)
        XCTAssertEqual(pairing.callCount, 0)
    }

    func testVerificationCallbackFailureWritesFailureMarker() async throws {
        let transport = MockBootstrapTransport(
            responses: [
                BootstrapRemoteCommand.probe: [
                    SSHExecResult(exitStatus: 0, stdout: Data("platform=Linux\narch=aarch64\n".utf8), stderr: Data()),
                ],
                BootstrapRemoteCommand.installScript: [success()],
                BootstrapRemoteCommand.launch: [success()],
                BootstrapRemoteCommand.readState: [
                    try state(.startPair),
                    try state(.verifyDevice),
                    try state(.verifyDevice, status: .failed, error: .object(["code": .string("verify-device-failed")])),
                ],
                BootstrapRemoteCommand.readPairing: [pairingResult()],
                BootstrapRemoteCommand.writePairingOK: [success()],
                BootstrapRemoteCommand.writeVerificationFailed: [success()],
            ]
        )
        let verifier = RecordingVerifier(error: TestError.verification)
        let runner = BootstrapRunner(
            transport: transport,
            pairing: RecordingPairer(result: BootstrapPairedDevice(
                deviceId: "dev_verify",
                deviceToken: issuedToken,
                roles: []
            )),
            verifier: verifier,
            configuration: BootstrapRunnerConfiguration(
                pollInterval: 0.001,
                overallTimeout: 2,
                commandTimeout: 2
            ),
            sleeper: { _ in }
        )

        let result = try await runner.run(configuration: try configuration())

        guard case let .failed(failure) = result else {
            return XCTFail("校验失败必须返回 failed：\(result)")
        }
        XCTAssertEqual(failure.code, .verifyDeviceFailed)
        XCTAssertEqual(failure.callbackFailure, .verification)
        XCTAssertEqual(transport.count(for: BootstrapRemoteCommand.writeVerificationFailed), 1)
        XCTAssertEqual(verifier.callCount, 1)
    }

    func testRuntimeNameMismatchReturnsFailureDetail() async throws {
        let result = try await runVerificationFailure(
            serverInfo: RACPServerInfo(
                protocolVersion: "1.0",
                serverName: "pi-host",
                serverVersion: "0.21.0",
                hostId: "host_old",
                connectionId: "conn_old",
                roles: ["owner"]
            )
        )
        guard case let .failed(failure) = result else {
            return XCTFail("旧 Host 名称不得通过安装验证：\(result)")
        }
        XCTAssertEqual(failure.code, .verifyDeviceFailed)
        XCTAssertTrue(failure.detail?.contains("pi-host") ?? false)
        XCTAssertTrue(failure.detail?.contains("pi-adaptor") ?? false)
        XCTAssertTrue(failure.detail?.contains("pi-adaptor.service") ?? false)
        XCTAssertTrue(failure.detail?.contains("43871") ?? false)
    }

    func testRuntimeVersionMismatchReturnsFailureDetail() async throws {
        let result = try await runVerificationFailure(
            serverInfo: RACPServerInfo(
                protocolVersion: "1.0",
                serverName: "pi-adaptor",
                serverVersion: "0.20.0",
                hostId: "host_old",
                connectionId: "conn_old",
                roles: ["owner"]
            )
        )
        guard case let .failed(failure) = result else {
            return XCTFail("错误版本不得通过安装验证：\(result)")
        }
        XCTAssertEqual(failure.code, .verifyDeviceFailed)
        XCTAssertTrue(failure.detail?.contains("0.21.0") ?? false)
        XCTAssertTrue(failure.detail?.contains("0.20.0") ?? false)
        XCTAssertTrue(failure.detail?.contains("pi-adaptor.service") ?? false)
        XCTAssertTrue(failure.detail?.contains("43871") ?? false)
    }

    private func runVerificationFailure(
        serverInfo: RACPServerInfo
    ) async throws -> BootstrapRunResult {
        let transport = MockBootstrapTransport(
            responses: [
                BootstrapRemoteCommand.probe: [
                    SSHExecResult(
                        exitStatus: 0,
                        stdout: Data("platform=Linux\narch=aarch64\n".utf8),
                        stderr: Data()
                    ),
                ],
                BootstrapRemoteCommand.installScript: [success()],
                BootstrapRemoteCommand.launch: [success()],
                BootstrapRemoteCommand.readState: [
                    try state(.startPair),
                    try state(.verifyDevice),
                    try state(
                        .verifyDevice,
                        status: .failed,
                        error: .object(["code": .string("verify-device-failed")])
                    ),
                ],
                BootstrapRemoteCommand.readPairing: [pairingResult()],
                BootstrapRemoteCommand.writePairingOK: [success()],
                BootstrapRemoteCommand.writeVerificationFailed: [success()],
            ]
        )
        let runner = BootstrapRunner(
            transport: transport,
            pairing: RecordingPairer(
                result: BootstrapPairedDevice(
                    deviceId: "dev_mismatch",
                    deviceToken: issuedToken,
                    roles: ["owner"]
                )
            ),
            verifier: RecordingVerifier(serverInfo: serverInfo),
            configuration: BootstrapRunnerConfiguration(
                pollInterval: 0.001,
                overallTimeout: 2,
                commandTimeout: 2
            ),
            sleeper: { _ in }
        )
        return try await runner.run(configuration: try configuration())
    }

    func testPairingFileCanAppearAfterInitialPollWithoutLosingTheAttempt() async throws {
        let empty = SSHExecResult(exitStatus: 0, stdout: Data(), stderr: Data())
        let transport = MockBootstrapTransport(
            responses: [
                BootstrapRemoteCommand.probe: [
                    SSHExecResult(exitStatus: 0, stdout: Data("platform=Linux\narch=aarch64\n".utf8), stderr: Data()),
                ],
                BootstrapRemoteCommand.installScript: [success()],
                BootstrapRemoteCommand.launch: [success()],
                BootstrapRemoteCommand.readState: [
                    try state(.startPair),
                    try state(.startPair),
                    try state(.stopManual),
                    try state(.startUnit),
                    try state(.verifyDevice),
                    try state(.done, status: .ok),
                ],
                BootstrapRemoteCommand.readPairing: [empty, pairingResult()],
                BootstrapRemoteCommand.writePairingOK: [success()],
            ]
        )
        let pairing = RecordingPairer(result: BootstrapPairedDevice(
            deviceId: "dev_late",
            deviceToken: issuedToken,
            roles: []
        ))
        let runner = BootstrapRunner(
            transport: transport,
            pairing: pairing,
            verifier: RecordingVerifier(),
            configuration: BootstrapRunnerConfiguration(
                pollInterval: 0.001,
                overallTimeout: 2,
                commandTimeout: 2
            ),
            sleeper: { _ in }
        )

        let result = try await runner.run(configuration: try configuration())

        guard case .succeeded = result else {
            return XCTFail("迟到写入的 pair.json 应被后续轮询接手：\(result)")
        }
        XCTAssertEqual(pairing.callCount, 1)
    }

    func testStalledProgressEmitsARecoverablePointOnlyOnce() async throws {
        let transport = MockBootstrapTransport(
            responses: [
                BootstrapRemoteCommand.probe: [
                    SSHExecResult(exitStatus: 0, stdout: Data("platform=Linux\narch=aarch64\n".utf8), stderr: Data()),
                ],
                BootstrapRemoteCommand.installScript: [success()],
                BootstrapRemoteCommand.launch: [success()],
                BootstrapRemoteCommand.readState: [
                    try state(.download),
                    try state(.download),
                    try state(.download, status: .failed, error: .object(["code": .string("download-failed")])),
                ],
            ]
        )
        let recorder = EventRecorder()
        let runner = BootstrapRunner(
            transport: transport,
            pairing: RecordingPairer(result: BootstrapPairedDevice(
                deviceId: "unused",
                deviceToken: "unused",
                roles: []
            )),
            verifier: RecordingVerifier(),
            configuration: BootstrapRunnerConfiguration(
                pollInterval: 0.001,
                overallTimeout: 2,
                stallThreshold: 0,
                commandTimeout: 2
            ),
            eventHandler: { await recorder.record($0) },
            sleeper: { _ in }
        )

        let result = try await runner.run(configuration: try configuration())
        guard case let .failed(failure) = result else {
            return XCTFail("最终应返回失败状态：\(result)")
        }
        XCTAssertEqual(failure.code, .downloadFailed)
        let stalls = await recorder.events.filter {
            if case .stalled = $0 { return true }
            return false
        }
        XCTAssertEqual(stalls.count, 1)
    }

    func testOverallTimeoutRequestsRemoteCancellation() async throws {
        let transport = MockBootstrapTransport(
            responses: [
                BootstrapRemoteCommand.probe: [
                    SSHExecResult(exitStatus: 0, stdout: Data("platform=Linux\narch=aarch64\n".utf8), stderr: Data()),
                ],
                BootstrapRemoteCommand.installScript: [success()],
                BootstrapRemoteCommand.launch: [success()],
                BootstrapRemoteCommand.readState: [
                    try state(.probe),
                ],
                BootstrapRemoteCommand.cancel: [success()],
            ]
        )
        let clock = IncrementingClock()
        let runner = BootstrapRunner(
            transport: transport,
            pairing: RecordingPairer(result: BootstrapPairedDevice(
                deviceId: "unused",
                deviceToken: "unused",
                roles: []
            )),
            verifier: RecordingVerifier(),
            configuration: BootstrapRunnerConfiguration(
                pollInterval: 0.001,
                overallTimeout: 0.01,
                commandTimeout: 2
            ),
            sleeper: { _ in },
            now: { clock.next() }
        )

        do {
            _ = try await runner.run(configuration: try configuration())
            XCTFail("必须整体超时")
        } catch {
            XCTAssertEqual(error as? BootstrapRunnerError, .timedOut)
        }
        XCTAssertEqual(transport.count(for: BootstrapRemoteCommand.cancel), 1)
    }

    private enum TestError: Error {
        case pairing
        case verification
    }
}

private final class MockBootstrapTransport: BootstrapCommandTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [String: [SSHExecResult]]
    private var fallbacks: [String: SSHExecResult] = [:]
    private(set) var commands: [String] = []
    private(set) var closed = false

    init(responses: [String: [SSHExecResult]]) {
        self.responses = responses
        for (command, values) in responses {
            fallbacks[command] = values.last
        }
    }

    func exec(
        _ command: String,
        stdin: Data?,
        timeout: TimeInterval
    ) async throws -> SSHExecResult {
        withLock {
            commands.append(command)
            var queue = responses[command] ?? []
            if !queue.isEmpty {
                let next = queue.removeFirst()
                responses[command] = queue
                return next
            }
            if let fallback = fallbacks[command] {
                return fallback
            }
            return SSHExecResult(exitStatus: 0, stdout: Data(), stderr: Data())
        }
    }

    func close() async {
        withLock { closed = true }
    }

    func count(for command: String) -> Int {
        withLock { commands.filter { $0 == command }.count }
    }

    func allCommands() -> [String] {
        withLock { commands }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class RecordingPairer: BootstrapPairingCallback, @unchecked Sendable {
    private let lock = NSLock()
    private let result: BootstrapPairedDevice?
    private let error: Error?
    private(set) var callCount = 0
    private(set) var material: BootstrapPairingMaterial?
    private(set) var deviceLabel: String?
    private(set) var transportIdentity: ObjectIdentifier?

    init(result: BootstrapPairedDevice) {
        self.result = result
        self.error = nil
    }

    init(error: Error) {
        self.result = nil
        self.error = error
    }

    func pair(
        using transport: any BootstrapCommandTransport,
        material: BootstrapPairingMaterial,
        deviceLabel: String?
    ) async throws -> BootstrapPairedDevice {
        let (error, result) = withLock {
            callCount += 1
            self.material = material
            self.deviceLabel = deviceLabel
            transportIdentity = ObjectIdentifier(transport as AnyObject)
            return (self.error, self.result)
        }
        if let error { throw error }
        return result!
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class RecordingVerifier: BootstrapDeviceVerificationCallback, @unchecked Sendable {
    private let lock = NSLock()
    private let error: Error?
    private let serverInfo: RACPServerInfo
    private(set) var callCount = 0
    private(set) var device: BootstrapPairedDevice?
    private(set) var transportIdentity: ObjectIdentifier?

    init(
        error: Error? = nil,
        serverInfo: RACPServerInfo = RACPServerInfo(
            protocolVersion: "1.0",
            serverName: "pi-adaptor",
            serverVersion: "0.21.0",
            hostId: "host_test",
            connectionId: "conn_test",
            roles: ["owner"]
        )
    ) {
        self.error = error
        self.serverInfo = serverInfo
    }

    func verify(
        using transport: any BootstrapCommandTransport,
        port: Int,
        device: BootstrapPairedDevice
    ) async throws -> RACPServerInfo {
        let (error, serverInfo) = withLock {
            callCount += 1
            self.device = device
            transportIdentity = ObjectIdentifier(transport as AnyObject)
            return (self.error, self.serverInfo)
        }
        if let error { throw error }
        return serverInfo
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private actor EventRecorder {
    private(set) var events: [BootstrapRunnerEvent] = []

    func record(_ event: BootstrapRunnerEvent) {
        events.append(event)
    }
}

private final class IncrementingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_000)

    func next() -> Date {
        lock.lock()
        defer { lock.unlock() }
        value = value.addingTimeInterval(1)
        return value
    }
}
