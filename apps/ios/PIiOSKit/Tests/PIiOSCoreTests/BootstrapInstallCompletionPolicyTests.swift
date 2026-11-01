import XCTest

@testable import PIiOSCore

final class BootstrapInstallCompletionPolicyTests: XCTestCase {
    func testPersistenceFailureIsNeverSuccess() {
        XCTAssertEqual(
            BootstrapInstallCompletionPolicy.disposition(
                persisted: false,
                saveError: "disk full"
            ),
            .failed(reason: "disk full")
        )
        XCTAssertEqual(
            BootstrapInstallCompletionPolicy.disposition(
                persisted: false,
                saveError: nil
            ),
            .failed(reason: "无法保存本机服务器安装记录")
        )
    }

    func testPersistedInstallIsSuccess() {
        XCTAssertEqual(
            BootstrapInstallCompletionPolicy.disposition(
                persisted: true,
                saveError: "ignored"
            ),
            .succeeded
        )
    }
}
