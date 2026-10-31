import Foundation
import XCTest
@testable import PIiOSCore

final class ProviderRemoveTests: XCTestCase {
    private let providerID = "6f1c2a3e-4b5d-4c7e-8f90-a1b2c3d4e5f6"

    func testCanonicalPayloadIs65Bytes() throws {
        let payload = ProviderRemovePayload(providerId: providerID)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(payload)
        XCTAssertEqual(data.count, 65)
    }

    func testParsesDeletedWithDefaultMove() throws {
        let json = """
        {"providerId":"\(providerID)","effect":"deleted","secretCleared":true,"defaultMoved":{"to":{"providerId":"0a1b2c3d-4e5f-4a6b-8c9d-0e1f2a3b4c5d","modelId":"model/a"},"orderingBasis":"createdAt"},"remaining":1,"remainingEligible":1}
        """
        let receipt = ProviderRemoveReceiptParser.parse(
            stdout: "PI_HOST_REMOVED \(json)\n",
            exitCode: 0
        )
        guard case .success(let summary) = receipt else {
            return XCTFail("应解析成功：\(receipt)")
        }
        XCTAssertEqual(summary.effect, .deleted)
        XCTAssertEqual(summary.defaultMoved, .moved(
            providerId: "0a1b2c3d-4e5f-4a6b-8c9d-0e1f2a3b4c5d",
            modelId: "model/a"
        ))
    }

    func testParsesAbsentWithoutDefaultMove() throws {
        let json = """
        {"providerId":"\(providerID)","effect":"absent","secretCleared":true,"remaining":0,"remainingEligible":0}
        """
        let receipt = ProviderRemoveReceiptParser.parse(
            stdout: "PI_HOST_REMOVED \(json)\n",
            exitCode: 0
        )
        guard case .success(let summary) = receipt else {
            return XCTFail("应解析成功：\(receipt)")
        }
        XCTAssertEqual(summary.effect, .absent)
        XCTAssertNil(summary.defaultMoved)
    }

    func testRejectsAbsentWithDefaultMoveAndSecretNotCleared() throws {
        let absent = """
        {"providerId":"\(providerID)","effect":"absent","secretCleared":true,"defaultMoved":{"to":null,"reason":"no_remaining","orderingBasis":"none"},"remaining":0,"remainingEligible":0}
        """
        XCTAssertThrowsError(try ProviderRemoveParser.parseSummary(Data(absent.utf8)))

        let secret = """
        {"providerId":"\(providerID)","effect":"deleted","secretCleared":false,"remaining":0,"remainingEligible":0}
        """
        XCTAssertThrowsError(try ProviderRemoveParser.parseSummary(Data(secret.utf8)))
    }

    func testFailureCodeIsRecognized() {
        let receipt = ProviderRemoveReceiptParser.parse(
            stdout: "PI_HOST_FAILED {\"code\":\"PLUGIN_OWNED\"}\n",
            exitCode: 1
        )
        XCTAssertEqual(receipt, .failure(.pluginOwned))
    }

    func testUnknownFailureCodeIsPreserved() {
        let receipt = ProviderRemoveReceiptParser.parse(
            stdout: "PI_HOST_FAILED {\"code\":\"SOMETHING_NEW\"}\n",
            exitCode: 1
        )
        XCTAssertEqual(receipt, .failure(.unknown("SOMETHING_NEW")))
    }

    func testDefaultTransferOrderUnknownFourKeyForm() {
        let json = """
        {"ok":false,"code":"DEFAULT_TRANSFER_ORDER_UNKNOWN","removed":{"providerId":"\(providerID)","secretCleared":true},"defaultTransfer":{"state":"not_transferred","reason":"order_unknown","orderingBasis":"none"}}
        """
        let receipt = ProviderRemoveReceiptParser.parse(stdout: "PI_HOST_FAILED \(json)\n", exitCode: 1)
        XCTAssertEqual(
            receipt,
            .defaultTransferOrderUnknown(removedProviderId: providerID, secretCleared: true)
        )
    }
}
