import XCTest

@testable import PIiOSNet

final class HostKeyTrustTests: XCTestCase {
    /// 用 `ssh-keygen` 生成的真实 ed25519 公钥作 fixture（只有公钥，无任何凭证风险）。
    private let ed25519PublicKey =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILB11ifY0Z88i5R3qXuNU0/FIcXSAky9lgfG3dgHs7+a pi-ios-test"

    func testFingerprintMatchesOpenSSHFormat() throws {
        let key = try SSHHostKey(openSSHPublicKey: ed25519PublicKey)
        XCTAssertEqual(key.algorithm, "ssh-ed25519")
        // `ssh-keygen -lf k1.pub` 对该 fixture 的输出：SHA256:<下面这串>，无补位 `=`。
        // `ssh-keygen -lf k1.pub` 对该 fixture 的输出：SHA256:2Jsa2T7Nsgl4KWoF566A7+ud7585/d76u9LSydV0MBs
        XCTAssertEqual(key.fingerprint, "SHA256:2Jsa2T7Nsgl4KWoF566A7+ud7585/d76u9LSydV0MBs")
        XCTAssertFalse(key.fingerprint.hasSuffix("="))
        XCTAssertTrue(key.fingerprint.hasPrefix("SHA256:"))
    }

    func testMalformedPublicKeyThrows() {
        XCTAssertThrowsError(try SSHHostKey(openSSHPublicKey: "onlyonefield"))
        XCTAssertThrowsError(try SSHHostKey(openSSHPublicKey: "ssh-ed25519 not-base64!!"))
    }

    func testFirstUseNeedsConfirmation() throws {
        let presented = try SSHHostKey(openSSHPublicKey: ed25519PublicKey)
        XCTAssertEqual(HostKeyTrust.evaluate(presented: presented, pinned: nil), .firstUse)
    }

    func testSameKeyMatches() throws {
        let presented = try SSHHostKey(openSSHPublicKey: ed25519PublicKey)
        XCTAssertEqual(HostKeyTrust.evaluate(presented: presented, pinned: presented), .matches)
    }

    func testChangedKeyIsRejectedAndOldPinIsReported() throws {
        let pinned = try SSHHostKey(openSSHPublicKey: ed25519PublicKey)
        let other = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBKxagoNscXik"
            + "Y72al4HslKW+E6pWiESLzuvoAJ0Hyhowk60fE7x5QK9BLtVBq408ou/ENzqYKS/YmMaXOepcG8A= pi-ios-test-ec"
        let presented = try SSHHostKey(openSSHPublicKey: other)
        XCTAssertEqual(
            HostKeyTrust.evaluate(presented: presented, pinned: pinned),
            .changed(pinned: pinned)
        )
    }

    func testFingerprintIsStableAcrossHashInput() {
        let blob = Data([0x00, 0x01, 0x02, 0xFF])
        let a = SSHHostKey.fingerprint(ofBlob: blob)
        let b = SSHHostKey.fingerprint(ofBlob: blob)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, SSHHostKey.fingerprint(ofBlob: Data([0x00, 0x01, 0x02])))

    }

    // MARK: RSA 主机密钥（rsa-sha2-256 / rsa-sha2-512）

    /// spec E6 的另一半：服务器主机密钥是 RSA 时，指纹口径必须与 `ssh-keygen -lf` 完全一致。
    func testRSAHostKeyFingerprintMatchesSSHKeyGen() throws {
        let key = try SSHHostKey(openSSHPublicKey: Self.fixturePublicKeyLine("rsa3072_none"))
        // 公钥 blob 里的算法名永远是 ssh-rsa（RFC 8332），指纹只由 blob 决定。
        XCTAssertEqual(key.algorithm, "ssh-rsa")
        XCTAssertEqual(key.fingerprint, "SHA256:L8Jmj8AM+B3joJmdr08Rg4XZ52dONQy4aFzLu6MB3d4")
    }

    /// 固定 RSA 指纹后：同一把 key 再次连接必须 `.matches`，换一把必须 `.changed`（无「一键忽略」）。
    func testRSAHostKeyPinMatchesAndChangeIsDetected() throws {
        let pinned = try SSHHostKey(openSSHPublicKey: Self.fixturePublicKeyLine("rsa2048_none"))
        let sameAgain = try SSHHostKey(openSSHPublicKey: Self.fixturePublicKeyLine("rsa2048_none"))
        XCTAssertEqual(HostKeyTrust.evaluate(presented: sameAgain, pinned: pinned), .matches)

        let different = try SSHHostKey(openSSHPublicKey: Self.fixturePublicKeyLine("rsa3072_none"))
        XCTAssertEqual(
            HostKeyTrust.evaluate(presented: different, pinned: pinned),
            .changed(pinned: pinned)
        )
    }

    /// 协商算法名（rsa-sha2-256 / rsa-sha2-512 / ssh-rsa）不参与指纹计算：
    /// 同一份 blob 无论用哪个算法名协商，用户看到的指纹都必须一样。
    func testRSAFingerprintDependsOnlyOnKeyBlob() throws {
        let line = try SSHFixture.publicKeyLine("rsa2048_none")
        let blob = String(line.split(separator: " ")[1])
        let byBlob = SSHHostKey(algorithm: "ssh-rsa", blobBase64: blob)
        XCTAssertEqual(
            SSHHostKey(algorithm: "rsa-sha2-256", blobBase64: blob).fingerprint,
            byBlob.fingerprint
        )
        XCTAssertEqual(
            SSHHostKey(algorithm: "rsa-sha2-512", blobBase64: blob).fingerprint,
            byBlob.fingerprint
        )
        XCTAssertEqual(byBlob.fingerprint, "SHA256:0ZmiwQo4Yhj6eq1DD4D0HWcrzYl1usSZ4Q4l6hVqOhc")
    }

    private static func fixturePublicKeyLine(_ name: String) -> String {
        (try? SSHFixture.publicKeyLine(name)) ?? ""
    }
}
