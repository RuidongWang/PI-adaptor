import XCTest
@testable import PIiOSNet

/// `channelSetupRejected`（服务器拒绝转发）必须告诉用户「端口上没有服务」，而不是原始 NIO 文本。
final class TunnelRefusedMessageTests: XCTestCase {
    func testTunnelRefusedMessageNamesPortCheckAndRandomPortPitfall() {
        let error = SSHTransportError.tunnelRefused(
            phase: "打开 direct-tcpip 通道（目标 127.0.0.1:33381）",
            detail: "NIOSSHError.channelSetupRejected: Reason: 2 Connection refused"
        )
        let text = error.description
        XCTAssertTrue(text.contains("没有服务在监听"))
        XCTAssertTrue(text.contains("ss -ltn"))
        XCTAssertTrue(text.contains("--port 0"), "必须点明端口随机会导致连接不上")
        XCTAssertTrue(text.contains("33381"), "错误里要保留用户填的那个端口，便于对照")
    }
}
