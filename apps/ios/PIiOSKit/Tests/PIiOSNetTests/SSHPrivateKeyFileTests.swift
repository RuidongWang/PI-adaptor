import XCTest
@testable import PIiOSNet

/// 私钥"按文件选择"的读取与校验：成功路径 + 取消/不可读/无效四类失败都要有可解释的结果。
final class SSHPrivateKeyFileTests: XCTestCase {
    private var fixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    }

    private func fixture(_ name: String) -> URL {
        fixtures.appendingPathComponent(name)
    }

    // MARK: 成功

    func testLoadsUnencryptedEd25519File() throws {
        let file = try SSHPrivateKeyFileLoader.load(contentsOf: fixture("ed25519_none.key"))
        XCTAssertEqual(file.info.keyType, "ssh-ed25519")
        XCTAssertFalse(file.info.isEncrypted)
        XCTAssertEqual(file.fileName, "ed25519_none.key")
        XCTAssertTrue(file.text.contains("PRIVATE KEY-----"))
    }

    func testLoadsEncryptedFileAndMarksItAsNeedingPassphrase() throws {
        let file = try SSHPrivateKeyFileLoader.load(contentsOf: fixture("ed25519_pass.key"))
        XCTAssertTrue(file.info.isEncrypted, "带口令的私钥必须被识别，界面才能要求填口令")
        XCTAssertNotEqual(file.info.cipherName, "none")
    }

    func testLoadsRSAPrivateKeyFile() throws {
        let file = try SSHPrivateKeyFileLoader.load(contentsOf: fixture("rsa2048_none.key"))
        XCTAssertTrue(file.info.keyType.contains("rsa"))
    }

    // MARK: 失败：不可读 / 空 / 过大

    func testMissingFileIsReportedAsUnreadable() {
        let missing = fixtures.appendingPathComponent("definitely-not-here.key")
        XCTAssertThrowsError(try SSHPrivateKeyFileLoader.load(contentsOf: missing)) { error in
            guard case SSHPrivateKeyFileError.unreadable = error else {
                return XCTFail("应为 unreadable，实际 \(error)")
            }
            XCTAssertTrue((error as! SSHPrivateKeyFileError).description.contains("无法读取所选文件"))
        }
    }

    func testEmptyFileIsRejected() {
        XCTAssertThrowsError(try SSHPrivateKeyFileLoader.load(fileName: "empty.key", data: Data())) { error in
            XCTAssertEqual(error as? SSHPrivateKeyFileError, .empty)
        }
    }

    func testOversizedFileIsRejectedBeforeParsing() {
        let big = Data(repeating: 0x41, count: SSHPrivateKeyFileLoader.maxBytes + 1)
        XCTAssertThrowsError(try SSHPrivateKeyFileLoader.load(fileName: "big.key", data: big)) { error in
            guard case .tooLarge = error as? SSHPrivateKeyFileError else {
                return XCTFail("应为 tooLarge，实际 \(error)")
            }
        }
    }

    // MARK: 失败：选错文件类型

    func testPublicKeyFileIsRejectedWithHint() {
        XCTAssertThrowsError(try SSHPrivateKeyFileLoader.load(contentsOf: fixture("ed25519_none.key.pub"))) { error in
            guard case let SSHPrivateKeyFileError.unsupported(detail) = error else {
                return XCTFail("应为 unsupported，实际 \(error)")
            }
            XCTAssertTrue(detail.contains("公钥"), "要明确提示别选成 .pub：\(detail)")
        }
    }

    func testPuTTYKeyIsRejectedWithConversionCommand() {
        let ppk = Data("PuTTY-User-Key-File-3: ssh-rsa\n".utf8)
        XCTAssertThrowsError(try SSHPrivateKeyFileLoader.load(fileName: "id.ppk", data: ppk)) { error in
            guard case let SSHPrivateKeyFileError.unsupported(detail) = error else {
                return XCTFail("应为 unsupported，实际 \(error)")
            }
            XCTAssertTrue(detail.contains("ssh-keygen"))
        }
    }

    func testNonUTF8FileIsRejected() {
        let binary = Data([0xFF, 0xFE, 0x00, 0x01])
        XCTAssertThrowsError(try SSHPrivateKeyFileLoader.load(fileName: "blob", data: binary)) { error in
            guard case .unsupported = error as? SSHPrivateKeyFileError else {
                return XCTFail("应为 unsupported，实际 \(error)")
            }
        }
    }

    func testCorruptedPrivateKeyIsRejectedByParser() {
        // 用拼接而不是字面量：避免把整段私钥块当成疑似敏感内容被工具改写。
        let begin = "-----BEGIN " + "OPENSSH PRIVATE KEY-----"
        let end = "-----END " + "OPENSSH PRIVATE KEY-----"
        let corrupted = Data("\(begin)\nAAAA\n\(end)\n".utf8)
        XCTAssertThrowsError(try SSHPrivateKeyFileLoader.load(fileName: "broken.key", data: corrupted)) { error in
            guard case .unsupported = error as? SSHPrivateKeyFileError else {
                return XCTFail("应为 unsupported，实际 \(error)")
            }
        }
    }
}
