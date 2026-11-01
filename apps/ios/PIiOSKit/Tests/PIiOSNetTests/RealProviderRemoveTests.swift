import Foundation
import XCTest
import PIiOSCore
@testable import PIiOSNet

final class RealProviderRemoveTests: XCTestCase {
    func testRACPV2ProviderRemoveAndIdempotentAbsent() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["PI_SSH_HOST"],
              let user = env["PI_SSH_USER"],
              let keyPath = env["PI_SSH_KEY"],
              let hostPortValue = env["PI_PROVIDER_V2_HOST_PORT"],
              let hostPort = Int(hostPortValue),
              let deviceToken = env["PI_PROVIDER_V2_DEVICE_TOKEN"],
              let baseURL = env["PI_PROVIDER_IMPORT_BASE_URL"],
              let secret = env["PI_PROVIDER_IMPORT_KEY"]
        else {
            throw XCTSkip("未配置隔离 RACP v2 provider-remove 环境")
        }
        let key = try String(contentsOfFile: keyPath, encoding: .utf8)
        let client = RACPClient(
            configuration: RACPConfiguration(
                ssh: SSHConnectionRequest(
                    host: host,
                    port: Int(env["PI_SSH_PORT"] ?? "22") ?? 22,
                    username: user,
                    credential: .privateKey(openSSHText: key, passphrase: nil),
                    pinnedHostKey: nil
                ),
                hostPort: hostPort,
                deviceToken: deviceToken
            ),
            confirmer: AcceptRemoveTestHostKey()
        )
        await startAndWaitForOnline(client)
        defer { Task { await client.stopBestEffort(timeout: 2) } }

        let input = ProviderCreateInput(
            name: "PI iOS Remove Test",
            vendorKey: "custom",
            type: "openai_compatible",
            protocol: "openai_compatible",
            authKind: "api_key_and_base_url",
            baseUrl: baseURL,
            models: [
                ProviderModelSpec(
                    id: "remove-test-model",
                    contextWindow: 8_000,
                    maxTokens: 1_000,
                    thinkingLevels: ["off"]
                ),
            ],
            secretValue: secret,
            apiStyle: "chat_completions"
        )
        let imported = try await RemoteProviderOperations.importProviders(
            client: client,
            payload: ProviderImportPayload.make(inputs: [input])
        )
        guard case .success(let success) = imported,
              let providerID = success.imported.first?.providerId
        else {
            return XCTFail("准备 provider 失败：\(imported)")
        }

        let first = try await RemoteProviderOperations.removeProvider(
            client: client,
            providerId: providerID
        )
        guard case .success(let summary) = first else {
            return XCTFail("删除失败：\(first)")
        }
        XCTAssertEqual(summary.effect, .deleted)
        XCTAssertTrue(summary.secretCleared)

        let second = try await RemoteProviderOperations.removeProvider(
            client: client,
            providerId: providerID
        )
        guard case .success(let absent) = second else {
            return XCTFail("重复删除应返回 absent：\(second)")
        }
        XCTAssertEqual(absent.effect, .absent)
    }

    private func startAndWaitForOnline(_ client: RACPClient) async {
        let stream = await client.start()
        for await update in stream {
            if case .ready = update { return }
            if case .error = update { return }
        }
    }
}

private struct AcceptRemoveTestHostKey: HostKeyConfirming {
    func confirmHostKey(
        _ key: SSHHostKey,
        status: HostKeyTrustStatus
    ) async -> HostKeyConfirmation {
        .trust
    }
}
