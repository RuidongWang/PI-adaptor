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

    func testDefaultProbeUsesOnlyPIAdaptor() {
        XCTAssertTrue(HostPortResolver.probeCommand.contains("--port"))
        XCTAssertTrue(HostPortResolver.probeCommand.contains("systemctl --user show pi-adaptor.service"))
        XCTAssertTrue(HostPortResolver.probeCommand.contains("pi-adaptor"))
        XCTAssertFalse(HostPortResolver.probeCommand.contains("pi-host\\.js"))
        XCTAssertFalse(HostPortResolver.probeCommand.contains(".pi-desktop/pi-host"))
        XCTAssertFalse(HostPortResolver.probeCommand.contains("systemctl --user show pi-host.service"))
    }

    func testLegacyProbeIsExplicitlySeparate() {
        XCTAssertTrue(HostPortResolver.legacyProbeCommand.contains("pi-host\\.js"))
        XCTAssertTrue(HostPortResolver.legacyProbeCommand.contains("systemctl --user show pi-host.service"))
    }
}
