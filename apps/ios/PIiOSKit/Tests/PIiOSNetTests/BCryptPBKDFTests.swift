import XCTest

@testable import PIiOSNet

/// `bcrypt_pbkdf` 与 AES-CTR 的正确性：带口令的 OpenSSH 私钥全靠这两块。
final class BCryptPBKDFTests: XCTestCase {
    /// 参考向量来自 OpenBSD 的 `bcrypt_pbkdf(3)` 参考实现（Go `x/crypto/ssh/internal/bcrypt_pbkdf` 测试同源）。
    func testReferenceVectorSingleBlock() throws {
        let derived = try BCryptPBKDF.derive(
            passphrase: Data("password".utf8),
            salt: Data("salt".utf8),
            rounds: 12,
            keyLength: 32
        )
        XCTAssertEqual(
            [UInt8](derived),
            [
                0x1a, 0xe4, 0x2c, 0x05, 0xd4, 0x87, 0xbc, 0x02, 0xf6, 0x49, 0x21, 0xa4, 0xeb, 0xe4,
                0xea, 0x93, 0xbc, 0xac, 0xfe, 0x13, 0x5f, 0xda, 0x99, 0x97, 0x4c, 0x06, 0xb7, 0xb0,
                0x1f, 0xae, 0x14, 0x9a,
            ]
        )
    }

    /// 多块输出（88 字节 = 3 个 32 字节块），验证块交织逻辑。
    func testReferenceVectorMultiBlock() throws {
        let derived = try BCryptPBKDF.derive(
            passphrase: Data("секретное слово".utf8),
            salt: Data("посолить немножко".utf8),
            rounds: 8,
            keyLength: 88
        )
        XCTAssertEqual(
            [UInt8](derived),
            [
                0x8d, 0xf4, 0x3f, 0xc6, 0xfe, 0x13, 0x1f, 0xc4, 0x7f, 0x0c, 0x9e, 0x39, 0x22, 0x4b,
                0xd9, 0x4c, 0x70, 0xb6, 0xfc, 0xc8, 0xee, 0x81, 0x35, 0xfa, 0xdd, 0xf6, 0x11, 0x56,
                0xe6, 0xcb, 0x27, 0x33, 0xea, 0x76, 0x5f, 0x31, 0x5a, 0x3e, 0x1e, 0x4a, 0xfc, 0x35,
                0xbf, 0x86, 0x87, 0xd1, 0x89, 0x25, 0x4c, 0x1e, 0x05, 0xa6, 0xfe, 0x80, 0xc0, 0x61,
                0x7f, 0x91, 0x83, 0xd6, 0x72, 0x60, 0xd6, 0xa1, 0x15, 0xc6, 0xc9, 0x4e, 0x36, 0x03,
                0xe2, 0x30, 0x3f, 0xbb, 0x43, 0xa7, 0x6a, 0x64, 0x52, 0x3f, 0xfd, 0xa6, 0x86, 0xb1,
                0xd4, 0x51, 0x85, 0x43,
            ]
        )
    }

    func testEmptyPassphraseIsRejected() {
        XCTAssertThrowsError(
            try BCryptPBKDF.derive(passphrase: Data(), salt: Data("salt".utf8), rounds: 16, keyLength: 32)
        ) { error in
            XCTAssertEqual(error as? BCryptPBKDF.Failure, .emptyPassphrase)
        }
    }

    func testZeroRoundsIsRejected() {
        XCTAssertThrowsError(
            try BCryptPBKDF.derive(
                passphrase: Data("p".utf8),
                salt: Data("salt".utf8),
                rounds: 0,
                keyLength: 32
            )
        ) { error in
            XCTAssertEqual(error as? BCryptPBKDF.Failure, .invalidRounds)
        }
    }

    /// NIST SP 800-38A F.5.1 AES-128-CTR 已知答案（全 128 位计数器自增，与 OpenSSH 一致）。
    func testAES128CTRKnownAnswer() throws {
        let key = try XCTUnwrap(hex("2b7e151628aed2a6abf7158809cf4f3c"))
        let iv = try XCTUnwrap(hex("f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff"))
        let plaintext = try XCTUnwrap(
            hex(
                "6bc1bee22e409f96e93d7e117393172a"
                    + "ae2d8a571e03ac9c9eb76fac45af8e51"
                    + "30c81c46a35ce411e5fbc1191a0a52ef"
                    + "f69f2445df4f9b17ad2b417be66c3710"
            )
        )
        let ciphertext = try XCTUnwrap(
            hex(
                "874d6191b620e3261bef6864990db6ce"
                    + "9806f66b7970fdff8617187bb9fffdff"
                    + "5ae4df3edbd5d35e5b4f09020db03eab"
                    + "1e031dda2fbe03d1792170a0f3009cee"
            )
        )
        XCTAssertEqual(try OpenSSHAES.ctr(plaintext, key: key, iv: iv), ciphertext)
        XCTAssertEqual(try OpenSSHAES.ctr(ciphertext, key: key, iv: iv), plaintext)
    }

    /// 非 16 字节整数倍（OpenSSH 的私钥段长度常常如此）也必须正确。
    func testAESCTRHandlesPartialFinalBlock() throws {
        let key = Data(repeating: 0x11, count: 32)
        let iv = Data(repeating: 0x22, count: 16)
        let plaintext = Data((0..<37).map { UInt8($0) })
        let encrypted = try OpenSSHAES.ctr(plaintext, key: key, iv: iv)
        XCTAssertEqual(encrypted.count, plaintext.count)
        XCTAssertEqual(try OpenSSHAES.ctr(encrypted, key: key, iv: iv), plaintext)
    }

    func testUnsupportedKeyLengthIsRejected() {
        XCTAssertThrowsError(try OpenSSHAES.ctr(Data([0]), key: Data(repeating: 1, count: 17), iv: Data(repeating: 0, count: 16))) {
            XCTAssertEqual($0 as? OpenSSHAES.Failure, .unsupportedKeyLength(17))
        }
    }

    private func hex(_ string: String) -> Data? {
        var bytes: [UInt8] = []
        var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(index, offsetBy: 2)
            guard let byte = UInt8(string[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }
}
