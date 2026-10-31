import XCTest

@testable import PIiOSCore

/// 离线缓存的 Host 分区、去重和保留上限。
final class OfflineSessionCachePolicyTests: XCTestCase {
    private let hostA = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let hostB = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    func testHostPartitionKeepsSameSessionAndItemIDsSeparate() {
        let entries = [
            entry("itm_1", session: "ses_1", host: hostA, offset: 0, text: "A"),
            entry("itm_1", session: "ses_1", host: hostB, offset: 1, text: "B"),
        ]

        XCTAssertNotEqual(
            OfflineSessionCachePolicy.itemKey(hostID: hostA, sessionID: "ses_1", itemID: "itm_1"),
            OfflineSessionCachePolicy.itemKey(hostID: hostB, sessionID: "ses_1", itemID: "itm_1")
        )
        let pruned = OfflineSessionCachePolicy.prunedEntries(entries, offlineCacheLimit: 200)
        XCTAssertEqual(pruned.count, 2)
        XCTAssertEqual(
            OfflineSessionCachePolicy.cachedEntries(entries, hostID: hostA, sessionID: "ses_1").map(\.text),
            ["A"]
        )
        XCTAssertEqual(
            OfflineSessionCachePolicy.cachedEntries(entries, hostID: hostB, sessionID: "ses_1").map(\.text),
            ["B"]
        )
    }

    func testEmptyHostNeverReturnsEntriesFromOtherHosts() {
        let entries = [entry("itm_1", session: "ses_1", host: hostA, offset: 0)]

        XCTAssertEqual(
            OfflineSessionCachePolicy.cachedEntries(entries, hostID: nil, sessionID: "ses_1"),
            []
        )
        XCTAssertEqual(OfflineSessionCachePolicy.sessionIDs(entries, hostID: nil), [])
    }

    func testPrunesToTwentySessionsAndTwoHundredItemsPerSession() {
        var entries: [OfflineSessionCacheEntry] = []
        for sessionIndex in 0..<25 {
            for itemIndex in 0..<205 {
                entries.append(
                    entry(
                        "itm_\(itemIndex)",
                        session: "ses_\(sessionIndex)",
                        host: hostA,
                        offset: TimeInterval(sessionIndex * 1_000 + itemIndex)
                    )
                )
            }
        }

        let pruned = OfflineSessionCachePolicy.prunedEntries(entries, offlineCacheLimit: 200)
        XCTAssertEqual(pruned.count, 20 * 200)
        XCTAssertFalse(pruned.contains { $0.sessionId == "ses_0" })
        XCTAssertFalse(pruned.contains { $0.sessionId == "ses_4" })
        XCTAssertTrue(pruned.contains { $0.sessionId == "ses_24" })
        XCTAssertFalse(pruned.contains {
            $0.sessionId == "ses_24" && $0.id == "itm_0"
        })
    }

    func testDeduplicatesSameSessionItemButKeepsNewestText() {
        let entries = [
            entry("itm_1", session: "ses_1", host: hostA, offset: 0, text: "old"),
            entry("itm_1", session: "ses_1", host: hostA, offset: 1, text: "new"),
        ]

        let deduplicated = OfflineSessionCachePolicy.deduplicatedEntries(entries)
        XCTAssertEqual(deduplicated.count, 1)
        XCTAssertEqual(deduplicated.first?.text, "new")
        XCTAssertEqual(
            OfflineSessionCachePolicy.prunedEntries(entries, offlineCacheLimit: 200).map(\.text),
            ["new"]
        )
    }

    func testCompositeKeysDoNotCollideForColonContainingIdentifiers() {
        let firstSession = "a:b"
        let firstItem = "c"
        let secondSession = "a"
        let secondItem = "b:c"

        XCTAssertNotEqual(
            OfflineSessionCachePolicy.itemKey(
                hostID: hostA,
                sessionID: firstSession,
                itemID: firstItem
            ),
            OfflineSessionCachePolicy.itemKey(
                hostID: hostA,
                sessionID: secondSession,
                itemID: secondItem
            )
        )

        let entries = [
            entry(firstItem, session: firstSession, host: hostA, offset: 0, text: "first"),
            entry(secondItem, session: secondSession, host: hostA, offset: 1, text: "second"),
        ]
        XCTAssertEqual(
            Set(OfflineSessionCachePolicy.deduplicatedEntries(entries).map(\.text)),
            Set(["first", "second"])
        )
    }

    private func entry(
        _ id: String,
        session: String,
        host: UUID?,
        offset: TimeInterval,
        text: String = "text"
    ) -> OfflineSessionCacheEntry {
        OfflineSessionCacheEntry(
            id: id,
            sessionId: session,
            hostID: host,
            text: text,
            createdAt: base.addingTimeInterval(offset)
        )
    }
}
