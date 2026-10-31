import Foundation
import XCTest
@testable import PIiOSCore

final class OfflineSessionCacheFileTests: XCTestCase {
    private var directory: URL!
    private var url: URL { directory.appendingPathComponent("cache.json") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testMissingFileCanBeCreatedAndRoundTripsDrafts() throws {
        XCTAssertNil(try OfflineSessionCacheFile.load(from: url))
        let draft = OfflineSessionDraft(hostID: UUID(), sessionId: "session", text: "unsent fixture", idempotencyKey: "key", updatedAt: Date(timeIntervalSince1970: 100))
        let document = OfflineSessionCacheDocument(drafts: [draft])
        try OfflineSessionCacheFile.save(document, to: url)
        XCTAssertEqual(try OfflineSessionCacheFile.load(from: url), document)
        XCTAssertEqual(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }

    func testCorruptFutureAndInvalidVersionsAreNotOverwritten() throws {
        for raw in ["not-json", #"{"version":99,"drafts":[],"futureField":"preserve"}"#,
                    #"{"version":0,"entries":[]}"#, #"{"version":-1}"#,
                    #"{"version":2,"drafts":"broken"}"#,
                    #"{"version":2,"version":2}"#] {
            let original = Data(raw.utf8)
            try original.write(to: url)
            XCTAssertThrowsError(try OfflineSessionCacheFile.load(from: url))
            XCTAssertThrowsError(try OfflineSessionCacheFile.save(OfflineSessionCacheDocument(), to: url))
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
    }

    func testDirectoryReadErrorIsNotTreatedAsMissingFile() throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        XCTAssertThrowsError(try OfflineSessionCacheFile.load(from: url))
        XCTAssertThrowsError(try OfflineSessionCacheFile.save(OfflineSessionCacheDocument(), to: url))
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testLegacyCacheUpgradesAndSubsequentSavesRemainReadable() throws {
        try Data(#"{"entries":[]}"#.utf8).write(to: url)
        let legacy = try XCTUnwrap(OfflineSessionCacheFile.load(from: url))
        XCTAssertEqual(legacy.version, OfflineSessionCacheDocument.currentVersion)
        try OfflineSessionCacheFile.save(legacy, to: url)
        XCTAssertEqual(try OfflineSessionCacheFile.load(from: url), legacy)
    }

    func testOutgoingUnsupportedVersionDoesNotReplaceExistingCache() throws {
        try OfflineSessionCacheFile.save(OfflineSessionCacheDocument(), to: url)
        let original = try Data(contentsOf: url)
        XCTAssertThrowsError(try OfflineSessionCacheFile.save(OfflineSessionCacheDocument(version: 99), to: url))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
}
