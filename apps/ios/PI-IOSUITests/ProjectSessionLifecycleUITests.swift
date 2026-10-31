import XCTest

final class ProjectSessionLifecycleUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchEnvironment["PI_IOS_UI_FIXTURE_SCENARIO"] = "online-project-lifecycle"
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["sidebar.session.S1"].waitForExistence(timeout: 8))
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    func testProjectArchiveRestoreAndConfirmedLocalDelete() {
        showRoot("项目")
        XCTAssertTrue(app.buttons["projects.row.P1"].exists)
        XCTAssertTrue(app.buttons["projects.row.P2"].exists)

        app.buttons["projects.details.P1"].tap()
        XCTAssertTrue(app.navigationBars["项目详情"].waitForExistence(timeout: 5))
        app.descendants(matching: .any)["projectDetail.archive"].tap()
        XCTAssertTrue(app.navigationBars["项目详情"].waitForNonExistence(timeout: 5))

        let archived = app.descendants(matching: .any)["projects.archived.P1"]
        XCTAssertTrue(archived.waitForExistence(timeout: 5))
        archived.tap()
        XCTAssertTrue(app.buttons["projects.row.P1"].waitForExistence(timeout: 5))
        XCTAssertFalse(archived.exists)

        app.buttons["projects.details.P1"].tap()
        app.descendants(matching: .any)["projectDetail.delete"].tap()
        let alert = app.alerts["从本机删除这个项目？"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(alert.staticTexts["只移除本机项目记录、会话记录与缓存；服务器上的目录、文件、provider 与会话历史不会被删除。"].exists)
        alert.buttons["取消"].tap()
        XCTAssertTrue(app.buttons["projects.row.P1"].exists)

        app.descendants(matching: .any)["projectDetail.delete"].tap()
        app.alerts["从本机删除这个项目？"].buttons["删除"].tap()
        XCTAssertTrue(app.buttons["projects.row.P1"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["projects.row.P2"].exists)

        app.buttons["打开侧边栏"].tap()
        let nextCurrentProject = app.buttons["sidebar.project.P2"]
        XCTAssertTrue(nextCurrentProject.waitForExistence(timeout: 5))
        XCTAssertTrue(nextCurrentProject.label.contains("当前项目"))
    }

    func testSidebarGroupsByProjectAndCrossProjectSelectionMovesContext() {
        let p1 = app.buttons["sidebar.project.P1"]
        let p2 = app.buttons["sidebar.project.P2"]
        XCTAssertTrue(p1.waitForExistence(timeout: 5))
        XCTAssertTrue(p2.exists)
        XCTAssertTrue(p1.label.contains("当前项目"))
        XCTAssertFalse(p2.label.contains("当前项目"))

        let s1 = app.buttons["sidebar.session.S1"]
        let s2 = app.buttons["sidebar.session.S2"]
        let s3 = app.buttons["sidebar.session.S3"]
        XCTAssertTrue(s1.exists && s2.exists && s3.exists)
        XCTAssertLessThan(s2.frame.minY, s1.frame.minY, "组内按最近活动排序")
        XCTAssertLessThan(s1.frame.minY, s3.frame.minY, "会话必须位于各自项目组内")
        XCTAssertFalse(s1.label.contains("provider"))
        XCTAssertFalse(s1.label.contains("P1"))

        s3.tap()
        XCTAssertTrue(app.navigationBars["Beta One"].waitForExistence(timeout: 5))
        app.buttons["打开侧边栏"].tap()
        XCTAssertTrue(p2.waitForExistence(timeout: 5))
        XCTAssertTrue(p2.label.contains("当前项目"))
        XCTAssertFalse(p1.label.contains("当前项目"))
    }

    func testSessionRenameAndArchiveFallsThroughToNextSession() {
        app.buttons["sidebar.session.S1"].tap()
        XCTAssertTrue(app.navigationBars["Alpha One"].waitForExistence(timeout: 5))

        renameCurrentSession(to: "Renamed Alpha")
        XCTAssertTrue(app.navigationBars["Renamed Alpha"].waitForExistence(timeout: 5))

        app.buttons["打开侧边栏"].tap()
        let renamedRow = app.buttons["sidebar.session.S1"]
        XCTAssertTrue(renamedRow.waitForExistence(timeout: 5))
        XCTAssertTrue(renamedRow.label.contains("Renamed Alpha"))
        app.buttons["sidebar.session.S2"].tap()
        XCTAssertTrue(app.navigationBars["Alpha Two"].waitForExistence(timeout: 5))

        app.buttons["会话操作"].tap()
        app.buttons["归档会话"].tap()
        XCTAssertTrue(app.navigationBars["Renamed Alpha"].waitForExistence(timeout: 8))

        app.buttons["打开侧边栏"].tap()
        XCTAssertFalse(app.buttons["sidebar.session.S2"].exists)
        app.buttons["项目"].tap()
        XCTAssertTrue(app.navigationBars["项目"].waitForExistence(timeout: 5))
        app.buttons["projects.details.P1"].tap()
        XCTAssertTrue(app.buttons["projectDetail.session.S2"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["projectDetail.restoreSession.S2"].exists)
        app.buttons["projectDetail.restoreSession.S2"].tap()
        XCTAssertTrue(app.navigationBars["Alpha Two"].waitForExistence(timeout: 8))
    }

    private func showRoot(_ title: String) {
        if app.navigationBars[title].exists { return }
        if app.buttons["sidebar.close"].exists {
            app.buttons["sidebar.close"].tap()
            XCTAssertTrue(app.buttons["sidebar.close"].waitForNonExistence(timeout: 5))
        }
        app.buttons["打开侧边栏"].tap()
        let root = app.buttons[title]
        XCTAssertTrue(root.waitForExistence(timeout: 5))
        root.tap()
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
    }

    private func renameCurrentSession(to title: String) {
        app.buttons["会话操作"].tap()
        app.buttons["重命名会话"].tap()
        let field = app.textFields["会话标题"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        if let existing = field.value as? String {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
        }
        field.typeText(title)
        app.buttons["保存"].tap()
    }
}
