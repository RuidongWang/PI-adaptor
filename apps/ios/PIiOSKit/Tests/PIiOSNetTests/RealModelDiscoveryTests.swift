import Foundation
import XCTest
@testable import PIiOSNet

/// Real SSH discovery smoke test. Skipped unless all four environment values
/// are supplied, so unit-only runs never depend on a provider.
final class RealModelDiscoveryTests: XCTestCase {
    func testRemoteModelDiscoveryUsesSSHStdin() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["PI_SSH_HOST"],
              let user = env["PI_SSH_USER"],
              let keyPath = env["PI_SSH_KEY"],
              let url = env["PI_MODEL_DISCOVERY_URL"],
              let apiKey = env["PI_MODEL_DISCOVERY_KEY"]
        else {
            throw XCTSkip("未配置真实模型发现环境变量")
        }
        let key = try String(contentsOfFile: keyPath, encoding: .utf8)
        let transport = try await SSHTransport.connect(
            SSHConnectionRequest(
                host: host,
                port: Int(env["PI_SSH_PORT"] ?? "22") ?? 22,
                username: user,
                credential: .privateKey(openSSHText: key, passphrase: nil),
                pinnedHostKey: nil
            ),
            confirmer: AcceptModelDiscoveryHostKey(),
            timeout: 20
        )
        defer { Task { await transport.close() } }

        let models = try await RemoteProviderOperations.discoverModels(
            transport: transport,
            requestURL: url,
            apiKey: apiKey
        )
        XCTAssertFalse(models.isEmpty)
        XCTAssertTrue(models.allSatisfy { !$0.modelId.isEmpty })
    }
}

private struct AcceptModelDiscoveryHostKey: HostKeyConfirming {
    func confirmHostKey(_ key: SSHHostKey, status: HostKeyTrustStatus) async -> HostKeyConfirmation {
        .trust
    }
}
