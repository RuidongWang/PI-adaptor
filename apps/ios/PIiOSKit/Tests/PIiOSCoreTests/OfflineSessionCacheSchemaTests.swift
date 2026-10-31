import XCTest

@testable import PIiOSCore

/// 契约 §6 C-4、AC-14.5、AC-15.1、AC-15.3。
final class OfflineSessionCacheSchemaTests: XCTestCase {
    private let hostA = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let hostB = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    private let clientA = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    func testDocumentRoundTripPreservesItemsCursorApprovalsAndDraft() throws {
        let snapshot = OfflineSessionCacheSnapshot(
            entries: [entry("itm_1", session: "ses_1", host: hostA, offset: 1)],
            cursors: [
                OfflineSessionCursor(
                    hostID: hostA,
                    sessionId: "ses_1",
                    epoch: "ep_7f",
                    sequence: 314,
                    updatedAt: base.addingTimeInterval(2)
                ),
            ],
            approvals: [
                approval(
                    "ap_1",
                    session: "ses_1",
                    host: hostA,
                    offset: 3,
                    revision: 9,
                    status: "pending"
                ),
            ],
            drafts: [
                OfflineSessionDraft(
                    hostID: hostA,
                    sessionId: "ses_1",
                    text: "unsent",
                    idempotencyKey: "turn_stable",
                    updatedAt: base.addingTimeInterval(4)
                ),
            ]
        )
        let document = OfflineSessionCacheDocument(snapshot: snapshot)
        let data = try JSONEncoder().encode(document)
        let decoded = try JSONDecoder().decode(OfflineSessionCacheDocument.self, from: data)

        XCTAssertEqual(decoded.version, OfflineSessionCacheDocument.currentVersion)
        XCTAssertEqual(decoded.snapshot, snapshot)
        XCTAssertEqual(decoded.snapshot.cachedSession(hostID: hostA, sessionID: "ses_1")?.cursor?.sequence, 314)
        XCTAssertEqual(decoded.snapshot.cachedSession(hostID: hostA, sessionID: "ses_1")?.approvals.first?.revision, 9)
        XCTAssertEqual(decoded.snapshot.cachedSession(hostID: hostA, sessionID: "ses_1")?.draft?.idempotencyKey, "turn_stable")
    }

    func testLegacyEntriesOnlyFileDecodesAndUpgradesWithoutDataLoss() throws {
        struct LegacyDocument: Encodable {
            let version = 1
            let entries: [OfflineSessionCacheEntry]
        }
        let legacy = LegacyDocument(
            entries: [entry("itm_old", session: "ses_old", host: hostA, offset: 0, text: "old")]
        )
        let data = try JSONEncoder().encode(legacy)
        let decoded = try JSONDecoder().decode(OfflineSessionCacheDocument.self, from: data)

        XCTAssertEqual(decoded.version, OfflineSessionCacheDocument.currentVersion)
        XCTAssertEqual(decoded.entries, legacy.entries)
        XCTAssertEqual(decoded.cursors, [])
        XCTAssertEqual(decoded.approvals, [])
        XCTAssertEqual(decoded.drafts, [])

        let upgradedData = try JSONEncoder().encode(decoded)
        let upgraded = try JSONDecoder().decode(OfflineSessionCacheDocument.self, from: upgradedData)
        XCTAssertEqual(upgraded.entries, legacy.entries)
        XCTAssertEqual(upgraded.version, OfflineSessionCacheDocument.currentVersion)
    }

    func testHostIsolationCoversEveryTable() {
        let snapshot = OfflineSessionCacheSnapshot(
            entries: [
                entry("itm_1", session: "ses_1", host: hostA, offset: 0, text: "A"),
                entry("itm_1", session: "ses_1", host: hostB, offset: 1, text: "B"),
            ],
            cursors: [
                cursor("ses_1", host: hostA, sequence: 10),
                cursor("ses_1", host: hostB, sequence: 20),
            ],
            approvals: [
                approval("ap_1", session: "ses_1", host: hostA, offset: 1, revision: 1),
                approval("ap_1", session: "ses_1", host: hostB, offset: 2, revision: 2),
            ],
            drafts: [
                draft("ses_1", host: hostA, text: "draft A"),
                draft("ses_1", host: hostB, text: "draft B"),
            ]
        )

        let cachedA = snapshot.cachedSession(hostID: hostA, sessionID: "ses_1")
        let cachedB = snapshot.cachedSession(hostID: hostB, sessionID: "ses_1")
        XCTAssertEqual(cachedA?.entries.map(\.text), ["A"])
        XCTAssertEqual(cachedA?.cursor?.sequence, 10)
        XCTAssertEqual(cachedA?.approvals.first?.revision, 1)
        XCTAssertEqual(cachedA?.draft?.text, "draft A")
        XCTAssertEqual(cachedB?.entries.map(\.text), ["B"])
        XCTAssertEqual(cachedB?.cursor?.sequence, 20)
        XCTAssertEqual(cachedB?.approvals.first?.revision, 2)
        XCTAssertEqual(cachedB?.draft?.text, "draft B")
        XCTAssertNil(snapshot.cachedSession(hostID: nil, sessionID: "ses_1"))
    }

    func testCachedApprovalsAreNeverActionableAndCarryStatusRevision() {
        let card = approval(
            "ap_1",
            session: "ses_1",
            host: hostA,
            offset: 0,
            revision: 17,
            status: "pending"
        )

        XCTAssertFalse(card.isActionable)
        XCTAssertEqual(card.revision, 17)
        XCTAssertEqual(card.status, "pending")
        XCTAssertTrue(card.offlineStatusText.contains("离线只读"))
        XCTAssertTrue(card.offlineStatusText.contains("可能已过期"))
    }

    func testReplacingSessionWithAuthoritativeSnapshotClearsVanishedApprovals() {
        var snapshot = OfflineSessionCacheSnapshot(
            approvals: [
                approval("ap_old", session: "ses_1", host: hostA, offset: 0, revision: 1),
            ],
            drafts: [draft("ses_1", host: hostA, text: "keep me")]
        )
        XCTAssertEqual(snapshot.cachedSession(hostID: hostA, sessionID: "ses_1")?.approvals.count, 1)

        snapshot.removeSession(hostID: hostA, sessionID: "ses_1")
        XCTAssertEqual(snapshot.cachedSession(hostID: hostA, sessionID: "ses_1")?.approvals, [])
        XCTAssertEqual(
            snapshot.cachedSession(hostID: hostA, sessionID: "ses_1")?.draft?.text,
            "keep me",
            "权威快照替换审批与游标时不能误删用户草稿"
        )
    }

    func testCursorAndDraftDeduplicatePerHostAndSession() {
        let cursors = OfflineSessionCachePolicy.deduplicatedCursors([
            cursor("ses_1", host: hostA, sequence: 1),
            cursor("ses_1", host: hostA, sequence: 2),
            cursor("ses_1", host: hostB, sequence: 3),
        ])
        XCTAssertEqual(cursors.count, 2)
        XCTAssertEqual(
            cursors.first { $0.hostID == hostA }?.sequence,
            2
        )

        let drafts = OfflineSessionCachePolicy.deduplicatedDrafts([
            draft("ses_1", host: hostA, text: "old", offset: 0),
            draft("ses_1", host: hostA, text: "new", offset: 1),
            draft("ses_1", host: hostB, text: "other", offset: 2),
        ])
        XCTAssertEqual(drafts.count, 2)
        XCTAssertEqual(
            drafts.first { $0.hostID == hostA }?.text,
            "new"
        )
    }

    func testPruningAppliesTwentySessionsAndTwoHundredItemsAcrossSchema() {
        var snapshot = OfflineSessionCacheSnapshot()
        for sessionIndex in 0..<25 {
            let sessionID = "ses_\(sessionIndex)"
            snapshot.drafts.append(
                draft(
                    sessionID,
                    host: hostA,
                    text: "draft",
                    offset: TimeInterval(sessionIndex * 1_000)
                )
            )
            snapshot.cursors.append(cursor(sessionID, host: hostA, sequence: sessionIndex))
            for itemIndex in 0..<205 {
                snapshot.entries.append(
                    entry(
                        "itm_\(itemIndex)",
                        session: sessionID,
                        host: hostA,
                        offset: TimeInterval(sessionIndex * 1_000 + itemIndex)
                    )
                )
            }
        }

        let pruned = OfflineSessionCachePolicy.prunedSnapshot(
            snapshot,
            offlineCacheLimit: 200
        )
        XCTAssertEqual(pruned.entries.count, 20 * 200)
        XCTAssertEqual(pruned.drafts.count, 20)
        XCTAssertEqual(pruned.cursors.count, 20)
        XCTAssertFalse(pruned.drafts.contains { $0.sessionId == "ses_0" })
        XCTAssertFalse(pruned.drafts.contains { $0.sessionId == "ses_4" })
        XCTAssertTrue(pruned.drafts.contains { $0.sessionId == "ses_24" })
        XCTAssertFalse(pruned.entries.contains {
            $0.sessionId == "ses_24" && $0.id == "itm_0"
        })
    }

    func testWriteLeaseRejectsClientGenerationHostAndSessionMismatch() {
        let lease = OfflineSessionCacheWriteLease(
            clientID: clientA,
            connectionGeneration: 7,
            hostID: hostA,
            sessionID: "ses_1"
        )
        XCTAssertTrue(
            lease.isCurrent(
                clientID: clientA,
                connectionGeneration: 7,
                hostID: hostA,
                sessionID: "ses_1"
            )
        )
        XCTAssertFalse(
            lease.isCurrent(
                clientID: UUID(),
                connectionGeneration: 7,
                hostID: hostA,
                sessionID: "ses_1"
            )
        )
        XCTAssertFalse(
            lease.isCurrent(
                clientID: clientA,
                connectionGeneration: 8,
                hostID: hostA,
                sessionID: "ses_1"
            )
        )
        XCTAssertFalse(
            lease.isCurrent(
                clientID: clientA,
                connectionGeneration: 7,
                hostID: hostB,
                sessionID: "ses_1"
            )
        )
        XCTAssertFalse(
            lease.isCurrent(
                clientID: clientA,
                connectionGeneration: 7,
                hostID: hostA,
                sessionID: "ses_2"
            )
        )
    }

    func testDraftLeaseSurvivesSessionSwitchButNotHostOrClientChange() {
        let lease = OfflineSessionCacheWriteLease(
            clientID: clientA,
            connectionGeneration: 7,
            hostID: hostA,
            sessionID: "ses_1"
        )
        XCTAssertFalse(
            lease.isCurrent(
                clientID: clientA,
                connectionGeneration: 7,
                hostID: hostA,
                sessionID: "ses_2"
            )
        )
        XCTAssertTrue(
            lease.isCurrentHost(
                clientID: clientA,
                connectionGeneration: 7,
                hostID: hostA
            )
        )
        XCTAssertFalse(
            lease.isCurrentHost(
                clientID: UUID(),
                connectionGeneration: 7,
                hostID: hostA
            )
        )
        XCTAssertFalse(
            lease.isCurrentHost(
                clientID: clientA,
                connectionGeneration: 8,
                hostID: hostA
            )
        )
        XCTAssertFalse(
            lease.isCurrentHost(
                clientID: clientA,
                connectionGeneration: 7,
                hostID: hostB
            )
        )
    }

    func testNewSchemaColumnsContainNoCredentialFields() {
        XCTAssertEqual(
            CacheFieldPolicy.violations(inFields: OfflineSessionCacheSchema.allColumns),
            []
        )
        XCTAssertEqual(
            OfflineSessionCacheSchema.draftColumns.filter { $0 == "idempotency_key" }.count,
            1,
            "幂等键可以缓存；API Key/设备令牌/配对令牌不可以"
        )
    }

    func testOpaqueApprovalPayloadIsRedactedBeforeCaching() {
        let payload = JSONValue.object([
            "id": .string("apr_1"),
            "summary": .string("safe summary"),
            "secretValue": .string("must-not-persist"),
            "nested": .object([
                "authorization": .string("Bearer must-not-persist"),
                "toolName": .string("read_file"),
            ]),
            "array": .array([
                .object(["apiKey": .string("must-not-persist")]),
                .string("visible"),
            ]),
        ])

        let redacted = CacheFieldPolicy.redactedForCache(payload)
        XCTAssertEqual(redacted.value(at: ["id"])?.stringValue, "apr_1")
        XCTAssertEqual(redacted.value(at: ["summary"])?.stringValue, "safe summary")
        XCTAssertEqual(redacted.value(at: ["nested", "toolName"])?.stringValue, "read_file")
        XCTAssertEqual(redacted.value(at: ["secretValue"])?.stringValue, "[redacted]")
        XCTAssertEqual(redacted.value(at: ["nested", "authorization"])?.stringValue, "[redacted]")
        XCTAssertEqual(
            redacted.value(at: ["array"])?.arrayValue?[0].value(at: ["apiKey"])?.stringValue,
            "[redacted]"
        )
        XCTAssertFalse(String(describing: redacted).contains("must-not-persist"))
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

    private func cursor(
        _ session: String,
        host: UUID?,
        sequence: Int
    ) -> OfflineSessionCursor {
        OfflineSessionCursor(
            hostID: host,
            sessionId: session,
            epoch: "ep_1",
            sequence: sequence,
            updatedAt: base.addingTimeInterval(TimeInterval(sequence))
        )
    }

    private func draft(
        _ session: String,
        host: UUID?,
        text: String,
        offset: TimeInterval = 0
    ) -> OfflineSessionDraft {
        OfflineSessionDraft(
            hostID: host,
            sessionId: session,
            text: text,
            idempotencyKey: "turn_\(session)",
            updatedAt: base.addingTimeInterval(offset)
        )
    }

    private func approval(
        _ id: String,
        session: String,
        host: UUID?,
        offset: TimeInterval,
        revision: Int,
        status: String = "pending"
    ) -> OfflineSessionApproval {
        OfflineSessionApproval(
            id: id,
            sessionId: session,
            hostID: host,
            payload: .object([
                "id": .string(id),
                "kind": .string("tool"),
                "toolName": .string("Bash"),
                "revision": .number(Double(revision)),
                "status": .string(status),
            ]),
            revision: revision,
            status: status,
            decision: nil,
            createdAt: base.addingTimeInterval(offset)
        )
    }
}
