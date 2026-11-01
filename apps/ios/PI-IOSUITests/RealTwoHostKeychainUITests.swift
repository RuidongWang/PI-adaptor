import XCTest

final class RealTwoHostKeychainUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    func testPairTwoRealHostsAndReconnectEachScopedToken() throws {
        let environment = ProcessInfo.processInfo.environment
        let token = environment["PI_IOS_HOST_B_PAIRING_TOKEN"] ?? ""
        let hostAName = environment["PI_IOS_HOST_A_NAME"] ?? "嗷嗷"
        let hostBName = environment["PI_IOS_HOST_B_NAME"] ?? "QA Host B"

        showRoot("设置")
        let hostBRow = app.buttons
            .matching(NSPredicate(format: "label CONTAINS %@", hostBName))
            .firstMatch
        let hostARow = app.buttons
            .matching(NSPredicate(format: "label CONTAINS %@", hostAName))
            .firstMatch
        guard hostBRow.waitForExistence(timeout: 10), hostARow.exists else {
            throw XCTSkip(
                "Configure both real Host records and set PI_IOS_HOST_B_PAIRING_TOKEN for the two-Host keychain run."
            )
        }
        openHost(hostBName)

        let field = app.secureTextFields["ppt1.…"]
        if field.waitForExistence(timeout: 8) {
            guard !token.isEmpty else {
                throw XCTSkip("Provide PI_IOS_HOST_B_PAIRING_TOKEN for the first real two-Host pairing run.")
            }
            UIPasteboard.general.string = token
            addTeardownBlock { UIPasteboard.general.string = nil }
            field.tap()
            field.press(forDuration: 1)
            let paste = app.menuItems["粘贴"].firstMatch
            if paste.waitForExistence(timeout: 2) {
                paste.tap()
            } else {
                app.menuItems["Paste"].firstMatch.tap()
            }
            UIPasteboard.general.string = nil

            let pair = app.buttons["配对并连接"]
            XCTAssertTrue(pair.waitForExistence(timeout: 5))
            pair.tap()
            XCTAssertTrue(
                app.staticTexts["配对成功；设备令牌已保存"].waitForExistence(timeout: 40),
                "Host B must pair and persist its scoped device token."
            )
        } else {
            XCTAssertTrue(
                app.staticTexts["已保存设备令牌"].waitForExistence(timeout: 10),
                "An already-paired Host B must expose its persisted token."
            )
        }
        XCTAssertTrue(app.staticTexts["已保存设备令牌"].waitForExistence(timeout: 10))
        XCTAssertTrue(
            app.staticTexts["在线"].waitForExistence(timeout: 30),
            "Host B must reconnect with its newly persisted token."
        )

        backToServerList()
        openHost(hostAName)
        XCTAssertTrue(app.staticTexts["已保存设备令牌"].waitForExistence(timeout: 10))
        connectPiHost()
        XCTAssertTrue(
            app.staticTexts["在线"].waitForExistence(timeout: 30),
            "Host A must keep its own token and reconnect independently."
        )

        backToServerList()
        openHost(hostBName)
        XCTAssertTrue(app.staticTexts["已保存设备令牌"].waitForExistence(timeout: 10))
        connectPiHost()
        XCTAssertTrue(
            app.staticTexts["在线"].waitForExistence(timeout: 30),
            "Host B must reconnect again without borrowing Host A's token."
        )
    }

    private func connectPiHost() {
        let connect = app.buttons
            .matching(NSPredicate(format: "label CONTAINS %@", "连接 PI-adaptor"))
            .firstMatch
        XCTAssertTrue(connect.waitForExistence(timeout: 10))
        connect.tap()
    }

    private func openHost(_ name: String) {
        let row = app.buttons
            .matching(NSPredicate(format: "label CONTAINS %@", name))
            .firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(app.navigationBars["服务器"].waitForExistence(timeout: 10))
    }

    private func backToServerList() {
        let nav = app.navigationBars["服务器"]
        let back = nav.buttons.firstMatch
        if back.exists {
            back.tap()
        } else {
            app.swipeRight()
        }
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 10))
    }

    private func showRoot(_ title: String) {
        if app.navigationBars[title].waitForExistence(timeout: 8) {
            return
        }
        let menu = app.buttons["打开侧边栏"]
        XCTAssertTrue(menu.waitForExistence(timeout: 8))
        menu.tap()
        let root = app.buttons[title].firstMatch
        XCTAssertTrue(root.waitForExistence(timeout: 5))
        root.tap()
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 10))
    }
}
