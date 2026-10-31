import XCTest
@testable import PIiOSNet

/// 真实服务器联调（默认跳过）：用与 App 完全相同的 SSH 栈连一台**真实**服务器，
/// 验证「握手 + 主机密钥 + 私钥认证 + exec + direct-tcpip」这条链路。
///
/// 只在显式给了环境变量时运行，所以 CI / 无网络环境不会失败：
/// ```
/// PI_SSH_HOST=1.2.3.4 PI_SSH_USER=ubuntu PI_SSH_KEY=/abs/path/id_ed25519 \
///   PI_HOST_PORT=33381 swift test --filter RealServerSmokeTests
/// ```
/// 它只执行只读命令（`uname -m`）并打开一条 direct-tcpip 后立即关闭，不改服务器任何状态。
final class RealServerSmokeTests: XCTestCase {
    func testHandshakeExecAndTunnelAgainstRealServer() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["PI_SSH_HOST"],
              let user = env["PI_SSH_USER"],
              let keyPath = env["PI_SSH_KEY"] else {
            throw XCTSkip("未设置 PI_SSH_HOST / PI_SSH_USER / PI_SSH_KEY")
        }
        let port = Int(env["PI_SSH_PORT"] ?? "22") ?? 22
        let keyText = try String(contentsOfFile: keyPath, encoding: .utf8)

        let transport = try await SSHTransport.connect(
            SSHConnectionRequest(
                host: host,
                port: port,
                username: user,
                credential: .privateKey(openSSHText: keyText, passphrase: nil),
                pinnedHostKey: nil
            ),
            confirmer: AcceptHostKey(),
            timeout: 20
        )
        defer { Task { await transport.close() } }

        XCTAssertNotNil(transport.presentedHostKey, "握手必须留下服务器主机公钥用于指纹核对")
        let result = try await transport.exec("uname -m", timeout: 15)
        XCTAssertEqual(result.exitStatus, 0)
        XCTAssertFalse(result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        let stdinProbe = Data("pi-stdin-ok".utf8)
        let echoed = try await transport.exec("cat", stdin: stdinProbe, timeout: 15)
        XCTAssertEqual(echoed.exitStatus, 0)
        XCTAssertEqual(echoed.stdout, stdinProbe)

        if let raw = env["PI_HOST_PORT"], let hostPort = Int(raw) {
            let channel = try await transport.directTCPIP(port: hostPort, timeout: 15)
            try? await channel.close().get()
        }
    }
}

private struct AcceptHostKey: HostKeyConfirming {
    func confirmHostKey(_ key: SSHHostKey, status: HostKeyTrustStatus) async -> HostKeyConfirmation {
        // 测试里信任任何密钥；真实 App 走 HostKeyPromptBroker 让用户确认。
        .trust
    }
}
