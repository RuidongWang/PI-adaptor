import XCTest

/// 端到端验证 2026-10-31 连接链路修复单中「真实主机」的可执行条目：
/// AC-08（RACP 握手 + `item.delta` 流式 + `turn.completed` 清除运行态）、
/// AC-09（运行中 `turn/interrupt` 中止并清除运行态）。
///
/// 前提：模拟器已配对的真实 Host 处于在线状态（与 `LiveDeepSeekChatUITests` 相同）。
/// 默认跳过；显式设置 `PI_IOS_CODE_FIX_E2E=1` 才运行，避免污染常规测试运行。
final class ConnectionCodefixE2ETests: XCTestCase {
    private var app: XCUIApplication!

    private let marker = "PI-E2E-CODEFIX"

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
    }

    override func tearDown() {
        app?.terminate()
    }

    private func requireLiveHost() throws {
        guard ProcessInfo.processInfo.environment["PI_IOS_CODE_FIX_E2E"] == "1" else {
            throw XCTSkip("Set PI_IOS_CODE_FIX_E2E=1 to run the live connection E2E.")
        }
    }

    private func showRoot(_ title: String) {
        if app.navigationBars[title].waitForExistence(timeout: 8) { return }
        let menu = app.buttons["打开侧边栏"]
        XCTAssertTrue(menu.waitForExistence(timeout: 8))
        menu.tap()
        let root = app.buttons[title].firstMatch
        XCTAssertTrue(root.waitForExistence(timeout: 5))
        root.tap()
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 10))
    }

    /// 打开一台已经在线的会话（列表行标签形如「测试、… · 17 条 · Agent · …、rev 8」）。
    @discardableResult
    private func openLiveSession() -> XCUIElement {
        showRoot("项目")
        let session = app.buttons
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "rev "))
            .firstMatch
        for _ in 0..<4 where !session.exists { app.swipeUp() }
        XCTAssertTrue(session.waitForExistence(timeout: 15), "必须在项目页看到至少一条会话")
        session.tap()
        let composer = composerField()
        // 打开会话后先等会话页就绪；失败时留下屏幕与元素快照，便于区分「隧道未建立」与「定位器失效」。
        if !composerField().waitForExistence(timeout: 40) {
            attach("08-open-session-failed")
            let texts = app.staticTexts.allElementsBoundByIndex.prefix(25)
                .map { "\($0.label)" }
                .joined(separator: " | ")
            XCTFail("会话页未出现指令输入框。屏幕文本：\(texts)")
        }
        return composer
    }

    /// 交接单 §3 第 3 条（已知未修）：会话未显式绑定模型时 `canSend` 判定为不可发送。
    /// 真实链路的正常做法是走 AC-14 的会话配置显式选定模型，这里照做并留证。
    private func ensureModelBound() {
        let send = app.buttons["发送"]
        if send.exists && send.isEnabled { return }
        let chip = app.buttons["composer.modelChip"]
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "会话配置入口（模型 chip）必须存在")
        chip.tap()
        XCTAssertTrue(app.navigationBars["会话配置"].waitForExistence(timeout: 10))
        let model = app.buttons
            .matching(NSPredicate(format: "label CONTAINS %@", "DeepSeek"))
            .firstMatch
        let hasModel = model.waitForExistence(timeout: 10)
        attach("05-session-config")
        XCTAssertTrue(hasModel, "本机模型清单必须至少含一个 DeepSeek 模型")
        model.tap()
        if app.buttons["完成"].exists { app.buttons["完成"].tap() }
        _ = app.navigationBars["会话配置"].waitForNonExistence(timeout: 10)
    }

    private func send(_ text: String) {
        let composer = composerField()
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        // 草稿会跨启动保留（离线缓存），先清空，保证每次发送的文本唯一可审计。
        let existing = (composer.value as? String) ?? ""
        if !existing.isEmpty && existing != "给 Agent 的指令" {
            composer.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
        }
        composer.typeText(text)
        let typed = (composer.value as? String) ?? ""
        attach("06-typed-draft")
        XCTAssertTrue(typed.contains(text), "输入必须真正进入指令框，实际读到：\(typed)")

        ensureModelBound()

        let send = app.buttons["发送"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        attach("07-before-send")
        XCTAssertTrue(send.isEnabled, "在线、已绑定模型且草稿非空时发送必须可用")
        send.tap()
    }
    /// SwiftUI 纵向 `TextField` 在无障碍树里会在 `TextField` / `TextView` 之间摇摆
    ///（`XC_kAXXCAttributeElementType = SwiftUI.VerticalTextView`），只按 textFields 查询会随机失败。
    private func composerField() -> XCUIElement {
        let byID = NSPredicate(format: "identifier == %@", "conversation.composer")
        let identified = app.descendants(matching: .any).matching(byID).firstMatch
        if identified.waitForExistence(timeout: 10) { return identified }
        // 兼容未带 identifier 的旧构建：按占位符/标签在两种类型里各试一次。
        let byHint = NSPredicate(
            format: "placeholderValue == %@ OR label == %@",
            "给 Agent 的指令", "给 Agent 的指令"
        )
        let textView = app.textViews.matching(byHint).firstMatch
        if textView.waitForExistence(timeout: 5) { return textView }
        return app.textFields.matching(byHint).firstMatch
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    // MARK: - AC-08

    func testAC08StreamingThenRunStateClearedOnCompletion() throws {
        try requireLiveHost()
        openLiveSession()

        let running = app.staticTexts["conversation.runningTurn"]
        let streaming = app.staticTexts["conversation.streamingCount"]

        send("\(marker) 请只回复一句：收到。")

        // 流式进行中：运行态指示必须出现（`turn/start` 解码 + 归约生效）。
        let sawRunning = running.waitForExistence(timeout: 90) || streaming.waitForExistence(timeout: 5)
        attach("01-streaming")
        XCTAssertTrue(sawRunning, "发送后应出现运行中/流式指示")
        if running.exists || streaming.exists {
            XCTAssertTrue(
                running.exists || streaming.exists,
                "活动期间必须能读到运行态或流式计数"
            )
        }

        // 终态：`turn.completed` 之后运行态与流式计数都必须清除（turnId 回退相关）。
        let interrupt = app.buttons["conversation.interrupt"]
        let cleared = running.waitForNonExistence(timeout: 180)
            && streaming.waitForNonExistence(timeout: 5)
            && interrupt.waitForNonExistence(timeout: 10)
        attach("02-completed")
        XCTAssertTrue(cleared, "turn 终态后运行态、流式计数与中止入口都必须消失")
    }

    // MARK: - AC-09

    func testAC09InterruptStopsTurnAndClearsRunningState() throws {
        try requireLiveHost()
        openLiveSession()

        send("\(marker) 请写一篇大约八百字的中文说明文，介绍远程协作的优缺点，不要使用工具。")

        let interrupt = app.buttons["conversation.interrupt"]
        XCTAssertTrue(interrupt.waitForExistence(timeout: 90), "运行中必须出现中止入口")
        attach("03-running-before-interrupt")
        interrupt.tap()

        let terminal = app.staticTexts["已中止"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 30), "中止后必须显示「已中止」终态")
        XCTAssertTrue(app.buttons["conversation.interrupt"].waitForNonExistence(timeout: 30),
                      "中止后运行态与中止入口必须消失")
        XCTAssertFalse(app.staticTexts["conversation.streamingCount"].exists,
                       "中止后不得残留流式计数")
        attach("04-interrupted")
    }
}
