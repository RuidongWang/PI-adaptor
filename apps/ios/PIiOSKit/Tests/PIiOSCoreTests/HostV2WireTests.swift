import XCTest
@testable import PIiOSCore

final class HostV2WireTests: XCTestCase {
    func testProviderDecodesMaskedProtocolField() throws {
        let json = """
        {
          "id":"p1","name":"Mock","vendorKey":"mock","type":"openai_compatible",
          "protocol":"openai_completions","baseUrl":"https://example.com/v1",
          "authKind":"api_key","hasApiKey":true,"apiKeyMask":"sk-…1234",
          "isDefault":true,"models":[],"createdAt":"2026-01-01T00:00:00Z",
          "updatedAt":"2026-01-01T00:00:00Z"
        }
        """
        let provider = try JSONDecoder().decode(RACPV2Provider.self, from: Data(json.utf8))
        XCTAssertEqual(provider.protocolName, "openai_completions")
        XCTAssertEqual(provider.apiKeyMask, "sk-…1234")
        XCTAssertTrue(provider.hasApiKey)
    }

    func testMethodInventoryIncludesEveryV2Family() {
        let methods = Set(RACPV2Method.allCases.map(\.rawValue))
        XCTAssertTrue(methods.contains("device/list"))
        XCTAssertTrue(methods.contains("session/attach"))
        XCTAssertTrue(methods.contains("provider/create"))
        XCTAssertTrue(methods.contains("skill/install"))
        XCTAssertTrue(methods.contains("attachment/complete"))
        XCTAssertEqual(methods.count, 48)
    }

    /// v2 `turn/start` 的冻结响应体只有 `turn`（见 golden），不带 v1 的 `accepted`。
    /// 客户端必须容忍缺失字段，否则发送会以 “数据丢失” 的 DecodingError 失败。
    func testTurnStartResultDecodesWithoutAcceptedField() throws {
        let json = """
        {"turn":{"id":"t1","sessionId":"s1","status":"running"}}
        """
        let result = try JSONDecoder().decode(RACPTurnStartResult.self, from: Data(json.utf8))
        XCTAssertTrue(result.accepted)
        XCTAssertEqual(result.turn.id, "t1")
        XCTAssertEqual(result.turn.status, "running")
    }

    /// v1 旧 Host 仍会带 `accepted`，显式值必须被尊重。
    func testTurnStartResultHonoursExplicitAcceptedField() throws {
        let json = """
        {"accepted":false,"turn":{"id":"t2"}}
        """
        let result = try JSONDecoder().decode(RACPTurnStartResult.self, from: Data(json.utf8))
        XCTAssertFalse(result.accepted)
        XCTAssertEqual(result.turn.id, "t2")
    }
}
