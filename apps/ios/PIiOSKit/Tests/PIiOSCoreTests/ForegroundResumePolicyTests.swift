import XCTest
@testable import PIiOSCore

final class ForegroundResumePolicyTests: XCTestCase {
    private let hostA = UUID()
    private let hostB = UUID()

    func testNewSessionWithUnknownRevisionStillMarksItsRow() {
        let updates = compare([:], ["new": .init(revision: nil)])
        XCTAssertEqual(updates, [reference("new")])
    }

    func testRevisionChangesMarkOnlyAffectedSessions() {
        let updates = compare(
            ["a": .init(revision: 1), "b": .init(revision: 2)],
            ["a": .init(revision: 2), "b": .init(revision: 2)]
        )
        XCTAssertEqual(updates, [reference("a")])
    }

    func testApprovalsAddedRemovedOrReplacedMarkTheirOwnRows() {
        let updates = compare(
            ["added": .init(revision: 1, pendingApprovalIDs: []),
             "removed": .init(revision: 1, pendingApprovalIDs: ["old"]),
             "replaced": .init(revision: 1, pendingApprovalIDs: ["old"])],
            ["added": .init(revision: 1, pendingApprovalIDs: ["new"]),
             "removed": .init(revision: 1, pendingApprovalIDs: []),
             "replaced": .init(revision: 1, pendingApprovalIDs: ["new"])]
        )
        XCTAssertEqual(updates, [reference("added"), reference("removed"), reference("replaced")])
    }

    func testUnloadedApprovalsDoNotMeanPreviouslyPendingCardsWereRemoved() {
        XCTAssertTrue(compare(
            ["a": .init(revision: 1, pendingApprovalIDs: ["old"])],
            ["a": .init(revision: 1)]
        ).isEmpty)
    }

    func testFirstLoadedPendingApprovalIsAnUpdateButEmptyCardsAreNot() {
        XCTAssertEqual(compare(
            ["a": .init(revision: 1), "b": .init(revision: 1)],
            ["a": .init(revision: 1, pendingApprovalIDs: ["pending"]),
             "b": .init(revision: 1, pendingApprovalIDs: [])]
        ), [reference("a")])
    }

    func testUnattachedApprovalStatusChangesIdentifySessionWithoutCardIDs() {
        XCTAssertEqual(compare(
            ["a": .init(revision: 1, status: "idle"),
             "b": .init(revision: 1, status: "waiting_approval"),
             "c": .init(revision: 1, status: "running")],
            ["a": .init(revision: 1, status: "waiting_approval"),
             "b": .init(revision: 1, status: "idle"),
             "c": .init(revision: 1, status: "idle")]
        ), [reference("a"), reference("b")])
    }

    func testUnchangedAndRemovedSessionsDoNotProduceUpdates() {
        XCTAssertTrue(compare(
            ["a": .init(revision: 1, pendingApprovalIDs: ["pending"]), "gone": .init(revision: 1)],
            ["a": .init(revision: 1, pendingApprovalIDs: ["pending"])]
        ).isEmpty)
    }

    func testRevisionAndApprovalChangesForSameRowCountOnce() {
        XCTAssertEqual(compare(
            ["a": .init(revision: 1, pendingApprovalIDs: [])],
            ["a": .init(revision: 2, pendingApprovalIDs: ["pending"])]
        ).count, 1)
    }

    func testHostSwitchRejectsEvenIdenticalSessionIDs() {
        let baseline = ForegroundResumeSnapshot(hostID: hostA, sessions: ["a": .init(revision: 1)])
        let current = ForegroundResumeSnapshot(hostID: hostB, sessions: ["a": .init(revision: 2)])
        XCTAssertTrue(ForegroundResumePolicy.updates(baseline: baseline, current: current).isEmpty)
        XCTAssertNotEqual(reference("a"), HostSessionReference(hostID: hostB, sessionID: "a"))
    }

    func testRepeatedActiveCallbacksConsumeBaselineAndNotifyOnlyOnce() throws {
        var tracker = ForegroundResumeTracker()
        tracker.capture(ForegroundResumeSnapshot(hostID: hostA, sessions: [:]))
        let ticket = try XCTUnwrap(tracker.beginResume())
        XCTAssertNil(tracker.beginResume())
        let current = ForegroundResumeSnapshot(hostID: hostA, sessions: ["a": .init(revision: 1)])
        XCTAssertEqual(tracker.complete(ticket, current: current), [reference("a")])
        XCTAssertTrue(tracker.complete(ticket, current: current).isEmpty)
    }

    func testNewBackgroundCycleInvalidatesOldInFlightCompletion() throws {
        var tracker = ForegroundResumeTracker()
        let baseline = ForegroundResumeSnapshot(hostID: hostA, sessions: [:])
        tracker.capture(baseline)
        let old = try XCTUnwrap(tracker.beginResume())
        tracker.capture(baseline)
        let current = ForegroundResumeSnapshot(hostID: hostA, sessions: ["a": .init(revision: 1)])
        XCTAssertTrue(tracker.complete(old, current: current).isEmpty)
        let next = try XCTUnwrap(tracker.beginResume())
        XCTAssertEqual(tracker.complete(next, current: current), [reference("a")])
    }

    func testIdentityInvalidationDiscardsInFlightAndPendingBaseline() throws {
        var tracker = ForegroundResumeTracker()
        tracker.capture(ForegroundResumeSnapshot(hostID: hostA, sessions: [:]))
        let old = try XCTUnwrap(tracker.beginResume())
        tracker.capture(nil)
        XCTAssertNil(tracker.beginResume())
        XCTAssertTrue(tracker.complete(old, current: ForegroundResumeSnapshot(
            hostID: hostA, sessions: ["a": .init(revision: 1)]
        )).isEmpty)
    }

    func testFailedResumeRetriesOriginalBaselineAndNotifiesOnlyOnce() throws {
        var tracker = ForegroundResumeTracker()
        let baseline = ForegroundResumeSnapshot(hostID: hostA, sessions: ["a": .init(revision: 1)])
        tracker.capture(baseline)
        let failed = try XCTUnwrap(tracker.beginResume())
        XCTAssertNil(tracker.beginResume())
        tracker.retry(failed)
        XCTAssertTrue(tracker.hasPendingResume)

        let retried = try XCTUnwrap(tracker.beginResume())
        XCTAssertNotEqual(failed.id, retried.id)
        XCTAssertEqual(retried.baseline, baseline)
        let current = ForegroundResumeSnapshot(hostID: hostA, sessions: ["a": .init(revision: 2)])
        XCTAssertEqual(tracker.complete(retried, current: current), [reference("a")])
        XCTAssertFalse(tracker.hasPendingResume)
        XCTAssertNil(tracker.beginResume())
        XCTAssertTrue(tracker.complete(retried, current: current).isEmpty)
    }

    func testFailureFollowedByAnotherBackgroundCycleKeepsEarliestBaseline() throws {
        var tracker = ForegroundResumeTracker()
        let original = ForegroundResumeSnapshot(hostID: hostA, sessions: ["a": .init(revision: 1)])
        tracker.capture(original)
        let failed = try XCTUnwrap(tracker.beginResume())
        tracker.retry(failed)
        let refreshed = ForegroundResumeSnapshot(hostID: hostA, sessions: ["a": .init(revision: 2)])
        tracker.capture(refreshed)

        let retried = try XCTUnwrap(tracker.beginResume())
        XCTAssertEqual(retried.baseline, original)
        XCTAssertEqual(tracker.complete(retried, current: refreshed), [reference("a")])
    }

    func testApprovalUpdateWithoutRevisionChangeSurvivesFailedResume() throws {
        var tracker = ForegroundResumeTracker()
        tracker.capture(ForegroundResumeSnapshot(hostID: hostA, sessions: [
            "a": .init(revision: 1, pendingApprovalIDs: []),
        ]))
        let failed = try XCTUnwrap(tracker.beginResume())
        tracker.retry(failed)
        let retried = try XCTUnwrap(tracker.beginResume())
        XCTAssertEqual(tracker.complete(retried, current: ForegroundResumeSnapshot(
            hostID: hostA, sessions: ["a": .init(revision: 1, pendingApprovalIDs: ["pending"])]
        )), [reference("a")])
    }

    func testLateCompletionAndFailureCannotReplaceRetryAttempt() throws {
        var tracker = ForegroundResumeTracker()
        tracker.capture(ForegroundResumeSnapshot(hostID: hostA, sessions: [:]))
        let failed = try XCTUnwrap(tracker.beginResume())
        tracker.retry(failed)
        let retried = try XCTUnwrap(tracker.beginResume())
        let current = ForegroundResumeSnapshot(hostID: hostA, sessions: ["a": .init(revision: 2)])
        XCTAssertTrue(tracker.complete(failed, current: current).isEmpty)
        tracker.retry(failed)
        XCTAssertNil(tracker.beginResume())
        XCTAssertEqual(tracker.complete(retried, current: current), [reference("a")])
    }

    func testOpenedSessionIsNotRemarkedByInFlightResume() throws {
        var tracker = ForegroundResumeTracker()
        tracker.capture(ForegroundResumeSnapshot(hostID: hostA, sessions: [
            "a": .init(revision: 1), "b": .init(revision: 1),
        ]))
        let ticket = try XCTUnwrap(tracker.beginResume())
        tracker.open(hostID: hostA, sessionID: "a")
        tracker.open(hostID: hostB, sessionID: "b")
        let updates = tracker.complete(ticket, current: ForegroundResumeSnapshot(hostID: hostA, sessions: [
            "a": .init(revision: 2), "b": .init(revision: 2),
        ]))
        XCTAssertEqual(updates, [reference("b")])
    }

    func testOpenedSessionStaysReadAcrossRetryButCanUpdateNextCycle() throws {
        var tracker = ForegroundResumeTracker()
        let baseline = ForegroundResumeSnapshot(hostID: hostA, sessions: ["a": .init(revision: 1)])
        tracker.capture(baseline)
        let failed = try XCTUnwrap(tracker.beginResume())
        tracker.open(hostID: hostA, sessionID: "a")
        tracker.retry(failed)
        let current = ForegroundResumeSnapshot(hostID: hostA, sessions: ["a": .init(revision: 2)])
        tracker.capture(current)
        let retried = try XCTUnwrap(tracker.beginResume())
        XCTAssertTrue(tracker.complete(retried, current: current).isEmpty)

        tracker.capture(current)
        let next = try XCTUnwrap(tracker.beginResume())
        XCTAssertEqual(tracker.complete(next, current: ForegroundResumeSnapshot(
            hostID: hostA, sessions: ["a": .init(revision: 3)]
        )), [reference("a")])
    }

    func testInvalidatedFailureCannotResurrectBaseline() throws {
        var tracker = ForegroundResumeTracker()
        tracker.capture(ForegroundResumeSnapshot(hostID: hostA, sessions: [:]))
        let ticket = try XCTUnwrap(tracker.beginResume())
        tracker.capture(nil)
        tracker.retry(ticket)
        XCTAssertFalse(tracker.hasPendingResume)
        XCTAssertNil(tracker.beginResume())
    }

    func testWrongHostDoesNotConsumeBaseline() throws {
        var tracker = ForegroundResumeTracker()
        tracker.capture(ForegroundResumeSnapshot(hostID: hostA, sessions: [:]))
        let ticket = try XCTUnwrap(tracker.beginResume())
        XCTAssertTrue(tracker.complete(ticket, current: ForegroundResumeSnapshot(
            hostID: hostB, sessions: ["a": .init(revision: 2)]
        )).isEmpty)
        tracker.retry(ticket)
        XCTAssertTrue(tracker.hasPendingResume)
        XCTAssertNotNil(tracker.beginResume())
    }

    func testOpeningSessionClearsOnlyItsHostAndRow() {
        var markers = ForegroundSessionUpdateMarkers()
        let otherHostSameSession = HostSessionReference(hostID: hostB, sessionID: "a")
        markers.record([reference("a"), reference("b"), otherHostSameSession])
        markers.open(hostID: hostA, sessionID: "a")
        XCTAssertEqual(markers.sessions, [reference("b"), otherHostSameSession])
        markers.removeHost(hostA)
        XCTAssertEqual(markers.sessions, [otherHostSameSession])
    }

    func testLaterResumeCanMarkPreviouslyOpenedSessionAgain() {
        var markers = ForegroundSessionUpdateMarkers()
        markers.record([reference("a")])
        markers.open(hostID: hostA, sessionID: "a")
        XCTAssertFalse(markers.contains(reference("a")))
        markers.record(compare(["a": .init(revision: 1)], ["a": .init(revision: 2)]))
        XCTAssertTrue(markers.contains(reference("a")))
    }

    private func reference(_ sessionID: String) -> HostSessionReference {
        HostSessionReference(hostID: hostA, sessionID: sessionID)
    }

    private func compare(
        _ baseline: [String: ForegroundSessionState],
        _ current: [String: ForegroundSessionState]
    ) -> Set<HostSessionReference> {
        ForegroundResumePolicy.updates(
            baseline: .init(hostID: hostA, sessions: baseline),
            current: .init(hostID: hostA, sessions: current)
        )
    }
}
