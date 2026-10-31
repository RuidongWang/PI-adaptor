import XCTest

@testable import PIiOSCore

final class ToolResultPresentationTests: XCTestCase {
    func testLargeASCIITextIsBoundedAndReportsTruncation() {
        let text = String(repeating: "a", count: 4 * 1024 * 1024)
        let presentation = ToolResultPresentation(text: text)

        XCTAssertEqual(presentation.preview.utf8.count, 32 * 1024)
        XCTAssertEqual(presentation.originalUTF8Bytes, text.utf8.count)
        XCTAssertTrue(presentation.isTruncated)
        XCTAssertNotNil(presentation.truncationNotice)
    }

    func testMultibyteScalarIsNeverSplitAtPreviewBoundary() {
        let prefix = String(repeating: "a", count: 32 * 1024 - 1)
        let presentation = ToolResultPresentation(text: prefix + "界" + "tail")

        XCTAssertEqual(presentation.preview, prefix)
        XCTAssertFalse(presentation.preview.contains("\u{FFFD}"))
        XCTAssertTrue(presentation.isTruncated)
    }

    func testShortResultIsReturnedWithoutNotice() {
        let presentation = ToolResultPresentation(text: "ok")

        XCTAssertEqual(presentation.preview, "ok")
        XCTAssertEqual(presentation.originalUTF8Bytes, 2)
        XCTAssertEqual(presentation.previewUTF8Bytes, 2)
        XCTAssertFalse(presentation.isTruncated)
        XCTAssertNil(presentation.truncationNotice)
    }

    func testFourMiBPreparationStaysUnderTwoHundredMilliseconds() {
        let text = String(repeating: "0123456789abcdef", count: 256 * 1024)
        let clock = ContinuousClock()
        var maximum = Duration.zero

        for _ in 0..<10 {
            let elapsed = clock.measure {
                _ = ToolResultPresentation(text: text)
            }
            maximum = max(maximum, elapsed)
        }

        XCTAssertLessThan(maximum, .milliseconds(200), "最慢一次：\(maximum)")
    }
}
