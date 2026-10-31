import Foundation
import XCTest
@testable import PIiOSCore
@testable import PIiOSNet

/// Opt-in end-to-end installation against a disposable Linux account.
///
/// Required environment:
/// - `PI_BOOTSTRAP_SSH_HOST`, `PI_BOOTSTRAP_SSH_USER`, `PI_BOOTSTRAP_SSH_KEY`
/// - `PI_BOOTSTRAP_PORT` (the loopback port installed into the user unit)
/// - `PI_BOOTSTRAP_RELEASE_BASE_URL` (directory containing both bundles and `.sha256`)
final class RealBootstrapInstallTests: XCTestCase {
    func testInstallsPairsStartsUnitAndVerifiesDeviceToken() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["PI_BOOTSTRAP_SSH_HOST"],
              let user = env["PI_BOOTSTRAP_SSH_USER"],
              let keyPath = env["PI_BOOTSTRAP_SSH_KEY"],
              let rawPort = env["PI_BOOTSTRAP_PORT"],
              let port = Int(rawPort) else {
            throw XCTSkip("未配置真实 bootstrap 安装环境")
        }
        let releaseBaseURL = env["PI_BOOTSTRAP_RELEASE_BASE_URL"]
            ?? PiHostRelease.defaultPatchedBaseURL

        let key = try String(contentsOfFile: keyPath, encoding: .utf8)
        let sshAuth = SSHCredential.privateKey(openSSHText: key, passphrase: nil)
        let transport = try await SSHTransport.connect(
            SSHConnectionRequest(
                host: host,
                port: Int(env["PI_SSH_PORT"] ?? "22") ?? 22,
                username: user,
                credential: sshAuth,
                pinnedHostKey: nil
            ),
            confirmer: AcceptBootstrapHostKey(),
            timeout: 20
        )

        let probe = try await transport.exec(BootstrapRemoteCommand.probe, timeout: 15)
        XCTAssertEqual(probe.exitStatus, 0)
        let identity = try parseProbe(probe.stdoutText)
        let decision = BootstrapPlatformProbe.decide(
            unameSystem: identity.platform,
            unameMachine: identity.architecture
        )
        let target = try XCTUnwrap(decision.target)
        let release = try XCTUnwrap(
            PiHostRelease.patched(target: target, baseURL: releaseBaseURL)
        )
        let attempt = "real-\(UUID().uuidString.lowercased())"
        let configuration = try BootstrapScriptConfiguration(
            release: release,
            attemptId: attempt,
            hostArchitecture: identity.architecture,
            port: port,
            readyTimeoutSeconds: 120,
            pairTimeoutSeconds: 180,
            stopTimeoutSeconds: 30,
            verifyTimeoutSeconds: 120
        )

        let runner = BootstrapRunner(
            transport: transport,
            pairing: BootstrapInstallPairingAdapter(),
            verifier: BootstrapInstallVerificationAdapter(),
            configuration: BootstrapRunnerConfiguration(
                pollInterval: 1,
                overallTimeout: 10 * 60,
                stallThreshold: 3 * 60,
                commandTimeout: 30,
                pairingCallbackTimeout: 120,
                verificationCallbackTimeout: 60
            )
        )
        let result = try await runner.run(configuration: configuration, deviceLabel: "PI-IOS real bootstrap test")

        guard case let .succeeded(success) = result else {
            return XCTFail("真实安装未成功：\(result)")
        }
        XCTAssertEqual(success.state.step, .done)
        XCTAssertEqual(success.state.status, .ok)
        XCTAssertEqual(success.state.service?.state, "active")
        XCTAssertEqual(success.port, port)
        XCTAssertFalse(success.device.deviceToken.isEmpty)
    }

    private func parseProbe(_ stdout: String) throws -> (platform: String, architecture: String) {
        var platform: String?
        var architecture: String?
        for line in stdout.components(separatedBy: .newlines) {
            let pair = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            if pair[0] == "platform" { platform = pair[1] }
            if pair[0] == "arch" { architecture = pair[1] }
        }
        guard let platform, let architecture else {
            throw BootstrapRunnerError.malformedProbe
        }
        return (platform, architecture)
    }
}

private struct AcceptBootstrapHostKey: HostKeyConfirming {
    func confirmHostKey(_ key: SSHHostKey, status: HostKeyTrustStatus) async -> HostKeyConfirmation {
        .trust
    }
}
