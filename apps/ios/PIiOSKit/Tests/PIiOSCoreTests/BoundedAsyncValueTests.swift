import Foundation
import XCTest

@testable import PIiOSCore

final class BoundedAsyncValueTests: XCTestCase {
    func testDeadlineReturnsWhenOperationIgnoresCancellation() async {
        let clock = ContinuousClock()
        let started = clock.now
        let value = await boundedAsyncValue(seconds: 0.08) {
            // This sleep is not reached by the deadline race. It simulates a
            // non-cancellable network close that continues after the caller is
            // released and must not hold the test or install path hostage.
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            return "late"
        }
        XCTAssertNil(value)
        XCTAssertLessThan(started.duration(to: clock.now), .seconds(1))
    }

    func testCompletedValueWinsBeforeDeadline() async {
        let value = await boundedAsyncValue(seconds: 1) { "ready" }
        XCTAssertEqual(value, "ready")
    }
}
