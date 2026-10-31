import XCTest

final class ModelConfigChipUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchEnvironment["PI_IOS_UI_FIXTURE_SCENARIO"] = "online-model-config"
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["sidebar.session.S1"].waitForExistence(timeout: 8))
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    func testModelAndThinkingChipsFollowPersistedBinding() {
        app.buttons["sidebar.session.S1"].tap()
        let modelChip = app.buttons["composer.modelChip"]
        XCTAssertTrue(modelChip.waitForExistence(timeout: 8))
        XCTAssertTrue(modelChip.label.contains("Alpha Pro"))
        let thinkingChip = app.buttons["composer.thinkingChip"]
        XCTAssertTrue(thinkingChip.exists)
        XCTAssertTrue(thinkingChip.label.contains("low"))

        modelChip.tap()
        XCTAssertTrue(app.navigationBars["会话配置"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Alpha Pro"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Beta Basic"].exists)
        XCTAssertTrue(app.staticTexts["思考档位"].exists)
        app.buttons["完成"].tap()

        app.buttons["打开侧边栏"].tap()
        app.buttons["sidebar.session.S2"].tap()
        XCTAssertTrue(app.navigationBars["Alpha Two"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "当前 turn 仍在运行")
            ).firstMatch.waitForExistence(timeout: 5)
        )
        XCTAssertTrue(modelChip.waitForExistence(timeout: 5))
        XCTAssertTrue(modelChip.label.contains("Beta Basic"))
        XCTAssertFalse(app.buttons["composer.thinkingChip"].exists, "无档位模型不得显示档位 chip")
        XCTAssertFalse(modelChip.isEnabled)
    }
}
