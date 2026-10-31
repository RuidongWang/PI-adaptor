import XCTest

@testable import PIiOSCore

/// 契约 §6；spec AC-15.1 / AC-15.3。
final class CacheRetentionTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - 保留上限（AC-15.1）

    func testAC15_1_retentionLimitsMatchContract() {
        XCTAssertEqual(CacheRetention.maxItemsPerSession, 200)
        XCTAssertEqual(CacheRetention.maxSessions, 20)
    }

    func testAC15_1_keepsNewestTwoHundredItemsPerSession() {
        let items = (0..<250).map { index in
            CacheItemRecord(id: "itm_\(index)", sessionId: "ses_1", createdAt: base.addingTimeInterval(Double(index)))
        }
        let plan = CacheRetention.pruneItems(items)

        XCTAssertEqual(plan.kept.count, 200)
        XCTAssertEqual(plan.evicted.count, 50)
        XCTAssertEqual(Set(plan.kept).union(plan.evicted).count, 250)
        // 保留的是最新 200 条：最早 50 条被淘汰
        XCTAssertEqual(Set(plan.evicted), Set((0..<50).map { "itm_\($0)" }))
        XCTAssertTrue(plan.kept.contains("itm_249"))
        XCTAssertFalse(plan.kept.contains("itm_0"))
    }

    func testAC15_1_evictsByCreatedAtNotInsertionOrder() {
        // 输入顺序打乱：淘汰必须按 created_at，而不是数组顺序。
        var items = (0..<205).map { index in
            CacheItemRecord(id: "itm_\(index)", sessionId: "ses_1", createdAt: base.addingTimeInterval(Double(index)))
        }
        items.shuffle()
        let plan = CacheRetention.pruneItems(items)
        XCTAssertEqual(plan.kept.count, 200)
        XCTAssertEqual(Set(plan.evicted), Set((0..<5).map { "itm_\($0)" }))
    }

    func testAC15_1_prunesEachSessionIndependently() {
        let sessionOne = (0..<250).map { index in
            CacheItemRecord(id: "a_\(index)", sessionId: "ses_a", createdAt: base.addingTimeInterval(Double(index)))
        }
        let sessionTwo = (0..<10).map { index in
            CacheItemRecord(id: "b_\(index)", sessionId: "ses_b", createdAt: base.addingTimeInterval(Double(index)))
        }
        let plan = CacheRetention.pruneItems(sessionOne + sessionTwo)
        XCTAssertEqual(plan.kept.count, 200 + 10)
        XCTAssertEqual(plan.evicted.count, 50)
        XCTAssertTrue(plan.kept.contains("b_9"), "会话 b 未超限，不应被淘汰")
    }

    func testAC15_1_keepsAtMostTwentySessionsEvictingOldest() {
        let sessions = (0..<25).map { index in
            CacheSessionRecord(id: "ses_\(index)", createdAt: base.addingTimeInterval(Double(index)))
        }
        let plan = CacheRetention.pruneSessions(sessions)

        XCTAssertEqual(plan.kept.count, 20)
        XCTAssertEqual(plan.evicted.count, 5)
        XCTAssertEqual(Set(plan.evicted), Set((0..<5).map { "ses_\($0)" }), "按 created_at 淘汰最旧的 5 个会话")
        XCTAssertTrue(plan.kept.contains("ses_24"))
        XCTAssertFalse(plan.kept.contains("ses_0"))
    }

    func testAC15_1_pruneCombinesSessionAndItemLimits() {
        let sessions = (0..<22).map { index in
            CacheSessionRecord(id: "ses_\(index)", createdAt: base.addingTimeInterval(Double(index)))
        }
        var items: [CacheItemRecord] = []
        for sessionIndex in 0..<22 {
            for itemIndex in 0..<205 {
                items.append(
                    CacheItemRecord(
                        id: "ses\(sessionIndex)_itm\(itemIndex)",
                        sessionId: "ses_\(sessionIndex)",
                        createdAt: base.addingTimeInterval(Double(itemIndex))
                    )
                )
            }
        }
        let plan = CacheRetention.prune(sessions: sessions, items: items)

        XCTAssertEqual(plan.sessions.evicted.count, 2)
        // 被淘汰会话里的记录整体出清：2 * 205
        XCTAssertEqual(plan.items.evicted.count, 2 * 205 + 20 * 5)
        XCTAssertEqual(plan.items.kept.count, 20 * 200)
        XCTAssertFalse(plan.items.kept.contains { $0.hasPrefix("ses0_") }, "被淘汰会话的记录不得保留")
        XCTAssertTrue(plan.items.kept.allSatisfy { $0.contains("_itm") })
    }

    func testAC15_1_noEvictionBelowLimits() {
        let items = (0..<10).map { index in
            CacheItemRecord(id: "itm_\(index)", sessionId: "ses_1", createdAt: base.addingTimeInterval(Double(index)))
        }
        let sessions = [CacheSessionRecord(id: "ses_1", createdAt: base)]
        XCTAssertEqual(CacheRetention.pruneItems(items).evicted, [])
        XCTAssertEqual(CacheRetention.pruneSessions(sessions).evicted, [])
    }

    // MARK: - 设置里的上限（审查 fix 18）

    func testFix18_settingsLimitDrivesItemPruning() {
        // 默认仍是 200（契约 §6）。
        XCTAssertEqual(CacheRetention.defaultItemsPerSession, 200)
        XCTAssertEqual(CacheRetention.itemsPerSessionLimit(offlineCacheLimit: nil), 200)
        XCTAssertEqual(CacheRetention.itemsPerSessionLimit(offlineCacheLimit: 0), 200)
        XCTAssertEqual(CacheRetention.itemsPerSessionLimit(offlineCacheLimit: 1000), 1000)

        let items = (0..<1_200).map { index in
            CacheItemRecord(id: "itm_\(index)", sessionId: "ses_1", createdAt: base.addingTimeInterval(Double(index)))
        }

        // 设置里选 1000 就必须保留 1000 条，而不是仍按 200 淘汰。
        let wide = CacheRetention.pruneItems(items, offlineCacheLimit: 1000)
        XCTAssertEqual(wide.kept.count, 1_000)
        XCTAssertEqual(wide.evicted.count, 200)
        XCTAssertEqual(Set(wide.evicted), Set((0..<200).map { "itm_\($0)" }))

        // 不给设置值时保持默认 200。
        XCTAssertEqual(CacheRetention.pruneItems(items, offlineCacheLimit: nil).kept.count, 200)
        XCTAssertEqual(CacheRetention.pruneItems(items).kept.count, 200)

        // `prune` 也要把设置值传下去。
        let sessions = [CacheSessionRecord(id: "ses_1", createdAt: base)]
        XCTAssertEqual(CacheRetention.prune(sessions: sessions, items: items, offlineCacheLimit: 1000).items.kept.count, 1_000)
        XCTAssertEqual(CacheRetention.prune(sessions: sessions, items: items).items.kept.count, 200)
    }

    // MARK: - 缓存不得含密钥（AC-15.3）

    func testAC15_3_cacheSchemaContainsNoSecretFields() {
        XCTAssertEqual(CacheFieldPolicy.schemaViolations, [], "契约 §6 的列名里不得出现密钥类字段")
        for kind in CacheRecordKind.allCases {
            XCTAssertEqual(CacheFieldPolicy.violations(inFields: kind.columns), [], "\(kind.rawValue) 表列名应干净")
        }
    }

    func testAC15_3_secretFieldNamesAreDetected() {
        let forbidden = ["secretValue", "apiKey", "api_key", "deviceToken", "pairing_token", "Authorization", "x-api-key"]
        for field in forbidden {
            XCTAssertFalse(
                CacheFieldPolicy.violations(inFields: [field]).isEmpty,
                "应识别出密钥类字段：\(field)"
            )
        }
        XCTAssertTrue(CacheFieldPolicy.violations(inFields: ["idempotency_key"]).isEmpty, "普通字段不应被误判")
        XCTAssertEqual(CacheFieldPolicy.violations(inFields: CacheRecordKind.allColumns), [])
    }

    func testAC15_3_assertCleanRejectsSecretColumns() {
        XCTAssertNoThrow(try CacheFieldPolicy.assertClean(CacheRecordKind.allColumns, context: "contract §6"))
        XCTAssertThrowsError(try CacheFieldPolicy.assertClean(["id", "secretValue"], context: "自定义表")) { error in
            guard case let CacheFieldPolicyError.forbiddenFields(context, fields) = error else {
                return XCTFail("错误类型不对：\(error)")
            }
            XCTAssertEqual(context, "自定义表")
            XCTAssertEqual(fields, ["secretValue"])
        }
        XCTAssertTrue(CacheFieldPolicy.rule.contains("禁止"))
    }
}
