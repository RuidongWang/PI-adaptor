import XCTest
import UniformTypeIdentifiers
@testable import PIiOSNet

/// `.key` 私钥必须能被选中：系统把这个扩展名认成 Keynote 的 package 类型，
/// 所以选择器类型里必须有类型树的根 `public.item`，且读取路径不能依赖扩展名。
final class PrivateKeyPickerTests: XCTestCase {
    func testAllowedContentTypesIncludeRootItemSoExtensionIsNeverFiltered() {
        let types = SSHPrivateKeyFileLoader.allowedContentTypes
        XCTAssertTrue(types.contains(.item), "必须包含 public.item，否则 package/未知扩展名会被置灰")
        // `.key` 在系统里是 Keynote 类型；它符合 public.item，所以列在白名单里就能选。
        let keyType = UTType(filenameExtension: "key")
        XCTAssertNotNil(keyType)
        XCTAssertTrue(keyType?.conforms(to: .item) ?? false)
        XCTAssertTrue(types.contains { keyType?.conforms(to: $0) ?? false })
    }

    func testKeyNamedFileLoadsAsPrivateKey() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ed25519_none.key")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-key-pick-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // 用用户实际会遇到的命名：私钥内容 + `.key` 扩展名。
        let target = directory.appendingPathComponent("server-prod.key")
        try FileManager.default.copyItem(at: source, to: target)

        let file = try SSHPrivateKeyFileLoader.load(contentsOf: target)
        XCTAssertEqual(file.fileName, "server-prod.key")
        XCTAssertEqual(file.info.keyType, "ssh-ed25519")
        XCTAssertTrue(file.text.contains("PRIVATE KEY-----"))
    }

    func testDirectoryIsRejectedWithReadableReason() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-key-dir-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertThrowsError(try SSHPrivateKeyFileLoader.load(contentsOf: directory)) { error in
            guard case SSHPrivateKeyFileError.directory = error else {
                return XCTFail("应为 directory，实际 \(error)")
            }
            XCTAssertTrue((error as! SSHPrivateKeyFileError).description.contains("文件夹"))
        }
    }
}
