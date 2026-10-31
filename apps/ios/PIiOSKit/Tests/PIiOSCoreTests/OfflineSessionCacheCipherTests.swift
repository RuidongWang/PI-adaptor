import Foundation
import XCTest

@testable import PIiOSCore

final class OfflineSessionCacheCipherTests: XCTestCase {
    func testRoundTripsTextIncludingLegacyPlaintext() {
        let secret = "构建日志里有敏感路径 /Users/me/secret"
        let sealed = OfflineCacheCipher.seal(secret)
        XCTAssertEqual(OfflineCacheCipher.open(sealed), secret)

        // 没有前缀的旧行必须按明文读回，保证旧缓存升级后仍可读。
        XCTAssertEqual(OfflineCacheCipher.open("legacy plaintext"), "legacy plaintext")

        // Keychain 可用时应真的加密；不可用时降级为明文也不得丢数据。
        if sealed.hasPrefix("enc:v1:") {
            XCTAssertNotEqual(sealed, secret)
            XCTAssertTrue(sealed.hasPrefix("enc:v1:"))
        }
    }

    func testOptionalHelpersPreserveNil() {
        XCTAssertNil(OfflineCacheCipher.seal(optional: nil))
        XCTAssertNil(OfflineCacheCipher.open(optional: nil))
        XCTAssertEqual(OfflineCacheCipher.open(optional: OfflineCacheCipher.seal(optional: "t")), "t")
    }

    func testUnreadableCiphertextDoesNotLeakAsMessage() {
        // 结构像密文但无法解开：不得把密文当正文暴露出来。
        XCTAssertEqual(OfflineCacheCipher.open("enc:v1:not-valid-base64!!"), "")
        XCTAssertNil(OfflineCacheCipher.openOrNil("enc:v1:not-valid-base64!!"))
        XCTAssertEqual(OfflineCacheCipher.openOrNil("legacy plaintext"), "legacy plaintext")
    }
}
