import XCTest

final class HostDeletionIsolationUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    func testDeletingHostBOnlyRemovesLocalRecord() throws {
        guard ProcessInfo.processInfo.environment["PI_IOS_DELETE_HOST_B"] == "1" else {
            throw XCTSkip("Set PI_IOS_DELETE_HOST_B=1 for the real Host deletion isolation run.")
        }
        let hostAName = ProcessInfo.processInfo.environment["PI_IOS_HOST_A_NAME"] ?? "嗷嗷"
        let hostBName = ProcessInfo.processInfo.environment["PI_IOS_HOST_B_NAME"] ?? "QA Host B"

        showRoot("设置")
        openHost(hostBName)

        let delete = app.buttons
            .matching(NSPredicate(format: "label CONTAINS %@", "删除这台服务器"))
            .firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 10))
        delete.tap()
        XCTAssertTrue(
            app.staticTexts
                .matching(NSPredicate(format: "label CONTAINS %@", "只删除这条本机记录"))
                .firstMatch
                .waitForExistence(timeout: 5)
        )
        app.buttons["删除"].firstMatch.tap()

        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 15))
        let deletedRow = app.buttons
            .matching(NSPredicate(format: "label CONTAINS %@", hostBName))
            .firstMatch
        XCTAssertTrue(deletedRow.waitForNonExistence(timeout: 10))
        XCTAssertTrue(
            app.buttons
                .matching(NSPredicate(format: "label CONTAINS %@", hostAName))
                .firstMatch
                .waitForExistence(timeout: 10)
        )
    }

    private func openHost(_ name: String) {
        let row = app.buttons
            .matching(NSPredicate(format: "label CONTAINS %@", name))
            .firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(app.navigationBars["服务器"].waitForExistence(timeout: 10))
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
