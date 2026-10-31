import XCTest
@testable import PIiOSCore
@testable import PIiOSNet

final class RACPHostSubscriptionTests: XCTestCase {
    func testHostSubscribeWireCarriesHostScopeAndResumeCursorWithoutSessionId() throws {
        let cursor = RACPCursor(epoch: "ep_host", sequence: 41)
        let request = RACPRequest(
            id: .number(1),
            method: .eventsSubscribe,
            params: RACPEventsSubscribeParams(scope: .host, after: cursor)
        )
        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let params = try XCTUnwrap(object["params"] as? [String: Any])

        XCTAssertEqual(object["method"] as? String, "events/subscribe")
        XCTAssertEqual(params["scope"] as? String, "host")
        XCTAssertNil(params["sessionId"])
        let after = try XCTUnwrap(params["after"] as? [String: Any])
        XCTAssertEqual(after["epoch"] as? String, "ep_host")
        XCTAssertEqual(after["sequence"] as? Int, 41)
    }

    func testHostAndSessionEventsRouteIndependently() {
        let host = event(
            sequence: 7,
            scope: "host",
            kind: "session.created",
            sessionId: "ses_new",
            revision: 1
        )
        let currentSession = event(
            sequence: 8,
            scope: "session",
            kind: "item.completed",
            sessionId: "ses_current"
        )
        let otherSession = event(
            sequence: 9,
            scope: "session",
            kind: "item.completed",
            sessionId: "ses_other"
        )

        XCTAssertEqual(RACPEventRouter.route(host, currentSessionID: "ses_current"), .host(host))
        XCTAssertEqual(
            RACPEventRouter.route(currentSession, currentSessionID: "ses_current"),
            .session(currentSession)
        )
        XCTAssertEqual(
            RACPEventRouter.route(otherSession, currentSessionID: "ses_current"),
            .ignored
        )
        XCTAssertEqual(RACPEventRouter.route(currentSession, currentSessionID: nil), .ignored)
    }

    func testCursorRecoveryOnlyAcceptsExplicitRecoveryCodes() {
        XCTAssertTrue(RACPClient.requiresCursorReset(
            RACPClientError.server(code: .cursorExpired, message: "expired")
        ))
        XCTAssertTrue(RACPClient.requiresCursorReset(
            RACPClientError.server(code: .clientTooSlow, message: "slow")
        ))
        XCTAssertFalse(RACPClient.requiresCursorReset(
            RACPClientError.server(code: .unauthorized, message: "no")
        ))
        XCTAssertFalse(RACPClient.requiresCursorReset(RACPClientError.notConnected))
    }

    func testLegacyScopeLessEventOnlyRoutesWhenItHasAnItem() throws {
        let item = try RACPItem(
            payload: .object([
                "id": .string("itm_1"),
                "itemType": .string("assistant_message"),
                "status": .string("completed"),
                "text": .string("hello"),
            ])
        )
        let legacy = RACPEvent(sequence: 3, epoch: "ep_1", item: item)
        let unknown = RACPEvent(sequence: 4, epoch: "ep_1")

        XCTAssertEqual(
            RACPEventRouter.route(legacy, currentSessionID: "ses_1"),
            .session(legacy)
        )
        XCTAssertEqual(RACPEventRouter.route(unknown, currentSessionID: "ses_1"), .ignored)
    }

    func testHostTrackerEmitsCatalogChangeAndSuppressesDuplicate() throws {
        var tracker = RACPHostSubscriptionTracker()
        tracker.install(
            subscriptionID: "sub_host_1",
            starting: RACPCursor(epoch: "ep_host", sequence: 10)
        )

        let created = event(
            sequence: 10,
            scope: "host",
            kind: "session.created",
            sessionId: "ses_new",
            revision: 3
        )
        let observation = try XCTUnwrap(tracker.observe(created))
        XCTAssertEqual(observation.change.reason, .catalogChanged)
        XCTAssertEqual(observation.change.sessionId, "ses_new")
        XCTAssertEqual(observation.change.revision, 3)
        XCTAssertEqual(observation.change.cursor, RACPCursor(epoch: "ep_host", sequence: 10))
        XCTAssertTrue(observation.requiresCatalogRefresh)

        XCTAssertNil(tracker.observe(created), "重放的重叠事件不能重复刷新")
    }

    func testHostTrackerTreatsNonContiguousGlobalSequenceAsNormalEpochAndResync() throws {
        var tracker = RACPHostSubscriptionTracker()
        tracker.install(
            subscriptionID: "sub_host_1",
            starting: RACPCursor(epoch: "ep_host", sequence: 10)
        )
        _ = tracker.observe(event(
            sequence: 10,
            scope: "host",
            kind: "session.changed",
            sessionId: "ses_1"
        ))

        // 序号 12 与 10 之间夹着会话事件（全局序号被占用），这不是缺口，
        // 不得据此触发重同步；按 kind 归类为普通目录变化即可。
        let next = try XCTUnwrap(tracker.observe(event(
            sequence: 12,
            scope: "host",
            kind: "session.changed",
            sessionId: "ses_1"
        )))
        XCTAssertNotEqual(next.change.reason, .eventGap)
        XCTAssertEqual(next.change.reason, .catalogChanged)

        let epoch = try XCTUnwrap(tracker.observe(event(
            sequence: 1,
            epoch: "ep_new",
            scope: "host",
            kind: "session.created",
            sessionId: "ses_2"
        )))
        XCTAssertEqual(epoch.change.reason, .epochChanged)

        let resync = try XCTUnwrap(tracker.observe(event(
            sequence: 2,
            epoch: "ep_new",
            scope: "host",
            kind: "resync.required",
            sessionId: nil
        )))
        XCTAssertEqual(resync.change.reason, .resyncRequired)
        XCTAssertTrue(resync.requiresCatalogRefresh)
    }

    func testEphemeralResyncRequiredTriggersCatalogRefresh() throws {
        var tracker = RACPHostSubscriptionTracker()
        tracker.install(
            subscriptionID: "sub_host_1",
            starting: RACPCursor(epoch: "ep_host", sequence: 10)
        )
        // `install(starting:)` 会把持久游标置于 `starting - 1`（重放从 starting 开始），
        // 故先消费一条 durable 事件，把水位推进到 10 作为基线，再验证 ephemeral 帧不篡改它。
        _ = tracker.observe(event(
            sequence: 10,
            scope: "host",
            kind: "session.created",
            sessionId: "ses_before_resync"
        ))
        XCTAssertEqual(tracker.cursor, RACPCursor(epoch: "ep_host", sequence: 10))
        let data = try JSONSerialization.data(withJSONObject: [
            "afterSequence": 12,
            "epoch": "ep_host",
            "scope": "host",
            "kind": "resync.required"
        ])
        let ephemeralEvent = try JSONDecoder().decode(RACPEvent.self, from: data)
        XCTAssertNil(ephemeralEvent.durableSequence)
        XCTAssertEqual(ephemeralEvent.afterSequence, 12)

        let observation = try XCTUnwrap(tracker.observe(ephemeralEvent))
        XCTAssertEqual(observation.change.reason, .resyncRequired)
        XCTAssertTrue(observation.requiresCatalogRefresh)
        // Durable cursor should NOT be advanced by an ephemeral frame
        XCTAssertEqual(tracker.cursor, RACPCursor(epoch: "ep_host", sequence: 10))
    }

    func testReconnectClearsSubscriptionIDButKeepsCursor() throws {
        var tracker = RACPHostSubscriptionTracker()
        tracker.install(
            subscriptionID: "sub_old",
            starting: RACPCursor(epoch: "ep_host", sequence: 10)
        )
        _ = tracker.observe(event(
            sequence: 10,
            scope: "host",
            kind: "session.created",
            sessionId: "ses_new"
        ))

        tracker.prepareForReconnect()
        XCTAssertNil(tracker.subscriptionID)
        XCTAssertEqual(tracker.cursor, RACPCursor(epoch: "ep_host", sequence: 10))

        tracker.install(
            subscriptionID: "sub_new",
            starting: RACPCursor(epoch: "ep_host", sequence: 11)
        )
        XCTAssertEqual(tracker.subscriptionID, "sub_new")
        XCTAssertEqual(tracker.cursor, RACPCursor(epoch: "ep_host", sequence: 10))

        let resumed = try XCTUnwrap(tracker.observe(event(
            sequence: 11,
            scope: "host",
            kind: "session.changed",
            sessionId: "ses_new"
        )))
        XCTAssertEqual(resumed.change.cursor, RACPCursor(epoch: "ep_host", sequence: 11))
    }

    func testReplayIncompleteResultDecodesForCatalogRecovery() throws {
        let value = JSONValue.object([
            "subscriptionId": .string("sub_host"),
            "starting": .object([
                "epoch": .string("ep_host"),
                "sequence": .number(90),
            ]),
            "replayComplete": .bool(false),
        ])
        let result = try RACPEventsSubscribeResult.decoded(from: value)

        XCTAssertEqual(result.subscriptionId, "sub_host")
        XCTAssertEqual(result.starting, RACPCursor(epoch: "ep_host", sequence: 90))
        XCTAssertEqual(result.replayComplete, false)
    }

    func testSubscriptionClosedNoticeCarriesResumableHostCursor() throws {
        let value = JSONValue.object([
            "subscriptionId": .string("sub_host"),
            "error": .object([
                "code": .string("CLIENT_TOO_SLOW"),
                "message": .string("subscriber did not acknowledge durable events in time"),
            ]),
            "lastSafeCursor": .object([
                "epoch": .string("ep_host"),
                "sequence": .number(88),
            ]),
        ])
        let notice = try RACPSubscriptionClosedNotice.decoded(from: value)

        XCTAssertEqual(notice.subscriptionId, "sub_host")
        XCTAssertEqual(notice.error?.code, "CLIENT_TOO_SLOW")
        XCTAssertEqual(notice.lastSafeCursor, RACPCursor(epoch: "ep_host", sequence: 88))

        var tracker = RACPHostSubscriptionTracker()
        tracker.install(
            subscriptionID: "sub_host",
            starting: RACPCursor(epoch: "ep_host", sequence: 90)
        )
        tracker.prepareForReconnect()
        tracker.restoreCursor(try XCTUnwrap(notice.lastSafeCursor))
        XCTAssertNil(tracker.subscriptionID)
        XCTAssertEqual(tracker.cursor, RACPCursor(epoch: "ep_host", sequence: 88))
    }

    private func event(
        sequence: Int,
        epoch: String = "ep_host",
        scope: String,
        kind: String,
        sessionId: String?,
        revision: Int? = nil
    ) -> RACPEvent {
        var payload: [String: JSONValue] = [
            "scope": .string(scope),
            "kind": .string(kind),
        ]
        if let sessionId {
            payload["sessionId"] = .string(sessionId)
        }
        if let revision {
            payload["revision"] = .number(Double(revision))
        }
        return RACPEvent(
            sequence: sequence,
            epoch: epoch,
            payload: .object(payload)
        )
    }
}
