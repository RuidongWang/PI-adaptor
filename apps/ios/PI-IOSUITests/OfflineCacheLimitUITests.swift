import XCTest

final class OfflineCacheLimitUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchEnvironment["PI_IOS_UI_FIXTURE_SCENARIO"] = "offline-cache-205"
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    func testOfflineHistoryKeepsOnlyNewestTwoHundredItems() {
        let row = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "fixture-cache-session")
        ).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        row.tap()
        XCTAssertTrue(app.staticTexts["离线只读 · 缓存可能已过期"].waitForExistence(timeout: 5))

        XCTAssertFalse(app.staticTexts["Cache item 005"].exists, "最旧 5 条应被缓存上限淘汰")
        XCTAssertTrue(app.staticTexts["Cache item 006"].exists)
        XCTAssertTrue(app.staticTexts["Cache item 205"].exists)
    }
}
