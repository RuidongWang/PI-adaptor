import XCTest

/// 回归：长历史下「工具一直显示执行中」的真实根因。
///
/// 审批卡片曾是滚动内容的第一项，而自动滚动一律滚到 `thread-bottom`：历史一长就把卡片顶到
/// 视口上方上千点，用户看不到卡片、点不了「允许一次」，工具就永远停在「工具执行中…」。
/// 现在卡片固定在滚动区之上；夹具 `online-long-history-pending-approval` 用 40 条历史
/// 加 1 张待审批卡片复刻现场。
final class PendingApprovalVisibilityUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchEnvironment["PI_IOS_UI_FIXTURE_SCENARIO"] = "online-long-history-pending-approval"
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["sidebar.session.S1"].waitForExistence(timeout: 8))
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    func testPendingApprovalCardStaysVisibleWhileScrollingHistory() {
        app.buttons["sidebar.session.S1"].tap()
        XCTAssertTrue(app.buttons["sidebar.close"].waitForNonExistence(timeout: 5))

        let allowOnce = app.buttons["允许一次"]
        XCTAssertTrue(allowOnce.waitForExistence(timeout: 15), "待审批卡片必须存在")
        let window = app.windows.firstMatch.frame
        XCTAssertTrue(
            window.intersects(allowOnce.frame),
            "打开会话后审批卡必须在视口里，否则用户只看到工具一直「执行中」"
        )

        // 模拟用户翻历史：卡片必须一直留在视口里（它是工具唯一的解锁入口）。
        app.swipeUp()
        app.swipeUp()
        XCTAssertTrue(
            window.intersects(allowOnce.frame),
            "翻历史后审批卡仍必须在视口里，不能被滚出屏幕"
        )

        // 卡片可点，且点它真的能提交决定（本用例只验证可点性，避免依赖假 Host 的响应）。
        XCTAssertTrue(allowOnce.isHittable)
    }
}
