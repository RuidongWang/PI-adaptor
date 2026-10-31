import Foundation
import XCTest
@testable import PIiOSCore

final class ProviderBindingStatusTests: XCTestCase {
    func testParsesAvailableBinding() {
        let json = """
        {"sessionId":"ses_1","pinned":{"providerId":"p1","modelId":"m1","thinkingLevel":"high"},"effective":{"providerId":"p1","modelId":"m1","providerSource":"pin","modelSource":"session"},"available":true,"unavailableReason":null,"checks":{"providerKnown":true,"providerEnabled":true,"modelsEmpty":false,"modelPresent":true,"secretPresent":true,"oauth":false,"pluginOwned":false,"secretMismatch":false},"unknownInputs":[],"consistency":{"reads":2,"snapshotStable":true},"isDefault":false,"revision":null,"sessionUpdatedAt":null,"maxAgeMs":10000,"observedAt":"2026-11-03T00:00:00Z"}
        """
        let receipt = ProviderBindingReceiptParser.parse(
            stdout: "PI_HOST_BINDING \(json)\n",
            exitCode: 0
        )
        guard case .success(let status) = receipt else {
            return XCTFail("应解析成功：\(receipt)")
        }
        XCTAssertEqual(status.available, true)
        XCTAssertEqual(status.pinnedProviderId, "p1")
        XCTAssertEqual(status.effectiveModelId, "m1")
    }

    func testParsesUnavailableAndUnknown() throws {
        func parse(available: String, reason: String) throws -> ProviderBindingStatus {
            let json = """
            {"sessionId":"ses_1","pinned":{"providerId":"p1","modelId":"m1","thinkingLevel":null},"effective":null,"available":\(available),"unavailableReason":"\(reason)","checks":{"providerKnown":false,"providerEnabled":null,"modelsEmpty":null,"modelPresent":null,"secretPresent":null,"oauth":null,"pluginOwned":null,"secretMismatch":null},"unknownInputs":[],"consistency":{"reads":2,"snapshotStable":true},"isDefault":false,"revision":null,"sessionUpdatedAt":null,"maxAgeMs":10000,"observedAt":"2026-11-03T00:00:00Z"}
            """
            return try ProviderBindingStatusParser.parse(Data(json.utf8))
        }
        XCTAssertEqual(try parse(available: "false", reason: "provider_missing").available, false)
        XCTAssertEqual(try parse(available: "null", reason: "unknown").available, nil)
    }

    func testRejectsUnknownKey() {
        let json = """
        {"sessionId":"ses_1","pinned":{"providerId":null,"modelId":null,"thinkingLevel":null},"effective":null,"available":null,"unavailableReason":"unknown","checks":{"providerKnown":null,"providerEnabled":null,"modelsEmpty":null,"modelPresent":null,"secretPresent":null,"oauth":null,"pluginOwned":null,"secretMismatch":null},"unknownInputs":[],"consistency":{"reads":2,"snapshotStable":true},"isDefault":false,"revision":null,"sessionUpdatedAt":null,"maxAgeMs":10000,"observedAt":"2026-11-03T00:00:00Z","exists":false}
        """
        XCTAssertThrowsError(try ProviderBindingStatusParser.parse(Data(json.utf8)))
    }
}
