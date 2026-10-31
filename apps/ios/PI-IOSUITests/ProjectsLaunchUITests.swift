import XCTest
import UIKit

final class ProjectsLaunchUITests: XCTestCase {
    private let app = XCUIApplication()
    /// 仓库里只保留脱敏后的保留地址（203.0.113.10，RFC 5737）。
    /// 要对着真实 Host 跑，用 `PI_IOS_EXPECTED_HOST=<真实地址片段>` 覆盖，不要把真实地址写回仓库。
    private let expectedHostFragment =
        ProcessInfo.processInfo.environment["PI_IOS_EXPECTED_HOST"] ?? "203.0.113.10"
    private let expectedProjectName = "pi-test-proj"

    override func setUpWithError() throws {
        continueAfterFailure = false
        addUIInterruptionMonitor(withDescription: "System alerts") { alert in
            for label in ["允许", "Allow", "好", "OK"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        app.launch()
    }

    func testProjectsScreenAndAddProjectAffordanceAreDiscoverable() throws {
        showRoot("项目")

        let addProject = app.buttons["projects.add"]
        XCTAssertTrue(
            addProject.waitForExistence(timeout: 8),
            "The projects.add accessibility identifier must be discoverable."
        )

        // The browse-and-register row only exists when the Host has an active project.
        // Keep that assertion conditional so the smoke test also runs with an empty Host.
        let browseRow = app.buttons
            .matching(NSPredicate(format: "label CONTAINS %@", "浏览服务器目录并注册"))
            .firstMatch
        if !browseRow.exists {
            app.swipeUp()
        }
        let emptyStateAction = app.buttons["选择服务器目录"]
        XCTAssertTrue(
            browseRow.exists || emptyStateAction.exists,
            "The projects screen must expose a non-mutating path to the directory browser."
        )

        guard addProject.isEnabled else { return }
        addProject.tap()

        let sheet = app.descendants(matching: .any)
            .matching(identifier: "projectBrowser.sheet")
            .firstMatch
        XCTAssertTrue(
            sheet.waitForExistence(timeout: 10),
            "Opening the project browser must expose projectBrowser.sheet."
        )
        XCTAssertTrue(
            app.textFields["projectBrowser.name"].waitForExistence(timeout: 5),
            "The add-project sheet must expose its project name field."
        )
        XCTAssertTrue(
            app.buttons["用当前目录注册项目"].waitForExistence(timeout: 5),
            "The add-project sheet must expose its register button."
        )

        let cancel = app.buttons["取消"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 3))
        cancel.tap()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
    }

    func testEditedProjectNameSurvivesDirectoryNavigation() throws {
        showRoot("项目")

        let addProject = app.buttons["projects.add"]
        guard addProject.waitForExistence(timeout: 8) else {
            throw XCTSkip("The current Host has no browsable project catalog.")
        }
        let catalogReady = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"),
            object: addProject
        )
        guard XCTWaiter.wait(for: [catalogReady], timeout: 10) == .completed else {
            throw XCTSkip("The current Host has no browsable project catalog.")
        }
        addProject.tap()

        let name = app.textFields["projectBrowser.name"]
        let currentPath = app.staticTexts["projectBrowser.currentPath"]
        guard name.waitForExistence(timeout: 10),
              currentPath.waitForExistence(timeout: 15)
        else {
            throw XCTSkip("The project browser is unavailable in this App state.")
        }

        let typedMarker = "E2E-NAME-KEEP"
        let browser = app.collectionViews["projectBrowser.sheet"]
        let window = app.windows.firstMatch
        XCTAssertTrue(browser.waitForExistence(timeout: 5))
        for _ in 0..<8 where !window.frame.intersects(name.frame) {
            browser.swipeUp()
        }
        XCTAssertTrue(
            window.frame.intersects(name.frame),
            "The project name field must be reachable by scrolling."
        )
        name.tap()
        name.typeText(" \(typedMarker)")
        XCTAssertTrue(
            (name.value as? String)?.contains(typedMarker) == true,
            "The project name field must accept user text."
        )

        let navigationTarget = app.buttons
            .matching(
                NSPredicate(
                    format: "isEnabled == true AND (identifier == %@ OR identifier BEGINSWITH %@)",
                    "projectBrowser.parent",
                    "projectBrowser.entry."
                )
            )
            .firstMatch
        guard navigationTarget.waitForExistence(timeout: 25) else {
            throw XCTSkip("The current Host has no navigable server directory.")
        }
        for _ in 0..<3 where !navigationTarget.isHittable {
            app.swipeDown()
        }
        XCTAssertTrue(
            navigationTarget.isHittable,
            "A directory navigation action must remain reachable."
        )
        let previousPath = currentPath.label
        navigationTarget.tap()

        let moved = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label != %@", previousPath),
            object: currentPath
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [moved], timeout: 10),
            .completed,
            "Parent navigation must load a different server directory."
        )
        XCTAssertTrue(
            (name.value as? String)?.contains(typedMarker) == true,
            "Directory navigation must not overwrite a name edited by the user."
        )

        app.buttons["取消"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["projectBrowser.sheet"]
                .waitForNonExistence(timeout: 5)
        )
    }

    func testProjectsShowCurrentServerAndCurrentProject() {
        showRoot("项目")

        XCTAssertTrue(
            app.staticTexts["当前服务器"].waitForExistence(timeout: 8),
            "The projects screen must identify the current-server section."
        )
        XCTAssertTrue(
            app.staticTexts
                .matching(NSPredicate(format: "label CONTAINS %@", expectedHostFragment))
                .firstMatch
                .waitForExistence(timeout: 8),
            "The projects screen must show the connected server address."
        )
        XCTAssertTrue(
            app.buttons
                .matching(NSPredicate(format: "label CONTAINS %@", expectedProjectName))
                .firstMatch
                .waitForExistence(timeout: 8),
            "The projects screen must show the current project as a read-only navigation row."
        )
    }

    func testUnreadableChildClearsStaleParentAndDisablesRegistration() throws {
        guard let deniedPath = ProcessInfo.processInfo.environment["PI_IOS_UI_TEST_UNREADABLE_DIRECTORY"],
              deniedPath.hasPrefix("/"), deniedPath != "/" else {
            throw XCTSkip("Provide an existing unreadable child directory on the QA Host.")
        }
        showRoot("项目")
        let addProject = app.buttons["projects.add"]
        guard addProject.waitForExistence(timeout: 10), addProject.isEnabled else {
            throw XCTSkip("The QA Host has no browsable project catalog.")
        }
        addProject.tap()
        let currentPath = app.staticTexts["projectBrowser.currentPath"]
        XCTAssertTrue(currentPath.waitForExistence(timeout: 15))
        let registerButton = app.buttons["用当前目录注册项目"]
        XCTAssertTrue(registerButton.waitForExistence(timeout: 10))
        let browser = app.collectionViews.firstMatch
        XCTAssertTrue(browser.exists, "The project browser list must remain visible.")
        let containerPath = (deniedPath as NSString).deletingLastPathComponent

        for _ in 0..<20 where currentPath.label != containerPath {
            let previousPath = currentPath.label
            let next: XCUIElement
            if containerPath.hasPrefix(previousPath == "/" ? "/" : previousPath + "/") {
                let remainder = containerPath.dropFirst(previousPath == "/" ? 1 : previousPath.count + 1)
                let component = try XCTUnwrap(remainder.split(separator: "/").first)
                let child = previousPath == "/" ? "/\(component)" : "\(previousPath)/\(component)"
                next = app.buttons["projectBrowser.entry.\(child)"]
                if !next.exists {
                    for _ in 0..<12 where !next.exists {
                        browser.swipeUp()
                    }
                }
            } else {
                next = app.buttons["projectBrowser.parent"]
            }
            guard next.waitForExistence(timeout: 5) else {
                throw XCTSkip("The unreadable fixture is outside the Host's browsable tree.")
            }
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: next)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
            for _ in 0..<10 {
                if next.isHittable, next.frame.maxY < registerButton.frame.minY - 8 { break }
                browser.swipeUp()
            }
            XCTAssertLessThan(
                next.frame.maxY,
                registerButton.frame.minY - 4,
                "Each directory row must be scrolled above the fixed registration footer before tapping."
            )
            next.tap()
            let moved = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "label != %@", previousPath), object: currentPath
            )
            XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 10), .completed)
        }
        XCTAssertEqual(currentPath.label, containerPath)
        let child = app.buttons["projectBrowser.entry.\(deniedPath)"]
        XCTAssertTrue(child.waitForExistence(timeout: 10))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: child)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
        for _ in 0..<10 {
            if child.isHittable, child.frame.maxY < registerButton.frame.minY - 8 { break }
            browser.swipeUp()
        }
        XCTAssertTrue(child.isHittable, "The unreadable directory row must be tappable, not covered by the toolbar.")
        XCTAssertLessThan(
            child.frame.maxY,
            registerButton.frame.minY - 4,
            "The directory row must be scrolled above the fixed registration footer before tapping."
        )
        child.tap()

        let deadline = Date().addingTimeInterval(10)
        var observedPath = currentPath.label
        while Date() < deadline {
            let pathElement = app.staticTexts["projectBrowser.currentPath"]
            if pathElement.exists {
                observedPath = pathElement.label
            }
            if observedPath == deniedPath { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertEqual(
            observedPath,
            deniedPath,
            "Tapping an unreadable directory must keep the attempted path visible. Labels: \(app.staticTexts.allElementsBoundByIndex.map(\.label))"
        )
        XCTAssertTrue(app.buttons["重试当前目录"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["projectBrowser.parent"].exists)
        XCTAssertFalse(app.buttons["用当前目录注册项目"].isEnabled)
        app.buttons["取消"].tap()
    }

    func testSettingsShowHostVersionAndSystemdState() {
        showRoot("设置")

        let hostVersion = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS %@", "Host 版本"))
            .firstMatch
        XCTAssertTrue(
            hostVersion.waitForExistence(timeout: 10),
            "Settings must show the connected Host version."
        )

        let systemd = app.buttons
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "systemd 服务"))
            .firstMatch
        XCTAssertTrue(
            systemd.waitForExistence(timeout: 10),
            "Settings must expose the systemd status row."
        )

        let settled = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "NOT (label CONTAINS[c] %@) AND NOT (label CONTAINS[c] %@)",
                "查询中",
                "未查询"
            ),
            object: systemd
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [settled], timeout: 20),
            .completed,
            "The systemd row must settle on a real status value. Current label: \(systemd.label)"
        )
        XCTAssertTrue(
            systemd.label.range(
                of: "active|inactive|failed|unknown|无法读取",
                options: [.regularExpression, .caseInsensitive]
            ) != nil,
            "The settled systemd row must include a status value. Current label: \(systemd.label)"
        )
        XCTAssertTrue(
            app.staticTexts["不会收到后台推送"].exists,
            "Settings must explicitly state that APNs background push is unavailable."
        )
    }

    func testModelsAuthenticationPresetsAndSubscriptionDisabledState() throws {
        showRoot("设置")

        let models = app.buttons
            .matching(NSPredicate(format: "label CONTAINS %@", "模型服务"))
            .firstMatch
        guard models.waitForExistence(timeout: 10) else {
            throw XCTSkip("The model-services entry is unavailable in this App state.")
        }
        models.tap()

        let subscription = segmentedButton(named: "订阅账号登录")
        guard subscription.waitForExistence(timeout: 10) else {
            throw XCTSkip("The authentication preset control is not reachable on this screen.")
        }
        XCTAssertTrue(segmentedButton(named: "API Key + Base URL").exists)

        let deepSeekPreset = segmentedButton(named: "DeepSeek 官方")
        XCTAssertTrue(
            deepSeekPreset.waitForExistence(timeout: 5),
            "The DeepSeek official service preset must be available."
        )
        deepSeekPreset.tap()
        XCTAssertEqual(
            app.textFields["models.serviceName"].value as? String,
            "DeepSeek",
            "Selecting the DeepSeek preset must fill the service name."
        )
        XCTAssertEqual(
            app.textFields["models.baseURL"].value as? String,
            "https://api.deepseek.com",
            "Selecting the DeepSeek preset must fill the official Base URL."
        )

        subscription.tap()
        XCTAssertTrue(
            app.staticTexts["暂不支持订阅账号登录；不会发起 OAuth 或访问账号授权页面。"]
                .waitForExistence(timeout: 8),
            "Selecting subscription login must explain that OAuth is not implemented."
        )

        let baseURL = app.textFields["models.baseURL"]
        XCTAssertTrue(baseURL.waitForExistence(timeout: 5), "The Base URL field must exist.")
        XCTAssertFalse(baseURL.isEnabled, "Subscription login must disable Base URL.")

        let apiKey = app.secureTextFields["models.apiKey"]
        XCTAssertTrue(apiKey.waitForExistence(timeout: 5), "The API Key field must exist.")
        XCTAssertFalse(apiKey.isEnabled, "Subscription login must disable API Key.")
    }

    func testInstallHostScreenIsReachableWithoutStartingInstallation() throws {
        showRoot("设置")

        let host = app.buttons
            .matching(NSPredicate(format: "label CONTAINS %@", expectedHostFragment))
            .firstMatch
        guard host.waitForExistence(timeout: 8) else {
            throw XCTSkip("The current Host row is unavailable.")
        }
        host.tap()
        XCTAssertTrue(app.navigationBars["服务器"].waitForExistence(timeout: 8))

        let install = app.buttons
            .matching(NSPredicate(format: "label CONTAINS %@", "安装或修复 pi-host"))
            .firstMatch
        guard install.waitForExistence(timeout: 8) else {
            throw XCTSkip("The install entry is unavailable for this Host.")
        }
        install.tap()

        XCTAssertTrue(app.navigationBars["安装 pi-host"].waitForExistence(timeout: 8))
        XCTAssertTrue(
            app.textFields["installHost.port"].waitForExistence(timeout: 5),
            "The installation screen must expose its fixed loopback port."
        )
        XCTAssertTrue(
            app.buttons["开始安装"].exists,
            "The installation screen must expose the real install action without auto-starting it."
        )
    }

    func testConversationAttachmentIsAvailableAndSidebarSearchIsDiscoverable() throws {
        showRoot("项目")

        let session = app.buttons
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "rev "))
            .firstMatch
        for _ in 0..<4 where !session.exists {
            app.swipeUp()
        }
        guard session.waitForExistence(timeout: 8) else {
            throw XCTSkip("There is no active session row for the current project.")
        }
        session.tap()

        let attachment = app.buttons["图片附件"]
        XCTAssertTrue(
            attachment.waitForExistence(timeout: 15),
            "An opened conversation must expose the attachment affordance."
        )
        XCTAssertTrue(
            attachment.isEnabled,
            "An online conversation must expose the v2 image attachment picker."
        )
        XCTAssertTrue(
            app.staticTexts["支持 JPEG、PNG、WebP；单张不超过 20 MiB，每条消息最多 10 张"]
                .waitForExistence(timeout: 5),
            "The conversation composer must explain the v2 attachment limits."
        )

        let menu = app.buttons["打开侧边栏"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.tap()

        XCTAssertTrue(
            app.textFields["搜索会话或项目"].waitForExistence(timeout: 5),
            "The sidebar must expose conversation/project search."
        )
        XCTAssertTrue(
            app.buttons
                .matching(NSPredicate(format: "label CONTAINS %@", expectedProjectName))
                .firstMatch
                .waitForExistence(timeout: 8),
            "The sidebar must show the current project group."
        )
        XCTAssertTrue(app.buttons["项目"].exists, "The sidebar project root entry must exist.")
        XCTAssertTrue(app.buttons["设置"].exists, "The sidebar settings root entry must exist.")
    }

    func testDeepSeekOfficialLiveImport() throws {
        let environment = ProcessInfo.processInfo.environment
        let apiKey: String
        if let inline = environment["PI_IOS_DEEPSEEK_API_KEY"], !inline.isEmpty {
            apiKey = inline
        } else if let path = environment["PI_IOS_DEEPSEEK_API_KEY_FILE"],
                  let fileValue = try? String(contentsOfFile: path, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !fileValue.isEmpty {
            apiKey = fileValue
        } else {
            throw XCTSkip(
                "Provide PI_IOS_DEEPSEEK_API_KEY or PI_IOS_DEEPSEEK_API_KEY_FILE to run the live DeepSeek import."
            )
        }

        showRoot("设置")
        let models = app.buttons
            .matching(NSPredicate(format: "label CONTAINS %@", "模型服务"))
            .firstMatch
        XCTAssertTrue(models.waitForExistence(timeout: 10))
        models.tap()

        let deepSeekPreset = segmentedButton(named: "DeepSeek 官方")
        XCTAssertTrue(deepSeekPreset.waitForExistence(timeout: 10))
        deepSeekPreset.tap()
        XCTAssertEqual(app.textFields["models.serviceName"].value as? String, "DeepSeek")
        XCTAssertEqual(app.textFields["models.baseURL"].value as? String, "https://api.deepseek.com")

        let keyField = app.secureTextFields["models.apiKey"]
        XCTAssertTrue(keyField.waitForExistence(timeout: 5))
        UIPasteboard.general.string = apiKey
        addTeardownBlock {
            UIPasteboard.general.string = nil
        }
        keyField.tap()
        keyField.press(forDuration: 1)
        let paste = app.menuItems["粘贴"].firstMatch
        if paste.waitForExistence(timeout: 2) {
            paste.tap()
        } else {
            let englishPaste = app.menuItems["Paste"].firstMatch
            XCTAssertTrue(englishPaste.waitForExistence(timeout: 2))
            englishPaste.tap()
        }
        UIPasteboard.general.string = nil

        let fetch = app.buttons["获取模型"]
        XCTAssertTrue(fetch.waitForExistence(timeout: 5))
        fetch.tap()

        let importButton = app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH %@", "导入 "))
            .firstMatch
        XCTAssertTrue(
            importButton.waitForExistence(timeout: 30),
            "DeepSeek /models must resolve into importable model rows."
        )
        XCTAssertTrue(
            app.staticTexts
                .matching(NSPredicate(format: "label CONTAINS %@", "思考 off/low/high/max"))
                .firstMatch
                .exists,
            "Endpoint effort metadata must remain authoritative over the generic catalog."
        )
        importButton.tap()
        XCTAssertTrue(
            app.staticTexts
                .matching(NSPredicate(format: "label BEGINSWITH %@", "已导入 2 个模型"))
                .firstMatch
                .waitForExistence(timeout: 30),
            "provider-import must return a success receipt for the discovered models."
        )
    }

    func testLiveSessionHistoryMatchesHostContent() throws {
        guard let expected = ProcessInfo.processInfo.environment["PI_IOS_LIVE_HISTORY_EXPECTED"],
              !expected.isEmpty
        else {
            throw XCTSkip("Provide PI_IOS_LIVE_HISTORY_EXPECTED for the live history projection probe.")
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
        XCTAssertTrue(
            app.staticTexts
                .matching(NSPredicate(format: "label CONTAINS %@", expected))
                .firstMatch
                .waitForExistence(timeout: 20),
            "The conversation must render the same canonical text stored by pi-host."
        )
    }

    private func segmentedButton(named name: String) -> XCUIElement {
        let scoped = app.segmentedControls.buttons[name].firstMatch
        return scoped.exists ? scoped : app.buttons[name].firstMatch
    }

    private func showRoot(_ title: String) {
        if app.navigationBars[title].waitForExistence(timeout: 8) {
            return
        }

        let menu = app.buttons["打开侧边栏"]
        XCTAssertTrue(menu.waitForExistence(timeout: 8), "The root navigation menu must exist.")
        menu.tap()

        let root = app.buttons[title].firstMatch
        XCTAssertTrue(root.waitForExistence(timeout: 5), "The \(title) root entry must exist.")
        root.tap()
        XCTAssertTrue(
            app.navigationBars[title].waitForExistence(timeout: 10),
            "The \(title) screen must be reachable without mutating server state."
        )
    }
}
