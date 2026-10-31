import XCTest

/// 回归：真机上「选了 key 文件无法加载进 App」。
///
/// 私钥导入的两条通道共用同一套校验（`SSHPrivateKeyFileLoader.load`）：
/// 文件选择通道（`PrivateKeyDocumentPicker` 在委托回调里复制到沙盒临时目录，不再依赖
/// file provider 的安全作用域）与粘贴兜底通道。这里验证粘贴通道的界面接线与校验失败
/// 提示；文件通道的读取/校验由 `PIiOSNetTests`（`SSHPrivateKeyFileLoader`）覆盖。
final class PrivateKeyImportUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    /// 私钥行必须同时提供「选择文件」与「粘贴」两个入口（后者是选择器读不到文件时的兜底）。
    func testPrivateKeyRowOffersPickAndPaste() throws {
        try openServersScreen()

        switchAuthKindToPrivateKey()
        XCTAssertTrue(
            app.buttons["servers.pickKey"].waitForExistence(timeout: 10),
            "私钥行必须有「选择文件」入口"
        )
        XCTAssertTrue(
            app.buttons["servers.pasteKey"].waitForExistence(timeout: 5),
            "私钥行必须有「粘贴」兜底入口"
        )
    }

    /// 粘贴通道必须走同一套校验：内容不是私钥时要给出「找不到私钥块」这类可读原因，且弹窗不关。
    func testPasteKeySheetReportsInvalidKey() throws {
        try openServersScreen()

        switchAuthKindToPrivateKey()
        let paste = app.buttons["servers.pasteKey"]
        XCTAssertTrue(paste.waitForExistence(timeout: 10), "私钥行必须有「粘贴」入口")
        paste.tap()

        let editor = app.textViews["servers.pasteKey.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "粘贴弹窗必须有输入框")
        editor.tap()
        editor.typeText("not-a-private-key")

        app.buttons["servers.pasteKey.import"].tap()

        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "私钥")).firstMatch
                .waitForExistence(timeout: 5),
            "无效内容必须显示可读的失败原因"
        )
        XCTAssertTrue(editor.exists, "校验失败时弹窗必须保持打开，方便改完再导入")
    }

    // MARK: - 导航

    /// 侧边栏 → 设置 → 添加服务器（私钥入口只在服务器表单里）。
    private func openServersScreen() throws {
        let menu = app.buttons["line.3.horizontal"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "会话页必须有侧边栏入口")
        menu.tap()
        // 侧边栏底部三个根入口：会话 / 项目 / 设置。
        let settings = app.buttons["设置"]
        XCTAssertTrue(settings.waitForExistence(timeout: 8), "侧边栏必须有「设置」入口")
        settings.tap()
        let add = app.buttons["settings.addServer"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10), "设置里必须有「添加服务器」入口")
        add.tap()
    }

    /// 新建服务器默认是「密码」认证；私钥行只在切成「私钥」后出现。
    private func switchAuthKindToPrivateKey() {
        let picker = app.buttons["认证方式"].firstMatch
        if picker.waitForExistence(timeout: 5) { picker.tap() }
        let option = app.buttons["私钥"].firstMatch
        if option.waitForExistence(timeout: 5) { option.tap() }
    }
}
