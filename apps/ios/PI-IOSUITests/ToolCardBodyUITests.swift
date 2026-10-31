import XCTest

/// 工具卡片正文（回归：卡片只显示「服务器没有返回工具输出正文。」）。
///
/// 夹具 `online-tool-result-body` 用契约 §7.2 的真实载荷形状给出两条工具条目：
/// 一条已完成（正文只在 `content.result.content[].text` 里）、一条运行中（尚无输出）。
/// 这里断言它们在真实界面里分别渲染成「正文」与「工具执行中…」。
final class ToolCardBodyUITests: XCTestCase {
    private let app = XCUIApplication()
    private let emptyBodyNotice = "服务器没有返回工具输出正文。"

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchEnvironment["PI_IOS_UI_FIXTURE_SCENARIO"] = "online-tool-result-body"
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["sidebar.session.S1"].waitForExistence(timeout: 8))
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    func testCompletedToolCardShowsResultBodyInsteadOfEmptyNotice() {
        app.buttons["sidebar.session.S1"].tap()
        XCTAssertTrue(app.buttons["sidebar.close"].waitForNonExistence(timeout: 5))

        let toggle = app.descendants(matching: .any)["toolCard.call_done.toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 8))
        XCTAssertEqual(app.staticTexts["工具 · bash"].firstMatch.exists, true, "卡片标题必须保留 tool.started 的工具名")

        toggle.tap()
        let preview = app.staticTexts["toolCard.call_done.preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 2))
        XCTAssertEqual(preview.label, "hello-from-tool")
        XCTAssertFalse(app.staticTexts[emptyBodyNotice].exists, "有正文时不得再显示空正文提示")
    }

    func testRunningToolCardSaysRunningInsteadOfEmptyNotice() {
        app.buttons["sidebar.session.S1"].tap()
        XCTAssertTrue(app.buttons["sidebar.close"].waitForNonExistence(timeout: 5))

        let toggle = app.descendants(matching: .any)["toolCard.call_running.toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 8))
        toggle.tap()

        XCTAssertTrue(app.staticTexts["工具执行中…"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.staticTexts[emptyBodyNotice].exists, "运行中的工具不能声称服务器没有返回正文")
    }
}
