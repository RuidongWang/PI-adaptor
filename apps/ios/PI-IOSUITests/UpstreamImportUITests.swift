import XCTest

final class UpstreamImportUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchEnvironment["PI_IOS_UI_FIXTURE_SCENARIO"] = "online-upstream-import"
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    func testFirstUpstreamSyncDefaultsProjectsAndSessionsToArchived() {
        if app.buttons["sidebar.close"].waitForExistence(timeout: 2) {
            app.buttons["sidebar.close"].tap()
            XCTAssertTrue(app.buttons["sidebar.close"].waitForNonExistence(timeout: 5))
        }
        app.buttons["打开侧边栏"].tap()
        XCTAssertTrue(app.buttons["项目"].waitForExistence(timeout: 5))
        app.buttons["项目"].tap()
        XCTAssertTrue(app.navigationBars["项目"].waitForExistence(timeout: 5))

        let archivedP1 = app.descendants(matching: .any)["projects.archived.P1"]
        let archivedP2 = app.descendants(matching: .any)["projects.archived.P2"]
        XCTAssertTrue(archivedP1.waitForExistence(timeout: 8))
        XCTAssertTrue(archivedP2.exists)
        XCTAssertFalse(app.buttons["projects.row.P1"].exists)
        XCTAssertFalse(app.buttons["projects.row.P2"].exists)
        XCTAssertTrue(app.staticTexts["还没有项目"].exists)

        archivedP1.tap()
        XCTAssertTrue(app.buttons["projects.row.P1"].waitForExistence(timeout: 5))
        app.buttons["projects.details.P1"].tap()
        XCTAssertTrue(app.buttons["projectDetail.restoreSession.S1"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["projectDetail.restoreSession.S2"].exists)
        app.buttons["projectDetail.restoreSession.S1"].tap()
        XCTAssertTrue(app.navigationBars["Alpha One"].waitForExistence(timeout: 8))
    }
}
