import XCTest

final class InterruptLatencyUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchEnvironment["PI_IOS_UI_FIXTURE_SCENARIO"] = "online-model-config"
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["sidebar.session.S2"].waitForExistence(timeout: 8))
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    func testInterruptResultIsVisibleWithinTwoSeconds() {
        app.buttons["sidebar.session.S2"].tap()
        XCTAssertTrue(app.navigationBars["Alpha Two"].waitForExistence(timeout: 5))

        let interrupt = app.buttons["conversation.interrupt"]
        XCTAssertTrue(interrupt.waitForExistence(timeout: 5))
        XCTAssertTrue(interrupt.isEnabled)
        XCTAssertTrue(app.staticTexts["conversation.streamingCount"].exists)

        let started = Date()
        interrupt.tap()

        let terminal = app.staticTexts["已中止"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 2))
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 2)
        XCTAssertTrue(interrupt.waitForNonExistence(timeout: 1))
        XCTAssertFalse(app.staticTexts["conversation.streamingCount"].exists)
    }
}
