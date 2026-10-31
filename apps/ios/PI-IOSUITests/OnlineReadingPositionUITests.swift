import XCTest

final class OnlineReadingPositionUITests: XCTestCase {
    private let app = XCUIApplication()
    private var latest: XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "回到最新")).firstMatch
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchEnvironment["PI_IOS_UI_FIXTURE_SCENARIO"] = "online-reading-two-sessions"
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["sidebar.session.S1"].waitForExistence(timeout: 5))
    }

    override func tearDownWithError() throws { app.terminate() }

    func testEachSessionRestoresItsOwnScrolledHistory() {
        openSession("S1", fromConversation: false)
        scrollToLatest("S1")
        scrollToEarlierItem("S1", number: 20)
        let s1Top = try! XCTUnwrap(stableTopItem(prefix: "reading-S1-"))

        openSession("S2")
        scrollToLatest("S2")
        XCTAssertFalse(item("S1", 20).exists)
        scrollToEarlierItem("S2", number: 10)
        let s2Top = try! XCTUnwrap(stableTopItem(prefix: "reading-S2-"))

        openSession("S1")
        assertRestored("S1", itemID: s1Top, absent: "S2")
        openSession("S2")
        assertRestored("S2", itemID: s2Top, absent: "S1")

        latest.tap()
        waitUntil { self.item("S2", 40).isHittable && !self.latest.exists }
        openSession("S1")
        assertRestored("S1", itemID: s1Top, absent: "S2")
    }

    private func item(_ session: String, _ number: Int) -> XCUIElement {
        let prefix = String(format: "Reading %@ item %03d\n", session, number)
        return app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    private func openSession(_ id: String, fromConversation: Bool = true) {
        if fromConversation { app.buttons["打开侧边栏"].tap() }
        let row = app.buttons["sidebar.session.\(id)"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.buttons["sidebar.close"].waitForNonExistence(timeout: 5))
        let title = id == "S1" ? "Fixture S1 Alpha" : "Fixture S2 Beta"
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
    }

    private func scrollToEarlierItem(_ session: String, number: Int) {
        let target = item(session, number)
        for _ in 0..<15 where !target.isHittable {
            app.scrollViews.firstMatch.swipeDown()
        }
        XCTAssertTrue(target.isHittable, "The chosen history item must be visibly reached by scrolling.")
        XCTAssertTrue(latest.waitForExistence(timeout: 5))
    }

    private func scrollToLatest(_ session: String) {
        for _ in 0..<20 where !item(session, 40).isHittable {
            app.scrollViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(item(session, 40).isHittable)
    }

    private var topItemProbe: String {
        app.staticTexts["conversation.debugTopVisibleItem"].label
    }

    private func stableTopItem(prefix: String) -> String? {
        let deadline = Date().addingTimeInterval(6)
        var last = ""
        var stableSince = Date()
        while Date() < deadline {
            let current = topItemProbe
            if current != last {
                last = current
                stableSince = Date()
            } else if current.hasPrefix(prefix),
                      Date().timeIntervalSince(stableSince) >= 0.8 {
                return current
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return last.hasPrefix(prefix) ? last : nil
    }

    private func assertRestored(_ session: String, itemID: String, absent: String) {
        let number = Int(itemID.suffix(3)) ?? 0
        let restored = waitForCondition {
            self.topItemProbe == itemID
                && self.item(session, number).isHittable
                && self.latest.exists
        }
        XCTAssertTrue(
            restored,
            "Expected \(itemID) to be restored; probe=\(topItemProbe), debug=\(restorationDebug), latest=\(latest.exists), item=\(item(session, number).isHittable)"
        )
        XCTAssertFalse(item(session, 40).isHittable, "Restoration must not jump to the newest message.")
        XCTAssertFalse(item(absent, 20).exists, "The previous session's items must be removed.")
    }

    private func waitUntil(file: StaticString = #filePath, line: UInt = #line, _ condition: @escaping () -> Bool) {
        XCTAssertTrue(waitForCondition(condition), file: file, line: line)
    }

    private func waitForCondition(_ condition: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        return XCTWaiter.wait(for: [expectation], timeout: 8) == .completed
    }

    private var restorationDebug: String {
        let element = app.staticTexts["conversation.debugRestorationState"]
        return element.exists ? element.label : "missing"
    }
}
