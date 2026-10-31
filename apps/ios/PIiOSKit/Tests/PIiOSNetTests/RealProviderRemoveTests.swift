import Foundation
import XCTest
import PIiOSCore
@testable import PIiOSNet

final class RealProviderRemoveTests: XCTestCase {
    func testRemoteProviderRemoveAndIdempotentAbsent() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["PI_SSH_HOST"],
              let user = env["PI_SSH_USER"],
              let keyPath = env["PI_SSH_KEY"],
              let dataDir = env["PI_PROVIDER_IMPORT_DATA_DIR"],
              let baseURL = env["PI_PROVIDER_IMPORT_BASE_URL"],
              let secret = env["PI_PROVIDER_IMPORT_KEY"]
        else {
            throw XCTSkip("未配置隔离 provider-remove 环境")
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
            confirmer: AcceptRemoveTestHostKey(),
            timeout: 20
        )
        defer { Task { await transport.close() } }

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
        let payload = ProviderImportPayload.make(inputs: [input])
        let imported = try await RemoteProviderOperations.importProviders(
            transport: transport,
            payload: try ProviderImportEncoder.encode(payload),
            dataDir: dataDir
        )
        guard case .success(let success) = imported,
              let providerID = success.imported.first?.providerId
        else {
            return XCTFail("准备 provider 失败：\(imported)")
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let removePayload = try encoder.encode(ProviderRemovePayload(providerId: providerID))
        let first = try await RemoteProviderOperations.removeProvider(
            transport: transport,
            payload: removePayload,
            dataDir: dataDir
        )
        guard case .success(let summary) = first else {
            return XCTFail("删除失败：\(first)")
        }
        XCTAssertEqual(summary.effect, .deleted)
        XCTAssertTrue(summary.secretCleared)

        let second = try await RemoteProviderOperations.removeProvider(
            transport: transport,
            payload: removePayload,
            dataDir: dataDir
        )
        guard case .success(let absent) = second else {
            return XCTFail("重复删除应幂等：\(second)")
        }
        XCTAssertEqual(absent.effect, .absent)
    }
}

private struct AcceptRemoveTestHostKey: HostKeyConfirming {
    func confirmHostKey(_ key: SSHHostKey, status: HostKeyTrustStatus) async -> HostKeyConfirmation {
        .trust
    }
}
