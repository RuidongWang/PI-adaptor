import Foundation
import XCTest
@testable import PIiOSCore

final class SessionOrderingPolicyTests: XCTestCase {
    func testPinnedFirstThenRecentActivity() {
        let now = Date()
        let ids = ["a", "b", "c", "d"]
        let result = SessionOrderingPolicy.orderedIDs(
            ids,
            pinnedOrders: ["a": 1, "d": 0],
            lastActivity: [
                "a": now.addingTimeInterval(-10),
                "b": now,
                "c": now.addingTimeInterval(-20),
            ]
        )
        XCTAssertEqual(result, ["d", "a", "b", "c"])
    }

    func testMovePinnedOnlyChangesPinOrder() {
        let orders = ["a": 0, "b": 1, "c": 2]
        let moved = SessionOrderingPolicy.movePinned(
            ["a", "b", "c"],
            pinnedOrders: orders,
            sourceID: "c",
            before: "a"
        )
        XCTAssertEqual(moved, ["c": 0, "a": 1, "b": 2])
        XCTAssertEqual(
            SessionOrderingPolicy.movePinned(
                ["a", "b", "c"],
                pinnedOrders: orders,
                sourceID: "a",
                before: "a"
            ),
            orders
        )
    }

    func testMovePinnedForwardUsesIndexAfterRemoval() {
        let moved = SessionOrderingPolicy.movePinned(
            ["a", "b", "c"],
            pinnedOrders: ["a": 0, "b": 1, "c": 2],
            sourceID: "a",
            before: "c"
        )

        XCTAssertEqual(moved, ["b": 0, "a": 1, "c": 2])
    }
}
