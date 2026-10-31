import XCTest

final class LiveDeepSeekChatUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    func testLiveDeepSeekChatWithRotatedKey() throws {
        guard ProcessInfo.processInfo.environment["PI_IOS_DEEPSEEK_CHAT"] == "1" else {
            throw XCTSkip("Set PI_IOS_DEEPSEEK_CHAT=1 after importing the rotated DeepSeek key.")
        }

        showRoot("项目")
        let session = app.buttons
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "rev "))
            .firstMatch
        for _ in 0..<4 where !session.exists {
            app.swipeUp()
        }
        XCTAssertTrue(session.waitForExistence(timeout: 10))
        session.tap()

        let modelChip = app.buttons["composer.modelChip"]
        XCTAssertTrue(modelChip.waitForExistence(timeout: 15))
        modelChip.tap()
        XCTAssertTrue(app.navigationBars["会话配置"].waitForExistence(timeout: 10))

        // Which model to pick is provider-specific: DeepSeek official exposes
        // `deepseek-chat`, an older self-hosted provider exposed a different id.
        // Default to the official id; override with PI_IOS_DEEPSEEK_MODEL.
        let modelName =
            ProcessInfo.processInfo.environment["PI_IOS_DEEPSEEK_MODEL"] ?? "deepseek-chat"
        let model = app.buttons
            .matching(NSPredicate(format: "label CONTAINS %@", modelName))
            .firstMatch
        XCTAssertTrue(
            model.waitForExistence(timeout: 10),
            "The DeepSeek provider must expose a model matching \"\(modelName)\" (set PI_IOS_DEEPSEEK_MODEL to change)."
        )
        model.tap()
        app.buttons["完成"].tap()
        XCTAssertTrue(app.navigationBars["会话配置"].waitForNonExistence(timeout: 10))

        let marker = "LIVE-DEEPSEEK-KEY-OK"
        // Prefer the stable identifier: the composer's accessibility type flips
        // between TextField/TextView, so a label-only query is flaky.
        let composer = app.textFields["conversation.composer"].exists
            ? app.textFields["conversation.composer"]
            : app.textFields["给 Agent 的指令"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        composer.typeText("Reply with exactly \(marker)")
        let send = app.buttons["发送"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        XCTAssertTrue(send.isEnabled)
        send.tap()

        XCTAssertTrue(
            app.staticTexts
                .matching(NSPredicate(format: "label CONTAINS %@", marker))
                .firstMatch
                .waitForExistence(timeout: 90),
            "The rotated DeepSeek key must produce a real assistant response."
        )
    }

    private func showRoot(_ title: String) {
        if app.navigationBars[title].waitForExistence(timeout: 8) {
            return
        }
        let menu = app.buttons["打开侧边栏"]
        XCTAssertTrue(menu.waitForExistence(timeout: 8))
        menu.tap()
        let root = app.buttons[title].firstMatch
        XCTAssertTrue(root.waitForExistence(timeout: 5))
        root.tap()
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 10))
    }
}
