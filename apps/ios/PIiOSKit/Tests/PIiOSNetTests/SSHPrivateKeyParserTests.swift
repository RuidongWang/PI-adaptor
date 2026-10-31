import XCTest
import CryptoKit
import NIOSSH

@testable import PIiOSNet

/// spec E6 的密钥矩阵：ed25519 / ecdsa(P-256/384/521) / rsa，且可带 passphrase。
///
/// fixture 全部由 `ssh-keygen` 临时生成（`Tests/PIiOSNetTests/Fixtures/`），
/// 因此这里断言的是「与 OpenSSH 自己的输出一致」——私钥能被解析、公钥与 `.pub` 逐字节相同。
final class SSHPrivateKeyParserTests: XCTestCase {
    private let passphrase = SSHFixture.passphrase

    // MARK: 未加密私钥

    func testEd25519UnencryptedParsesAndMatchesOpenSSHPublicKey() throws {
        try assertParses("ed25519_none.key", passphrase: nil)
    }

    func testECDSAP256UnencryptedParsesAndMatchesOpenSSHPublicKey() throws {
        try assertParses("ecdsa256_none.key", passphrase: nil)
    }

    func testECDSAP384UnencryptedParsesAndMatchesOpenSSHPublicKey() throws {
        try assertParses("ecdsa384_none.key", passphrase: nil)
    }

    func testECDSAP521UnencryptedParsesAndMatchesOpenSSHPublicKey() throws {
        try assertParses("ecdsa521_none.key", passphrase: nil)
    }

    func testRSA2048UnencryptedParsesAndMatchesOpenSSHPublicKey() throws {
        try assertParses("rsa2048_none.key", passphrase: nil)
    }

    func testRSA3072UnencryptedParsesAndMatchesOpenSSHPublicKey() throws {
        try assertParses("rsa3072_none.key", passphrase: nil)
    }

    func testTraditionalRSAPEMMatchesOpenSSHPublicKey() throws {
        let original = try SSHFixture.text("rsa2048_none.key")
        let rsa = try SSHPrivateKeyParser.parse(openSSHPrivateKey: original)
        let fields = try RSAFields(openSSHPrivateKey: original)
        let der = try NIOSSHRSAPrivateKey(openSSHModulus: fields.modulus, publicExponent: fields.publicExponent, privateExponent: fields.privateExponent, coefficient: fields.coefficient, prime1: fields.prime1, prime2: fields.prime2).pkcs1DER
        let pem = "-----BEGIN " + "RSA PRIVATE KEY-----\n" + der.base64EncodedString(options: .lineLength64Characters) + "\n-----END " + "RSA PRIVATE KEY-----"
        XCTAssertEqual(String(openSSHPublicKey: try SSHPrivateKeyParser.parse(openSSHPrivateKey: pem).publicKey), String(openSSHPublicKey: rsa.publicKey))
        XCTAssertFalse(try SSHPrivateKeyParser.requiresPassphrase(openSSHPrivateKey: pem))
    }

    // MARK: 带口令私钥（bcrypt_pbkdf + AES-CTR）

    func testPassphraseProtectedEd25519Decrypts() throws {
        try assertParses("ed25519_pass.key", passphrase: passphrase)
    }

    func testPassphraseProtectedECDSADecrypts() throws {
        try assertParses("ecdsa256_pass.key", passphrase: passphrase)
    }

    func testPassphraseProtectedRSADecrypts() throws {
        try assertParses("rsa2048_pass.key", passphrase: passphrase)
    }

    func testEncryptedKeyWithoutPassphraseIsReportedAsRequiringOne() throws {
        let text = try SSHFixture.text("ed25519_pass.key")
        XCTAssertThrowsError(try SSHPrivateKeyParser.parse(openSSHPrivateKey: text)) { error in
            XCTAssertEqual(error as? SSHPrivateKeyError, .passphraseRequired)
        }
    }

    func testWrongPassphraseIsRejectedWithDedicatedError() throws {
        let text = try SSHFixture.text("rsa2048_pass.key")
        XCTAssertThrowsError(
            try SSHPrivateKeyParser.parse(openSSHPrivateKey: text, passphrase: "definitely-not-it")
        ) { error in
            XCTAssertEqual(error as? SSHPrivateKeyError, .wrongPassphrase)
            // 错误文案不得包含口令或密钥内容（AC-G2）。
            XCTAssertFalse((error as? CustomStringConvertible)?.description.contains("definitely-not-it") ?? false)
        }
    }

    func testEncryptedKeyReportsEncryptionInInfo() throws {
        let text = try SSHFixture.text("rsa2048_pass.key")
        let info = try SSHPrivateKeyParser.info(openSSHPrivateKey: text)
        XCTAssertTrue(info.isEncrypted)
        XCTAssertEqual(info.keyType, "ssh-rsa")
        XCTAssertEqual(info.displayName, "RSA")
        XCTAssertTrue(try SSHPrivateKeyParser.requiresPassphrase(openSSHPrivateKey: text))
    }

    func testUnencryptedKeyReportsNoEncryption() throws {
        let text = try SSHFixture.text("ecdsa384_none.key")
        let info = try SSHPrivateKeyParser.info(openSSHPrivateKey: text)
        XCTAssertFalse(info.isEncrypted)
        XCTAssertEqual(info.keyType, "ecdsa-sha2-nistp384")
        XCTAssertEqual(info.bits, 384)
        XCTAssertFalse(try SSHPrivateKeyParser.requiresPassphrase(openSSHPrivateKey: text))
    }

    // MARK: 明确拒绝的格式（附修复命令）

    func testNonOpenSSHFormatIsRejectedWithFixCommand() {
        let pem = "-----BEGIN " + "PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----\n"
        XCTAssertThrowsError(try SSHPrivateKeyParser.parse(openSSHPrivateKey: pem)) { error in
            guard case .unsupportedFormat = error as? SSHPrivateKeyError else {
                return XCTFail("应为 unsupportedFormat，实际是 \(error)")
            }
            XCTAssertTrue(
                (error as? CustomStringConvertible)?.description.contains("ssh-keygen") ?? false,
                "不支持的格式必须给出可执行的修复命令"
            )
        }
    }

    func testPPKFormatIsRejectedWithConversionHint() {
        let ppk = "PuTTY-User-Key-File-3: ssh-rsa\nEncryption: none\n"
        XCTAssertThrowsError(try SSHPrivateKeyParser.parse(openSSHPrivateKey: ppk)) { error in
            guard case .unsupportedFormat = error as? SSHPrivateKeyError else {
                return XCTFail("应为 unsupportedFormat，实际是 \(error)")
            }
            XCTAssertTrue(
                (error as? CustomStringConvertible)?.description.contains("PPK") ?? false
            )
        }
    }

    func testUnsupportedCipherIsReportedWithReencryptCommand() throws {
        // 手工拼一个声明 chacha20-poly1305@openssh.com 的容器：解析必须在解密前就明确拒绝。
        let text = try makeContainer(
            cipherName: "chacha20-poly1305@openssh.com",
            kdfName: "bcrypt",
            privateSection: Data(repeating: 7, count: 64)
        )
        XCTAssertThrowsError(
            try SSHPrivateKeyParser.parse(openSSHPrivateKey: text, passphrase: passphrase)
        ) { error in
            guard case .unsupportedCipher(let name) = error as? SSHPrivateKeyError else {
                return XCTFail("应为 unsupportedCipher，实际是 \(error)")
            }
            XCTAssertEqual(name, "chacha20-poly1305@openssh.com")
            XCTAssertTrue(
                (error as? CustomStringConvertible)?.description.contains("ssh-keygen -p") ?? false
            )
        }
    }

    func testMismatchedCheckIntOnUnencryptedKeyIsRejected() throws {
        let key = Curve25519.Signing.PrivateKey()
        var privateSection = SSHContainerWriter()
        privateSection.appendUInt32(0x1111_1111)
        privateSection.appendUInt32(0x2222_2222)  // 两个 checkint 不一致
        privateSection.appendString("ssh-ed25519")
        privateSection.appendString(Data(key.publicKey.rawRepresentation))
        privateSection.appendString(
            Data(key.rawRepresentation) + Data(key.publicKey.rawRepresentation)
        )
        privateSection.appendString("")
        privateSection.appendPadding()

        var publicBlob = SSHContainerWriter()
        publicBlob.appendString("ssh-ed25519")
        publicBlob.appendString(Data(key.publicKey.rawRepresentation))

        let text = try makeContainer(
            cipherName: "none",
            kdfName: "none",
            keyCount: 1,
            publicBlob: publicBlob.data,
            privateSection: privateSection.data
        )
        XCTAssertThrowsError(try SSHPrivateKeyParser.parse(openSSHPrivateKey: text)) { error in
            guard case .malformed = error as? SSHPrivateKeyError else {
                return XCTFail("应为 malformed，实际是 \(error)")
            }
        }
    }

    // MARK: 辅助

    private func assertParses(
        _ fixture: String,
        passphrase: String?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let name = String(fixture.dropLast(".key".count))
        let text = try SSHFixture.text(fixture)
        let parsedLine = try SSHPrivateKeyParser.publicKeyLine(
            openSSHPrivateKey: text,
            passphrase: passphrase
        )
        XCTAssertEqual(parsedLine, try SSHFixture.publicKeyLine(name), file: file, line: line)

        // 解析出的私钥必须能给出同一个公钥（NIOSSH 侧的序列化路径）。
        let key = try SSHPrivateKeyParser.parse(openSSHPrivateKey: text, passphrase: passphrase)
        XCTAssertEqual(
            String(openSSHPublicKey: key.publicKey),
            try SSHFixture.publicKeyLine(name),
            file: file,
            line: line
        )
    }

    private func makeContainer(
        cipherName: String,
        kdfName: String,
        keyCount: UInt32 = 1,
        publicBlob: Data = Data("placeholder".utf8),
        privateSection: Data
    ) throws -> String {
        var outer = SSHContainerWriter()
        outer.appendRaw(Data("openssh-key-v1\u{0}".utf8))
        outer.appendString(cipherName)
        outer.appendString(kdfName)
        if kdfName == "bcrypt" {
            var kdf = SSHContainerWriter()
            kdf.appendString(Data(repeating: 0xAB, count: 16))  // salt
            kdf.appendUInt32(16)  // rounds
            outer.appendString(kdf.data)
        } else {
            outer.appendString("")
        }
        outer.appendUInt32(keyCount)
        outer.appendString(publicBlob)
        outer.appendString(privateSection)

        let begin = "-----BEGIN " + "OPENSSH PRIVATE KEY-----"
        let end = "-----END " + "OPENSSH PRIVATE KEY-----"
        let base64 = outer.data.base64EncodedString(options: [.lineLength64Characters])
        return "\(begin)\n\(base64)\n\(end)\n"
    }
}

/// 与被测解析器独立的手写 writer：按 RFC 4251 的 `string`/`uint32` 布局拼字节。
struct SSHContainerWriter {
    private(set) var data = Data()

    mutating func appendRaw(_ bytes: Data) { data.append(bytes) }

    mutating func appendUInt32(_ value: UInt32) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    mutating func appendString(_ value: String) { appendString(Data(value.utf8)) }

    mutating func appendString(_ bytes: Data) {
        appendUInt32(UInt32(bytes.count))
        data.append(bytes)
    }

    /// OpenSSH 私有段按 1,2,3… 补齐到 8 字节对齐。
    mutating func appendPadding() {
        var next: UInt8 = 1
        while data.count % 8 != 0 {
            data.append(next)
            next &+= 1
        }
    }
}
