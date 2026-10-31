import XCTest

/// Synthetic catalog only: these tests never attach a session or contact a Host.
/// Long-press reorder needs manual verification: title/grip/slow-drag probes did
/// not change order. SessionDragPolicyTests cover the 500 ms / 8 pt contract only.
final class OnlineSidebarUITests: XCTestCase {
    private let app = XCUIApplication()
    private var group: XCUIElement { app.buttons["sidebar.project.fixture-online-project"] }
    private var search: XCUIElement { app.textFields["搜索会话或项目"] }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchEnvironment["PI_IOS_UI_FIXTURE_SCENARIO"] = "online-two-sessions"
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(group.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Fixture Online Host"].exists)
        XCTAssertTrue(group.label.hasPrefix("Fixture Workspace，2 个会话"))
        assertOrder("S2", before: "S1")
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    func testProjectAndSessionSearchAndCollapseExpansion() {
        setSearch("Fixture Workspace")
        XCTAssertTrue(row("S1").exists)
        XCTAssertTrue(row("S2").exists)

        setSearch("ALPHA")
        XCTAssertTrue(row("S1").exists)
        XCTAssertFalse(row("S2").exists)
        XCTAssertTrue(group.label.hasPrefix("Fixture Workspace，1 个会话"))

        setSearch("no-such-fixture")
        XCTAssertFalse(group.exists)
        XCTAssertFalse(row("S1").exists)
        XCTAssertFalse(row("S2").exists)
        XCTAssertTrue(app.staticTexts["没有匹配的会话或项目。"].exists)

        setSearch("")
        group.tap()
        XCTAssertTrue(group.label.contains("已折叠"))
        XCTAssertFalse(row("S1").exists)
        XCTAssertFalse(row("S2").exists)

        // A search temporarily reveals matches without losing the collapsed setting.
        setSearch("Beta")
        XCTAssertTrue(row("S2").exists)
        XCTAssertFalse(row("S1").exists)
        setSearch("")
        XCTAssertTrue(group.label.contains("已折叠"))
        XCTAssertFalse(row("S2").exists)
        group.tap()
        XCTAssertFalse(group.label.contains("已折叠"))
        assertOrder("S2", before: "S1")
    }

    func testPinControlsKeepInsertionOrderAndUnpinRestoresActivityOrder() {
        XCTAssertEqual(pin("S1").label, "置顶会话")
        XCTAssertEqual(pin("S2").label, "置顶会话")

        pin("S1").tap()
        XCTAssertEqual(pin("S1").label, "取消置顶")
        assertOrder("S1", before: "S2")

        pin("S2").tap()
        XCTAssertEqual(pin("S2").label, "取消置顶")
        assertOrder("S1", before: "S2")

        pin("S1").tap()
        XCTAssertEqual(pin("S1").label, "置顶会话")
        assertOrder("S2", before: "S1")
        pin("S2").tap()
        XCTAssertEqual(pin("S2").label, "置顶会话")
        assertOrder("S2", before: "S1")
    }

    private func row(_ id: String) -> XCUIElement { app.buttons["sidebar.session.\(id)"] }
    private func pin(_ id: String) -> XCUIElement { app.buttons["sidebar.pin.\(id)"] }

    private func setSearch(_ text: String) {
        search.tap()
        let existing = search.value as? String ?? ""
        let count = existing == search.placeholderValue ? 0 : existing.count
        search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: count) + text)
    }

    private func assertOrder(_ first: String, before second: String, file: StaticString = #filePath, line: UInt = #line) {
        let upper = row(first)
        let lower = row(second)
        XCTAssertTrue(upper.exists, file: file, line: line)
        XCTAssertTrue(lower.exists, file: file, line: line)
        XCTAssertLessThan(upper.frame.midY, lower.frame.midY, "Expected \(first) above \(second)", file: file, line: line)
    }
}
