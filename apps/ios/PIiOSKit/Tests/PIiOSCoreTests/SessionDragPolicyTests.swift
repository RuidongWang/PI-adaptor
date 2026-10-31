import CoreGraphics
import XCTest
@testable import PIiOSCore

final class SessionDragPolicyTests: XCTestCase {
    func testGestureContractUsesFiveHundredMillisecondsAndEightPoints() {
        XCTAssertEqual(SessionDragPolicy.longPressDuration, 0.5)
        XCTAssertEqual(SessionDragPolicy.scrollCancellationDistance, 8)
    }

    func testMovementCancelsOnlyAfterCrossingEightPoints() {
        let start = CGPoint(x: 20, y: 30)

        XCTAssertFalse(
            SessionDragPolicy.movementCancelsActivation(
                from: start,
                to: CGPoint(x: 26, y: 34)
            )
        )
        XCTAssertFalse(
            SessionDragPolicy.movementCancelsActivation(
                from: start,
                to: CGPoint(x: 28, y: 30)
            )
        )
        XCTAssertTrue(
            SessionDragPolicy.movementCancelsActivation(
                from: start,
                to: CGPoint(x: 28.01, y: 30)
            )
        )
        XCTAssertTrue(
            SessionDragPolicy.movementCancelsActivation(
                from: start,
                to: CGPoint(x: 26, y: 36)
            )
        )
    }

    func testReorderScopeContainsOnlyPinnedSessionsInSameProject() {
        let candidates = [
            SessionDragCandidate(sessionID: "a", projectID: "alpha", isPinned: true),
            SessionDragCandidate(sessionID: "b", projectID: "alpha", isPinned: false),
            SessionDragCandidate(sessionID: "c", projectID: "beta", isPinned: true),
            SessionDragCandidate(sessionID: "d", projectID: "alpha", isPinned: true),
        ]

        XCTAssertEqual(
            SessionDragPolicy.reorderableSessionIDs(from: candidates, projectID: "alpha"),
            ["a", "d"]
        )
        XCTAssertTrue(
            SessionDragPolicy.canStartDrag(
                sessionID: "a",
                candidates: candidates,
                projectID: "alpha"
            )
        )
        XCTAssertFalse(
            SessionDragPolicy.canStartDrag(
                sessionID: "b",
                candidates: candidates,
                projectID: "alpha"
            )
        )
        XCTAssertFalse(
            SessionDragPolicy.canStartDrag(
                sessionID: "c",
                candidates: candidates,
                projectID: "alpha"
            )
        )
    }

    func testDropResolutionSelectsBeforeAndAfterEdgesInsideProject() {
        let candidates = [
            SessionDragCandidate(sessionID: "a", projectID: "alpha", isPinned: true),
            SessionDragCandidate(sessionID: "b", projectID: "alpha", isPinned: true),
            SessionDragCandidate(sessionID: "c", projectID: "beta", isPinned: true),
        ]
        let frames = [
            "a": CGRect(x: 0, y: 0, width: 300, height: 60),
            "b": CGRect(x: 0, y: 60, width: 300, height: 60),
            "c": CGRect(x: 0, y: 120, width: 300, height: 60),
        ]

        XCTAssertEqual(
            SessionDragPolicy.resolveDrop(
                at: CGPoint(x: 100, y: 70),
                sourceID: "a",
                projectID: "alpha",
                candidates: candidates,
                frames: frames
            ),
            SessionDropResolution(targetID: "b", edge: .before)
        )
        XCTAssertEqual(
            SessionDragPolicy.resolveDrop(
                at: CGPoint(x: 100, y: 90),
                sourceID: "a",
                projectID: "alpha",
                candidates: candidates,
                frames: frames
            ),
            SessionDropResolution(targetID: "b", edge: .after)
        )
        XCTAssertNil(
            SessionDragPolicy.resolveDrop(
                at: CGPoint(x: 100, y: 130),
                sourceID: "a",
                projectID: "alpha",
                candidates: candidates,
                frames: frames
            )
        )
    }

    func testDraggedSessionCannotResolveAsItsOwnDropTarget() {
        let candidates = [
            SessionDragCandidate(sessionID: "a", projectID: "alpha", isPinned: true),
        ]
        let frames = [
            "a": CGRect(x: 0, y: 0, width: 300, height: 60),
        ]

        XCTAssertNil(
            SessionDragPolicy.resolveDrop(
                at: CGPoint(x: 100, y: 30),
                sourceID: "a",
                projectID: "alpha",
                candidates: candidates,
                frames: frames
            )
        )
    }

    func testRemovingPinOrderRestoresRecentActivityOrder() {
        let now = Date()
        let ids = ["older", "newer"]

        XCTAssertEqual(
            SessionOrderingPolicy.orderedIDs(
                ids,
                pinnedOrders: ["older": 0],
                lastActivity: [
                    "older": now.addingTimeInterval(-60),
                    "newer": now,
                ]
            ),
            ["older", "newer"]
        )
        XCTAssertEqual(
            SessionOrderingPolicy.orderedIDs(
                ids,
                pinnedOrders: [:],
                lastActivity: [
                    "older": now.addingTimeInterval(-60),
                    "newer": now,
                ]
            ),
            ["newer", "older"]
        )
    }
}
