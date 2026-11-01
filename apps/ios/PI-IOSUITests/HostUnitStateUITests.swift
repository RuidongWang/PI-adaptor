import XCTest

final class HostUnitStateUITests: XCTestCase {
    private let app = XCUIApplication()

    override func tearDownWithError() throws {
        app.terminate()
    }

    func testActiveUnitShowsActiveWithoutRestartCommand() {
        launch(scenario: "online-host-unit-active")
        let row = systemdRow()
        XCTAssertTrue(row.label.contains("active"))
        XCTAssertFalse(row.label.contains("inactive"))
        XCTAssertTrue(app.staticTexts["在线"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["settings.restartCommand"].exists)
    }

    func testStoppedUnitShowsInactiveAndRestartCommand() {
        launch(scenario: "online-host-unit-stopped")
        let row = systemdRow()
        XCTAssertTrue(row.label.contains("inactive"))
        XCTAssertTrue(app.staticTexts["未连接"].waitForExistence(timeout: 5))
        let restart = app.descendants(matching: .any)["settings.restartCommand"]
        XCTAssertTrue(restart.waitForExistence(timeout: 5))
        XCTAssertTrue(restart.label.contains("systemctl --user restart pi-adaptor.service"))
    }

    private func launch(scenario: String) {
        app.launchEnvironment["PI_IOS_UI_FIXTURE_SCENARIO"] = scenario
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["设置"].waitForExistence(timeout: 8))
        app.buttons["设置"].tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
    }

    private func systemdRow() -> XCUIElement {
        let row = app.descendants(matching: .any)["settings.hostUnit"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let settled = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "NOT (label CONTAINS[c] %@) AND NOT (label CONTAINS[c] %@)",
                "查询中",
                "未查询"
            ),
            object: row
        )
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 5), .completed)
        return row
    }

}
