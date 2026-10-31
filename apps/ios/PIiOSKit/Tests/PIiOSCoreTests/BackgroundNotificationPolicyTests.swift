import XCTest

@testable import PIiOSCore

final class BackgroundNotificationPolicyTests: XCTestCase {
    private let hostA = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let hostB = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!

    func testNoRevisionOrApprovalChangesDoesNotNotify() {
        let baseline = baseline(host: hostA, revisions: ["ses_1": 3], approvals: ["apr_1"])
        let current = snapshot(host: hostA, revisions: ["ses_1": 3], approvals: ["apr_1"])

        XCTAssertEqual(
            BackgroundNotificationPolicy.evaluate(baseline: baseline, current: current),
            .noChanges
        )
    }

    func testRevisionChangesNotifyWithChangedSessionCount() {
        let baseline = baseline(
            host: hostA,
            revisions: ["ses_1": 3, "ses_2": 8],
            approvals: []
        )
        let current = snapshot(
            host: hostA,
            revisions: ["ses_1": 4, "ses_2": 8],
            approvals: []
        )

        let decision = BackgroundNotificationPolicy.evaluate(baseline: baseline, current: current)
        XCTAssertEqual(
            decision,
            .notify(updatedSessionCount: 1, newApprovalCount: 0)
        )
        XCTAssertEqual(decision.notificationCount, 1)
    }

    func testNewSessionRevisionCountsAsChange() {
        let baseline = baseline(host: hostA, revisions: ["ses_1": 3], approvals: [])
        let current = snapshot(
            host: hostA,
            revisions: ["ses_1": 3, "ses_new": 0],
            approvals: []
        )

        XCTAssertEqual(
            BackgroundNotificationPolicy.evaluate(baseline: baseline, current: current),
            .notify(updatedSessionCount: 1, newApprovalCount: 0)
        )
    }

    func testOnlyNewApprovalsCountAndStillProduceOneNotification() {
        let baseline = baseline(host: hostA, revisions: ["ses_1": 3], approvals: ["apr_old"])
        let current = snapshot(
            host: hostA,
            revisions: ["ses_1": 3],
            approvals: ["apr_old", "apr_new"]
        )

        let decision = BackgroundNotificationPolicy.evaluate(baseline: baseline, current: current)
        XCTAssertEqual(
            decision,
            .notify(updatedSessionCount: 0, newApprovalCount: 1)
        )
        XCTAssertEqual(decision.notificationCount, 1)
    }

    func testRemovedApprovalAloneDoesNotNotify() {
        let baseline = baseline(host: hostA, revisions: ["ses_1": 3], approvals: ["apr_old"])
        let current = snapshot(host: hostA, revisions: ["ses_1": 3], approvals: [])

        XCTAssertEqual(
            BackgroundNotificationPolicy.evaluate(baseline: baseline, current: current),
            .noChanges
        )
    }

    func testHostChangeNeverCarriesChangesAcrossServers() {
        let baseline = baseline(host: hostA, revisions: ["ses_1": 3], approvals: [])
        let current = snapshot(
            host: hostB,
            revisions: ["ses_1": 4, "ses_b": 9],
            approvals: ["apr_b"]
        )

        XCTAssertEqual(
            BackgroundNotificationPolicy.evaluate(baseline: baseline, current: current),
            .ignore(.hostChanged)
        )
    }

    func testMissingBackgroundHostDoesNotNotify() {
        let baseline = baseline(host: nil, revisions: ["ses_1": 3], approvals: [])
        let current = snapshot(host: hostA, revisions: ["ses_1": 4], approvals: [])

        XCTAssertEqual(
            BackgroundNotificationPolicy.evaluate(baseline: baseline, current: current),
            .ignore(.missingBaseline)
        )
    }

    func testTrackerAllowsOnlyOneDecisionPerForegroundTransition() {
        let transitionID = UUID()
        let baselineSnapshot = baseline(host: hostA, revisions: ["ses_1": 3], approvals: [])
        let current = snapshot(host: hostA, revisions: ["ses_1": 4], approvals: [])
        var tracker = ForegroundNotificationTracker()

        tracker.begin(transitionID: transitionID, baseline: baselineSnapshot)
        XCTAssertTrue(tracker.hasActiveTransition)
        XCTAssertEqual(
            tracker.resolve(transitionID: transitionID, current: current),
            .notify(updatedSessionCount: 1, newApprovalCount: 0)
        )
        XCTAssertFalse(tracker.hasActiveTransition)
        XCTAssertEqual(
            tracker.resolve(transitionID: transitionID, current: current),
            .alreadyHandled
        )
    }

    func testTrackerUsesNewBaselineForNextForegroundTransition() {
        let firstTransition = UUID()
        let secondTransition = UUID()
        var tracker = ForegroundNotificationTracker()

        tracker.begin(
            transitionID: firstTransition,
            baseline: baseline(host: hostA, revisions: ["ses_1": 3], approvals: [])
        )
        _ = tracker.resolve(
            transitionID: firstTransition,
            current: snapshot(host: hostA, revisions: ["ses_1": 3], approvals: [])
        )

        tracker.begin(
            transitionID: secondTransition,
            baseline: baseline(host: hostA, revisions: ["ses_1": 3], approvals: [])
        )
        XCTAssertEqual(
            tracker.resolve(
                transitionID: secondTransition,
                current: snapshot(host: hostA, revisions: ["ses_1": 4], approvals: [])
            ),
            .notify(updatedSessionCount: 1, newApprovalCount: 0)
        )
    }

    func testAuthorizationRequestPolicyDoesNotRepeatDeniedOrFailedAttempts() {
        XCTAssertTrue(
            LocalNotificationAuthorizationPolicy.shouldRequest(
                status: .notDetermined,
                alreadyAttempted: false
            )
        )
        XCTAssertFalse(
            LocalNotificationAuthorizationPolicy.shouldRequest(
                status: .notDetermined,
                alreadyAttempted: true
            )
        )
        XCTAssertFalse(
            LocalNotificationAuthorizationPolicy.shouldRequest(
                status: .denied,
                alreadyAttempted: false
            )
        )
        XCTAssertFalse(
            LocalNotificationAuthorizationPolicy.shouldRequest(
                status: .authorized,
                alreadyAttempted: false
            )
        )
    }

    func testOnlyAuthorizedStatusesCanDeliver() {
        XCTAssertTrue(LocalNotificationAuthorizationPolicy.canDeliver(status: .authorized))
        XCTAssertTrue(LocalNotificationAuthorizationPolicy.canDeliver(status: .provisional))
        XCTAssertTrue(LocalNotificationAuthorizationPolicy.canDeliver(status: .ephemeral))
        XCTAssertFalse(LocalNotificationAuthorizationPolicy.canDeliver(status: .denied))
        XCTAssertFalse(LocalNotificationAuthorizationPolicy.canDeliver(status: .notDetermined))
    }

    private func baseline(
        host: UUID?,
        revisions: [String: Int],
        approvals: Set<String>
    ) -> BackgroundNotificationBaseline {
        BackgroundNotificationBaseline(
            hostID: host,
            sessionRevisions: revisions,
            pendingApprovalIDs: approvals
        )
    }

    private func snapshot(
        host: UUID?,
        revisions: [String: Int],
        approvals: Set<String>
    ) -> BackgroundNotificationSnapshot {
        BackgroundNotificationSnapshot(
            hostID: host,
            sessionRevisions: revisions,
            pendingApprovalIDs: approvals
        )
    }
}
