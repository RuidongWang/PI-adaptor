import XCTest

@testable import PIiOSNet

final class ReconnectBackoffTests: XCTestCase {
    func testContractSchedule() {
        let backoff = ReconnectBackoff()
        XCTAssertEqual(backoff.delay(forAttempt: 1), 1)
        XCTAssertEqual(backoff.delay(forAttempt: 2), 2)
        XCTAssertEqual(backoff.delay(forAttempt: 3), 4)
        XCTAssertEqual(backoff.delay(forAttempt: 4), 8)
    }

    func testDoublesThenCapsAt30Seconds() {
        let backoff = ReconnectBackoff()
        XCTAssertEqual(backoff.delay(forAttempt: 5), 16)
        XCTAssertEqual(backoff.delay(forAttempt: 6), 30)
        XCTAssertEqual(backoff.delay(forAttempt: 20), 30)
    }

    func testOutOfRangeAttempts() {
        let backoff = ReconnectBackoff()
        XCTAssertEqual(backoff.delay(forAttempt: 0), 0)
        XCTAssertEqual(backoff.delay(forAttempt: -3), 0)
    }
}
