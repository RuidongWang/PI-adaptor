import Foundation
import XCTest

@testable import PIiOSCore
@testable import PIiOSNet

final class BootstrapInstallAdaptersTests: XCTestCase {
    private let issuedToken = "pdt2." + "adapter_device_token"

    private func material(port: Int = 43_871) throws -> BootstrapPairingMaterial {
        try BootstrapPairingMaterial(
            token: "ppt2." + "adapter_pairing_token",
            expiresAt: 1_800_000_000,
            host: "127.0.0.1",
            port: port
        )
    }

    func testPairingAdapterReusesTransportPersistsBeforeReturningAndRedactsToken() async throws {
        let transport = AdapterTransport()
        let recorder = PairingRecorder()
        let material = try material()
        let token = issuedToken
        let adapter = BootstrapInstallPairingAdapter(
            exchange: { received, receivedMaterial, label in
                recorder.record(
                    transport: ObjectIdentifier(received as AnyObject),
                    material: receivedMaterial,
                    label: label
                )
                return RACPPairResult(
                    deviceId: "dev_install",
                    deviceToken: token,
                    roles: ["owner"]
                )
            },
            persist: { device in
                recorder.recordPersisted(device)
            }
        )

        let device = try await adapter.pair(
            using: transport,
            material: material,
            deviceLabel: "Test iPhone"
        )

        XCTAssertEqual(device.deviceId, "dev_install")
        XCTAssertEqual(device.deviceToken, issuedToken)
        XCTAssertEqual(device.roles, ["owner"])
        XCTAssertEqual(recorder.transportIdentity, ObjectIdentifier(transport))
        XCTAssertEqual(recorder.material?.port, 43_871)
        XCTAssertEqual(recorder.label, "Test iPhone")
        XCTAssertEqual(recorder.persistedDevice, device)
        XCTAssertFalse(device.redactedDescription.contains(device.deviceToken))
        XCTAssertFalse(device.redactedDescription.contains(material.token))
    }

    func testPairingAdapterDoesNotReturnDeviceWhenPersistenceFails() async throws {
        let recorder = PairingRecorder()
        let token = issuedToken
        let adapter = BootstrapInstallPairingAdapter(
            exchange: { _, _, _ in
                RACPPairResult(
                    deviceId: "dev_keychain_failure",
                    deviceToken: token,
                    roles: ["owner"]
                )
            },
            persist: { device in
                recorder.recordPersisted(device)
                throw BootstrapInstallAdapterError.persistenceFailed
            }
        )

        do {
            _ = try await adapter.pair(
                using: AdapterTransport(),
                material: try material(),
                deviceLabel: nil
            )
            XCTFail("Keychain 写入失败时不得返回已配对")
        } catch {
            XCTAssertEqual(error as? BootstrapInstallAdapterError, .persistenceFailed)
        }
        XCTAssertEqual(recorder.persistedDevice?.deviceId, "dev_keychain_failure")
    }

    func testPairingAdapterRejectsLegacyDeviceToken() async throws {
        let recorder = PairingRecorder()
        let adapter = BootstrapInstallPairingAdapter(
            exchange: { _, _, _ in
                RACPPairResult(
                    deviceId: "dev_legacy",
                    deviceToken: "pdt1." + "legacy_token_for_test",
                    roles: ["owner"]
                )
            },
            persist: { recorder.recordPersisted($0) }
        )

        do {
            _ = try await adapter.pair(
                using: AdapterTransport(),
                material: try material(),
                deviceLabel: nil
            )
            XCTFail("PI-adaptor 安装不得接受旧 pdt1 设备令牌")
        } catch {
            XCTAssertEqual(error as? BootstrapInstallAdapterError, .legacyDeviceToken)
        }
        XCTAssertNil(recorder.persistedDevice)
    }

    func testVerificationAdapterUsesSameTransportPortAndDeviceToken() async throws {
        let transport = AdapterTransport()
        let recorder = VerificationRecorder()
        let device = BootstrapPairedDevice(
            deviceId: "dev_verify",
            deviceToken: issuedToken,
            roles: ["owner"]
        )
        let adapter = BootstrapInstallVerificationAdapter(verify: { received, port, receivedDevice in
            recorder.record(
                transport: ObjectIdentifier(received as AnyObject),
                port: port,
                device: receivedDevice
            )
            return RACPServerInfo(
                protocolVersion: "1.0",
                serverName: "pi-adaptor",
                serverVersion: "2.0.1",
                hostId: "host_1",
                connectionId: "conn_1",
                roles: ["owner"],
                remoteMaxPermissionMode: nil,
                applyCeilingToPairedDevices: nil,
                capabilities: nil
            )
        })

        let info = try await adapter.verify(using: transport, port: 43_871, device: device)

        XCTAssertEqual(recorder.transportIdentity, ObjectIdentifier(transport))
        XCTAssertEqual(recorder.port, 43_871)
        XCTAssertEqual(recorder.device, device)
        XCTAssertEqual(info.serverName, "pi-adaptor")
        XCTAssertEqual(info.serverVersion, "2.0.1")
    }

    func testDefaultAdapterRejectsNonSSHTransportWithoutPersisting() async throws {
        let recorder = PairingRecorder()
        let adapter = BootstrapInstallPairingAdapter(
            persist: { recorder.recordPersisted($0) }
        )

        do {
            _ = try await adapter.pair(
                using: AdapterTransport(),
                material: try material(),
                deviceLabel: nil
            )
            XCTFail("不能把 mock transport 当成真实 SSHTransport")
        } catch {
            XCTAssertEqual(error as? BootstrapInstallAdapterError, .requiresSSHTransport)
        }
        XCTAssertNil(recorder.persistedDevice)
    }

    func testVerificationAdapterRetriesWhileSystemdStartsListening() async throws {
        let attempts = AttemptCounter()
        let adapter = BootstrapInstallVerificationAdapter(
            retryTimeout: 5,
            retryInterval: 0.01,
            sleep: { _ in },
            verify: { _, _, _ in
                let attempt = await attempts.increment()
                if attempt == 1 {
                    throw SSHTransportError.tunnelRefused(
                        phase: "direct-tcpip",
                        detail: "not listening yet"
                    )
                }
                return RACPServerInfo(
                    protocolVersion: "1.0",
                    serverName: "pi-adaptor",
                    serverVersion: "2.0.1",
                    hostId: "host_install",
                    connectionId: "conn_install",
                    roles: ["owner"],
                    remoteMaxPermissionMode: nil,
                    applyCeilingToPairedDevices: nil,
                    capabilities: nil
                )
            }
        )

        let info = try await adapter.verify(
            using: AdapterTransport(),
            port: 43_871,
            device: BootstrapPairedDevice(
                deviceId: "dev_retry",
                deviceToken: issuedToken,
                roles: ["owner"]
            )
        )
        let attemptCount = await attempts.value
        XCTAssertEqual(attemptCount, 2)
        XCTAssertEqual(info.serverName, "pi-adaptor")
        XCTAssertEqual(info.serverVersion, "2.0.1")
    }

    func testLogCommandTargetsOwnerOnlyBootstrapLogWithTailAndDoesNotLeakToken() {
        let command = BootstrapInstallDiagnostics.logCommand
        XCTAssertTrue(command.contains("$HOME/.pi-adaptor/.bootstrap/bootstrap.log"))
        XCTAssertTrue(command.contains("tail -n 240"))
        XCTAssertFalse(command.contains("ppt1."))
        XCTAssertFalse(command.contains("pdt1."))
    }

    func testEnableLingerCommandReadsSudoCredentialFromStdinOnly() {
        let command = BootstrapInstallDiagnostics.enableLingerCommand
        XCTAssertTrue(command.contains("sudo -S -p ''"))
        XCTAssertTrue(command.contains("loginctl enable-linger"))
        XCTAssertFalse(command.contains("--password"))
        XCTAssertFalse(command.contains("ppt1."))
        XCTAssertFalse(command.contains("pdt1."))
    }
}

private actor AttemptCounter {
    private(set) var value = 0

    func increment() -> Int {
        value += 1
        return value
    }
}

private final class AdapterTransport: BootstrapCommandTransport, @unchecked Sendable {
    func exec(
        _ command: String,
        stdin: Data?,
        timeout: TimeInterval
    ) async throws -> SSHExecResult {
        SSHExecResult(exitStatus: 0, stdout: Data(), stderr: Data())
    }

    func close() async {}
}

private final class PairingRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedTransport: ObjectIdentifier?
    private var storedMaterial: BootstrapPairingMaterial?
    private var storedLabel: String?
    private var storedDevice: BootstrapPairedDevice?

    var transportIdentity: ObjectIdentifier? {
        lock.lock(); defer { lock.unlock() }
        return storedTransport
    }

    var material: BootstrapPairingMaterial? {
        lock.lock(); defer { lock.unlock() }
        return storedMaterial
    }

    var label: String? {
        lock.lock(); defer { lock.unlock() }
        return storedLabel
    }

    var persistedDevice: BootstrapPairedDevice? {
        lock.lock(); defer { lock.unlock() }
        return storedDevice
    }

    func record(
        transport: ObjectIdentifier,
        material: BootstrapPairingMaterial,
        label: String?
    ) {
        lock.lock(); defer { lock.unlock() }
        storedTransport = transport
        storedMaterial = material
        storedLabel = label
    }

    func recordPersisted(_ device: BootstrapPairedDevice) {
        lock.lock(); defer { lock.unlock() }
        storedDevice = device
    }
}

private final class VerificationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedTransport: ObjectIdentifier?
    private var storedPort: Int?
    private var storedDevice: BootstrapPairedDevice?

    var transportIdentity: ObjectIdentifier? {
        lock.lock(); defer { lock.unlock() }
        return storedTransport
    }

    var port: Int? {
        lock.lock(); defer { lock.unlock() }
        return storedPort
    }

    var device: BootstrapPairedDevice? {
        lock.lock(); defer { lock.unlock() }
        return storedDevice
    }

    func record(
        transport: ObjectIdentifier,
        port: Int,
        device: BootstrapPairedDevice
    ) {
        lock.lock(); defer { lock.unlock() }
        storedTransport = transport
        storedPort = port
        storedDevice = device
    }
}
