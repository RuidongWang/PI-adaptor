import XCTest

final class ToolRenderLatencyUITests: XCTestCase {
    private let app = XCUIApplication()

    override func tearDownWithError() throws {
        app.terminate()
    }

    func testBoundedToolPreviewRendersWithinTwoHundredMilliseconds() {
        app.launchEnvironment["PI_IOS_UI_FIXTURE_SCENARIO"] = "online-large-tool-result"
        app.launchEnvironment["PI_IOS_MEASURE_TOOL_RENDER"] = "1"
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()

        XCTAssertTrue(app.buttons["sidebar.session.S1"].waitForExistence(timeout: 8))
        app.buttons["sidebar.session.S1"].tap()
        XCTAssertTrue(app.buttons["sidebar.close"].waitForNonExistence(timeout: 5))

        let toggle = app.descendants(matching: .any)["toolCard.large-tool.toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 8))
        toggle.tap()

        let measured = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", "firstFrameMs="),
            object: toggle
        )
        XCTAssertEqual(XCTWaiter.wait(for: [measured], timeout: 2), .completed)
        let value = (toggle.value as? String) ?? ""
        let firstFrame = value
            .components(separatedBy: "firstFrameMs=")
            .dropFirst()
            .first
            .flatMap(Double.init) ?? .infinity
        XCTAssertGreaterThanOrEqual(firstFrame, 0, "First-frame timing must use one monotonic clock")
        XCTAssertLessThan(firstFrame, 200, "Actual first displayed frame took \(firstFrame) ms")
    }
}
