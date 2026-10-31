import XCTest

/// Runs entirely from synthetic in-memory records; no server or credentials.
final class OfflineHostCacheUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchEnvironment["PI_IOS_UI_FIXTURE_SCENARIO"] = "offline-two-hosts"
        app.launchEnvironment["TZ"] = "UTC"
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    func testOfflineSidebarAndConversationStayWithinSelectedHost() {
        assertSidebar(host: "B", absent: "A")
        cachedRow("fixture-session-B").tap()
        assertReadOnlyConversation(host: "B", kind: "private", absent: "A")

        openSidebar()
        switchHost(to: "A")
        assertSidebar(host: "A", absent: "B")
        cachedRow("fixture-session-A").tap()
        assertReadOnlyConversation(host: "A", kind: "private", absent: "B")

        // Closing the drawer after switching restores B's remembered selection,
        // not A's last-opened session or the newest (shared) cache row.
        openSidebar()
        switchHost(to: "B")
        assertSidebar(host: "B", absent: "A")
        closeSidebar()
        assertReadOnlyConversation(host: "B", kind: "private", absent: "A")
        XCTAssertFalse(app.staticTexts["Fixture B shared history"].exists)
    }

    func testCollidingSessionAndItemIDsStayPartitionedAcrossHostSwitch() {
        assertSidebar(host: "B", absent: "A")
        cachedRow("fixture-shared-session").tap()
        assertReadOnlyConversation(host: "B", kind: "shared", absent: "A")

        openSidebar()
        switchHost(to: "A")
        cachedRow("fixture-shared-session").tap()
        assertReadOnlyConversation(host: "A", kind: "shared", absent: "B")

        openSidebar()
        switchHost(to: "B")
        closeSidebar()
        assertReadOnlyConversation(host: "B", kind: "shared", absent: "A")
    }

    private func cachedRow(_ id: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", id)).firstMatch
    }

    private func assertSidebar(host: String, absent: String) {
        XCTAssertTrue(app.buttons["切换服务器"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Fixture Host \(host)"].exists)
        let projectGroup = app.buttons["sidebar.project.fixture-project-\(host)"]
        XCTAssertTrue(projectGroup.waitForExistence(timeout: 5))
        XCTAssertTrue(projectGroup.label.contains("当前项目"))
        XCTAssertTrue(cachedRow("fixture-session-\(host)").exists)
        XCTAssertTrue(cachedRow("fixture-shared-session").exists)
        XCTAssertFalse(cachedRow("fixture-session-\(absent)").exists)
        assertNoContext(from: absent)
        XCTAssertTrue(app.staticTexts["离线：下面是可以只读查看的缓存会话。"].exists)
    }

    private func assertReadOnlyConversation(host: String, kind: String, absent: String) {
        XCTAssertFalse(app.buttons["切换服务器"].exists, "Conversation assertions require a closed drawer.")
        let readOnly = app.staticTexts["离线只读 · 缓存可能已过期"]
        XCTAssertTrue(readOnly.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["离线：发送已禁用"].exists)
        let input = app.textFields["给 Agent 的指令"]
        XCTAssertTrue(input.exists)
        XCTAssertFalse(input.isEnabled)
        XCTAssertTrue(app.buttons["发送"].exists)
        XCTAssertFalse(app.buttons["发送"].isEnabled)

        for label in ["允许一次", "本会话允许", "拒绝"] {
            XCTAssertTrue(app.buttons[label].exists)
            XCTAssertFalse(app.buttons[label].isEnabled)
        }
        for identifier in [
            "composer.modeChip",
            "composer.permissionChip",
            "composer.modelChip",
            "composer.thinkingChip",
        ] {
            let chip = app.buttons[identifier]
            if chip.exists {
                XCTAssertFalse(chip.isEnabled, "\(identifier) must be disabled offline")
            }
        }
        XCTAssertTrue(app.staticTexts["Fixture \(host) approval"].exists)
        assertNoContext(from: absent)

        let history = app.staticTexts["Fixture \(host) \(kind) history"]
        for _ in 0..<5 where !history.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(history.isHittable, "The selected Host's original cache text must be visible.")
        XCTAssertTrue(app.staticTexts["Fixture \(host) unsent draft"].exists)
        let time = Date(timeIntervalSince1970: 1_704_164_640 + (kind == "shared" ? 60 : 0))
        let originalTimestamp = time.formatted(Date.FormatStyle(
            date: .abbreviated, time: .shortened,
            locale: Locale(identifier: "zh_CN"), timeZone: TimeZone(secondsFromGMT: 0)!
        ))
        XCTAssertTrue(app.staticTexts[originalTimestamp].exists,
                      "Cached messages must retain their original timestamp: \(originalTimestamp)")
        assertNoContext(from: absent)
    }

    private func assertNoContext(from host: String) {
        let leaked = app.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS %@ OR label CONTAINS %@ OR label CONTAINS %@ OR label CONTAINS %@",
            "Fixture \(host) ", "fixture-session-\(host)",
            "Fixture Project \(host)", "fixture-project-\(host)"
        ))
        XCTAssertEqual(leaked.count, 0, "The other Host's titles, IDs and cache payloads must be absent.")
    }

    private func openSidebar() {
        app.buttons["打开侧边栏"].tap()
        XCTAssertTrue(app.buttons["切换服务器"].waitForExistence(timeout: 5))
    }

    private func closeSidebar() {
        app.buttons["sidebar.close"].tap()
        XCTAssertTrue(app.buttons["sidebar.close"].waitForNonExistence(timeout: 5))
    }

    private func switchHost(to host: String) {
        app.buttons["切换服务器"].tap()
        let choice = app.buttons["Fixture Host \(host)"]
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        choice.tap()
        XCTAssertTrue(app.staticTexts["Fixture Host \(host)"].waitForExistence(timeout: 5))
    }
}
