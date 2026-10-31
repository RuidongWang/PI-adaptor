import XCTest
@testable import PIiOSNet

final class RACPPairingTests: XCTestCase {
    func testPairingTokenValidation() {
        XCTAssertEqual(RACPPairingToken.normalize("  ppt1.abc  "), "ppt1.abc")
        XCTAssertEqual(RACPPairingToken.normalize("ppt" + "2.abc"), "ppt" + "2.abc")
        XCTAssertNil(RACPPairingToken.normalize("pdt" + "1.abc"))
        XCTAssertNil(RACPPairingToken.normalize("pdt" + "2.abc"))
        XCTAssertNil(RACPPairingToken.normalize("ppt1."))
        XCTAssertNil(RACPPairingToken.normalize("ppt1.abc def"))
    }

    func testPairRejectsDeviceTokenBeforeConnecting() async {
        let ssh = SSHConnectionRequest(host: "127.0.0.1", port: 22, username: "test", credential: .password("test"), pinnedHostKey: nil)
        let client = RACPClient(configuration: RACPConfiguration(ssh: ssh, hostPort: 1, deviceToken: "pdt" + "2.abc"), confirmer: RejectHost())
        do {
            _ = try await client.pairOnce()
            XCTFail("设备令牌不能用于一次性配对")
        } catch let error as RACPClientError {
            guard case .protocolMismatch = error else { return XCTFail("错误分类不正确") }
        } catch {
            XCTFail("不应访问网络：\(error)")
        }
    }
}

private struct RejectHost: HostKeyConfirming {
    func confirmHostKey(_ key: SSHHostKey, status: HostKeyTrustStatus) async -> HostKeyConfirmation { .reject }
}
