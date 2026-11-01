import XCTest
import NIOCore
@testable import PIiOSNet

/// 网络层错误必须翻译成用户能照着排查的原因：
/// 之前 `ChannelError.eof` 会原样显示成「未能完成操作。（NIOCore.ChannelError错误9）」。
final class SSHErrorMappingTests: XCTestCase {
    func testTimeoutReturnsWithoutWaitingForNonCancellableBody() async {
        let started = Date()
        do {
            let _: Int = try await withTimeout(seconds: 0.1, phase: "测试超时") {
                try await withCheckedThrowingContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.6) {
                        continuation.resume(returning: 42)
                    }
                }
            }
            XCTFail("Expected timeout")
        } catch let error as SSHTransportError {
            XCTAssertEqual(error, .timedOut("测试超时"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.4)
    }

    func testEOFDuringHandshakeBecomesClosedByPeer() {
        let mapped = SSHTransport.mapTransportError(ChannelError.eof, phase: "SSH 握手与认证")
        guard case let SSHTransportError.closedByPeer(phase) = mapped else {
            return XCTFail("eof 必须映射为 closedByPeer，实际：\(mapped)")
        }
        XCTAssertEqual(phase, "SSH 握手与认证")
        let text = SSHTransportError.closedByPeer(phase: phase).description
        XCTAssertTrue(text.contains("EOF"))
        XCTAssertTrue(text.contains("SSH 端口"), "必须提示检查是否把 SSH 端口填成了 PI-adaptor 端口")
        XCTAssertTrue(text.contains("sshd"))
    }

    func testClosedChannelVariantsAllMapToClosedByPeer() {
        for error in [ChannelError.inputClosed, .outputClosed, .alreadyClosed, .ioOnClosedChannel] {
            let mapped = SSHTransport.mapTransportError(error, phase: "打开 direct-tcpip 通道")
            guard case SSHTransportError.closedByPeer = mapped else {
                return XCTFail("\(error) 应映射为 closedByPeer")
            }
        }
    }

    func testConnectTimeoutMapsToTimedOut() {
        let mapped = SSHTransport.mapTransportError(ChannelError.connectTimeout(.seconds(1)), phase: "建立 TCP 连接")
        guard case let SSHTransportError.timedOut(phase) = mapped else {
            return XCTFail("connectTimeout 应映射为 timedOut")
        }
        XCTAssertEqual(phase, "建立 TCP 连接")
    }

    func testOtherChannelErrorsKeepANetworkFailureWithDetail() {
        let mapped = SSHTransport.mapTransportError(ChannelError.operationUnsupported, phase: "建立 TCP 连接")
        guard case let SSHTransportError.networkFailure(_, detail) = mapped else {
            return XCTFail("其它 ChannelError 应映射为 networkFailure")
        }
        XCTAssertFalse(detail.isEmpty)
    }

    func testAlreadyTypedTransportErrorsPassThroughUnchanged() {
        let original = SSHTransportError.authenticationFailed
        let mapped = SSHTransport.mapTransportError(original, phase: "SSH 握手与认证")
        XCTAssertEqual(mapped as? SSHTransportError, original)
    }
}
