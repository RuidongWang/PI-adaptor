import XCTest

@testable import PIiOSCore

final class HostPortResolverTests: XCTestCase {
    func testResolvePicksFirstValidPort() {
        let stdout = "19445\n44271\n"
        XCTAssertEqual(HostPortResolver.resolve(stdout: stdout), 19445)
    }

    func testResolveSkipsInvalidAndOutOfRangeLines() {
        let stdout = "not-a-port\n0\n70000\n 8080 \n"
        XCTAssertEqual(HostPortResolver.resolve(stdout: stdout), 8080)
    }

    func testResolveReturnsNilWhenNothingUsable() {
        XCTAssertNil(HostPortResolver.resolve(stdout: "\n  \nnope\n"))
    }

    func testProbeCommandLooksForProcessAndUnitPorts() {
        XCTAssertTrue(HostPortResolver.probeCommand.contains("--port"))
        XCTAssertTrue(HostPortResolver.probeCommand.contains("systemctl --user show pi-host.service"))
        // The v2 host is `pi-adaptor`; the legacy upstream host stays `pi-host.js`.
        XCTAssertTrue(HostPortResolver.probeCommand.contains("pi-adaptor"))
        XCTAssertTrue(HostPortResolver.probeCommand.contains("pi-host\\.js"))
    }
}
