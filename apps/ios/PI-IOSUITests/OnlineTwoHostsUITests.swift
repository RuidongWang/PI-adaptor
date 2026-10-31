import XCTest

final class OnlineTwoHostsUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchEnvironment["PI_IOS_UI_FIXTURE_SCENARIO"] = "online-two-hosts"
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["sidebar.session.B-session"].waitForExistence(timeout: 8))
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    func testProjectSessionAndProviderContextFollowEachHost() {
        assertHost("B")
        app.buttons["sidebar.session.B-session"].tap()
        XCTAssertTrue(app.navigationBars["Host B Session"].waitForExistence(timeout: 5))
        assertModelGroup("Host B Models", absent: "Host A Models")

        openSidebar()
        switchHost(to: "A")
        assertHost("A")
        app.buttons["sidebar.session.A-session"].tap()
        XCTAssertTrue(app.navigationBars["Host A Session"].waitForExistence(timeout: 5))
        assertModelGroup("Host A Models", absent: "Host B Models")

        openSidebar()
        switchHost(to: "B")
        closeSidebar()
        XCTAssertTrue(app.navigationBars["Host B Session"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["sidebar.session.A-session"].exists)
    }

    private func assertHost(_ suffix: String) {
        XCTAssertTrue(app.staticTexts["Fixture Online Host \(suffix)"].exists)
        let project = app.buttons["sidebar.project.\(suffix)-project"]
        XCTAssertTrue(project.waitForExistence(timeout: 5))
        XCTAssertTrue(project.label.contains("当前项目"))
        XCTAssertTrue(app.buttons["sidebar.session.\(suffix)-session"].exists)
        let other = suffix == "A" ? "B" : "A"
        XCTAssertFalse(app.buttons["sidebar.project.\(other)-project"].exists)
        XCTAssertFalse(app.buttons["sidebar.session.\(other)-session"].exists)
    }

    private func assertModelGroup(_ expected: String, absent: String) {
        let chip = app.buttons["composer.modelChip"]
        XCTAssertTrue(chip.waitForExistence(timeout: 5))
        chip.tap()
        XCTAssertTrue(app.navigationBars["会话配置"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[expected].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts[absent].exists)
        app.buttons["完成"].tap()
        XCTAssertTrue(app.navigationBars["会话配置"].waitForNonExistence(timeout: 5))
    }

    private func openSidebar() {
        app.buttons["打开侧边栏"].tap()
        XCTAssertTrue(app.buttons["切换服务器"].waitForExistence(timeout: 5))
    }

    private func switchHost(to suffix: String) {
        app.buttons["切换服务器"].tap()
        let host = app.buttons["Fixture Online Host \(suffix)"]
        XCTAssertTrue(host.waitForExistence(timeout: 5))
        host.tap()
        XCTAssertTrue(app.staticTexts["Fixture Online Host \(suffix)"].waitForExistence(timeout: 8))
    }

    private func closeSidebar() {
        app.buttons["sidebar.close"].tap()
        XCTAssertTrue(app.buttons["切换服务器"].waitForNonExistence(timeout: 5))
    }
}
