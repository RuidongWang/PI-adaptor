import XCTest
import NIOCore
import NIOPosix
import NIOSSH

@testable import PIiOSNet

/// 本机环回端到端：真 NIOSSH 服务端（RSA 主机密钥）+ 我们的 `SSHTransport` 客户端。
///
/// 覆盖 spec E6 的组合路径在**真实握手**里的表现：
/// 服务器只提供 RSA 主机密钥（协商成 rsa-sha2-256/rsa-sha2-512）→ 客户端验签、算 SHA256
/// 指纹、交给 TOFU 确认 → 客户端用 RSA 用户密钥完成 userauth。
///
/// 未覆盖：`exec` 的响应。服务端需要在子通道里回 exit status，而本机 NIOSSH 服务端在给子通道挂
/// handler 时会撞到 NIO 内部 precondition（`ChannelPipeline.swift:159`，与 RSA 补丁无关），
/// 因此这里只验证到「握手 + 认证 + 主机指纹」为止；`exec` / `direct-tcpip` 的代码路径本次未改，
/// 仍由 App 的真实使用验证。
final class SSHLoopbackTests: XCTestCase {
    func testRSAHostKeyAndRSAUserAuthOverLoopback() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        let serverKey = try makeHostKey()
        let serverChannel = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 4)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(
                    NIOSSHHandler(
                        role: .server(
                            SSHServerConfiguration(
                                hostKeys: [serverKey],
                                userAuthDelegate: AcceptAnyPublicKey()
                            )
                        ),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: nil
                    )
                )
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()

        do {
            let port = try XCTUnwrap(serverChannel.localAddress?.port)
            let keyText = try SSHFixture.text("rsa2048_none.key")
            let confirmer = RecordingHostKeyConfirmer()
            let transport = try await SSHTransport.connect(
                SSHConnectionRequest(
                    host: "127.0.0.1",
                    port: port,
                    username: "pi-test",
                    credential: .privateKey(openSSHText: keyText),
                    pinnedHostKey: nil
                ),
                confirmer: confirmer,
                timeout: 30
            )

            // 首次连接：客户端必须把服务器送来的 RSA 主机密钥交给用户核对（TOFU），且指纹与
            // `ssh-keygen -lf` 口径一致。
            let presented = try XCTUnwrap(transport.presentedHostKey)
            let expected = try SSHHostKey(
                openSSHPublicKey: try SSHFixture.publicKeyLine("rsa2048_none")
            )
            XCTAssertEqual(presented.fingerprint, expected.fingerprint)
            XCTAssertEqual(presented.algorithm, "ssh-rsa")

            let prompts = confirmer.prompts
            XCTAssertEqual(prompts.count, 1, "首次连接必须且只问一次")
            XCTAssertEqual(prompts.first?.status, .firstUse)
            XCTAssertEqual(prompts.first?.key.fingerprint, expected.fingerprint)

            await transport.close()
        } catch {
            try? await serverChannel.close().get()
            try? await group.shutdownGracefully()
            throw error
        }
        try? await serverChannel.close().get()
        try? await group.shutdownGracefully()
    }

    private func makeHostKey() throws -> NIOSSHPrivateKey {
        let fields = try RSAFields(openSSHPrivateKey: try SSHFixture.text("rsa2048_none.key"))
        let privateKey = try NIOSSHRSAPrivateKey(
            openSSHModulus: fields.modulus,
            publicExponent: fields.publicExponent,
            privateExponent: fields.privateExponent,
            coefficient: fields.coefficient,
            prime1: fields.prime1,
            prime2: fields.prime2
        )
        return NIOSSHPrivateKey(rsaKey: privateKey)
    }
}

/// 服务器侧：接受任何公钥（只用于本机环回测试，不代表生产行为）。
private final class AcceptAnyPublicKey: NIOSSHServerUserAuthenticationDelegate, @unchecked Sendable {
    let supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods = .publicKey

    func requestReceived(
        request: NIOSSHUserAuthenticationRequest,
        responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
    ) {
        responsePromise.succeed(.success)
    }
}

/// 记录客户端提出的指纹确认请求。
private final class RecordingHostKeyConfirmer: HostKeyConfirming, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(key: SSHHostKey, status: HostKeyTrustStatus)] = []

    var prompts: [(key: SSHHostKey, status: HostKeyTrustStatus)] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func confirmHostKey(_ key: SSHHostKey, status: HostKeyTrustStatus) async -> HostKeyConfirmation {
        lock.lock()
        storage.append((key, status))
        lock.unlock()
        return .trust
    }
}
