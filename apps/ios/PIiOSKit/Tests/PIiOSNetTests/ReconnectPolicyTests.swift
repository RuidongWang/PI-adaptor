import XCTest
@testable import PIiOSNet

/// 自动重连纪律：握手/认证/端口被拒这类“重试也没用”的失败必须停止重连，
/// 否则会持续冲击 sshd（MaxStartups / fail2ban），把用户后续的正常连接一起封掉。
final class ReconnectPolicyTests: XCTestCase {
    func testConnectionStageFailuresAreDetected() {
        for error in [
            SSHTransportError.closedByPeer(phase: "SSH 握手与认证"),
            SSHTransportError.tunnelRefused(phase: "打开 direct-tcpip 通道", detail: "refused"),
            SSHTransportError.authenticationFailed,
            SSHTransportError.hostKeyAlgorithmUnsupported,
            SSHTransportError.hostKeyUnreadable,
        ] {
            XCTAssertTrue(RACPClient.isConnectionStageFailure(error), "\(error) 应停止自动重连")
        }
    }

    func testTransientFailuresStillRetry() {
        XCTAssertFalse(RACPClient.isConnectionStageFailure(SSHTransportError.timedOut("SSH 握手与认证")))
        XCTAssertFalse(RACPClient.isConnectionStageFailure(SSHTransportError.networkFailure(phase: "建立 TCP 连接", detail: "unreachable")))
        XCTAssertFalse(RACPClient.isConnectionStageFailure(RACPClientError.notConnected))
    }

    func testRetryStopsAfterThreeConsecutiveStageFailures() {
        // 与 runLoop 里的一致：第 3 次即停止。
        XCTAssertEqual(RACPClient.maxConnectionStageFailures, 3)
    }
}
