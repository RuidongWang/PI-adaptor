import XCTest

/// 临时视觉截图测试：起会话页，抓消息流与输入条。验完即删。
final class ZZVisualShotUITests: XCTestCase {
    private let app = XCUIApplication()

    func testConversationVisualShot() throws {
        continueAfterFailure = false
        app.launchEnvironment["PI_IOS_UI_FIXTURE_SCENARIO"] = "online-reading-two-sessions"
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()

        // 关掉系统通知弹窗（若出现）。
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["允许", "Allow", "好", "OK"] {
            let b = springboard.buttons[label]
            if b.waitForExistence(timeout: 1.5) { b.tap(); break }
        }

        XCTAssertTrue(app.buttons["sidebar.session.S1"].waitForExistence(timeout: 8))
        app.buttons["sidebar.session.S1"].tap()
        XCTAssertTrue(app.navigationBars["Fixture S1 Alpha"].waitForExistence(timeout: 8))

        // 滚到最新，露出输入条。
        for _ in 0..<25 where !app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Reading S1 item 040")).firstMatch.isHittable {
            app.scrollViews.firstMatch.swipeUp()
        }
        sleep(1)

        let shot = XCUIScreen.main.screenshot()
        let attach = XCTAttachment(screenshot: shot)
        attach.name = "conversation-visual"
        attach.lifetime = .keepAlways
        add(attach)
        try shot.pngRepresentation.write(to: URL(fileURLWithPath: "/tmp/piios_conversation.png"))
    }
}
