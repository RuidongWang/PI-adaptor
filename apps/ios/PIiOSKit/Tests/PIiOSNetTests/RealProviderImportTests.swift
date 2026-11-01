import Foundation
import XCTest
import PIiOSCore
@testable import PIiOSNet

final class RealProviderImportTests: XCTestCase {
    func testProviderImportUsesRACPV2AgainstIsolatedHost() async throws {
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
            throw XCTSkip("未配置隔离 RACP v2 provider-import 环境")
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
            confirmer: AcceptImportHostKey()
        )
        await startAndWaitForOnline(client)
        defer { Task { await client.stopBestEffort(timeout: 2) } }

        let input = ProviderCreateInput(
            name: "PI iOS Import Test",
            vendorKey: "custom",
            type: "openai_compatible",
            protocol: "openai_compatible",
            authKind: "api_key_and_base_url",
            baseUrl: baseURL,
            models: [
                ProviderModelSpec(
                    id: "test-model",
                    contextWindow: 128_000,
                    maxTokens: 8_192,
                    thinkingLevels: ["off", "medium", "high"]
                ),
                ProviderModelSpec(
                    id: "plain-model",
                    contextWindow: 128_000,
                    maxTokens: 8_192,
                    thinkingLevels: []
                ),
            ],
            secretValue: secret,
            apiStyle: "chat_completions",
            defaultModelId: "plain-model"
        )
        let payload = ProviderImportPayload.make(
            inputs: [input],
            defaultSelection: ProviderImportDefaultSelection(
                providerIndex: 0,
                modelId: "plain-model"
            )
        )
        let receipt = try await RemoteProviderOperations.importProviders(
            client: client,
            payload: payload
        )
        guard case .success(let success) = receipt else {
            return XCTFail("导入失败：\(receipt)")
        }
        XCTAssertTrue(success.defaultSet)
        XCTAssertEqual(success.imported.count, 1)
        XCTAssertFalse(success.imported[0].providerId.isEmpty)
    }

    private func startAndWaitForOnline(_ client: RACPClient) async {
        let stream = await client.start()
        for await update in stream {
            if case .ready = update { return }
            if case .error = update { return }
        }
    }
}

private struct AcceptImportHostKey: HostKeyConfirming {
    func confirmHostKey(
        _ key: SSHHostKey,
        status: HostKeyTrustStatus
    ) async -> HostKeyConfirmation {
        .trust
    }
}
