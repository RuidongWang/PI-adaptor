import XCTest
@testable import PIiOSCore
@testable import PIiOSNet

/// 本轮新增的线缆形状测试：撤销配对与提问回答必须与冻结契约逐字一致。
///
/// 断言走解码后的结构，而不是原始字符串：`JSONEncoder` 会把 `/` 转义成 `\/`，
/// 拿字符串比对会把「编码器行为」当成契约失败。
final class RACPCommandWireTests: XCTestCase {
    func testContractApprovalGoldenUsesTheResolvedActionModeAndCardRevision() throws {
        let card = RACPApprovalRequest(id: "contract_1", payload: .object([
            "revision": .number(7), "allowedPermissionModes": .array([.string("ask"), .string("auto")]),
        ]))
        for (current, expected) in [(RACPPermissionMode.auto, "auto"), (.acceptEdits, "ask")] {
            let action = try DecisionPolicy.contractAction(for: card, decision: .approve, currentMode: current)
            let params = try RACPApprovalRespondParams(approvalId: card.id, action: action, context: RACPContext(requestId: "request_1", idempotencyKey: "key_1", expectedRevision: card.revision))
            let actual = try JSONSerialization.data(withJSONObject: encodedObject(.approvalRespond, params: params), options: [.sortedKeys])
            let golden = Data(#"{"id":1,"jsonrpc":"2.0","method":"approval/respond","params":{"approvalId":"contract_1","context":{"expectedRevision":7,"idempotencyKey":"key_1","requestId":"request_1"},"decision":"approve","permissionMode":"\#(expected)"}}"#.utf8)
            XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: actual), try JSONDecoder().decode(JSONValue.self, from: golden))
        }
    }

    func testContractDecisionAlwaysCarriesPermissionMode() throws {
        let context = RACPContext(requestId: "request_1", idempotencyKey: "key_1", expectedRevision: 7)
        let rejection = try RACPApprovalRespondParams(
            approvalId: "contract_1",
            action: .contract(decision: .reject, permissionMode: .ask),
            context: context
        )
        let actual = try JSONSerialization.data(withJSONObject: encodedObject(.approvalRespond, params: rejection))
        let golden = Data(#"{"id":1,"jsonrpc":"2.0","method":"approval/respond","params":{"approvalId":"contract_1","context":{"expectedRevision":7,"idempotencyKey":"key_1","requestId":"request_1"},"decision":"reject","permissionMode":"ask"}}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: actual), try JSONDecoder().decode(JSONValue.self, from: golden))
        XCTAssertThrowsError(try RACPApprovalRespondParams(approvalId: "contract_1", action: .contract(decision: .approve), context: context))
        XCTAssertThrowsError(try RACPApprovalRespondParams(approvalId: "contract_1", action: .contract(decision: .reject), context: context))
    }

    private func encodedObject<P: Encodable>(_ method: RACPMethod, params: P) throws -> [String: Any] {
        let request = RACPRequest(id: .number(1), method: method, params: params)
        let data = try JSONEncoder().encode(request)
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any])
    }

    func testSessionRevokeCarriesSavedDeviceId() throws {
        let object = try encodedObject(.sessionRevoke, params: RACPSessionRevokeParams(deviceId: "dev_abc"))
        XCTAssertEqual(object["method"] as? String, "session/revoke")
        let params = try XCTUnwrap(object["params"] as? [String: Any])
        XCTAssertEqual(params["deviceId"] as? String, "dev_abc")
    }

    func testInputAnswersEncodeArraysAndSkips() throws {
        let params = RACPInputRespondParams(
            inputId: "in_1",
            answers: [["yes"], nil],
            context: RACPContext(requestId: "req_1", idempotencyKey: "key_1")
        )
        let object = try encodedObject(.inputRespond, params: params)
        XCTAssertEqual(object["method"] as? String, "input/respond")
        let payload = try XCTUnwrap(object["params"] as? [String: Any])
        let answers = try XCTUnwrap(payload["answers"] as? [Any])
        XCTAssertEqual(answers.count, 2)
        XCTAssertEqual(answers[0] as? [String], ["yes"], "每题是一组标签，不是单个标签")
        XCTAssertTrue(answers[1] is NSNull, "未作答必须是 null")
    }

    func testTurnStartPutsIdempotencyKeyOnlyInContext() throws {
        let params = RACPTurnStartParams(
            sessionId: "ses_1",
            admission: .queue,
            input: RACPTurnInput(text: "继续"),
            context: RACPContext(requestId: "req_2", idempotencyKey: "turn_key")
        )
        let object = try encodedObject(.turnStart, params: params)
        let payload = try XCTUnwrap(object["params"] as? [String: Any])
        XCTAssertEqual(payload["admission"] as? String, "queue")
        XCTAssertNil(payload["idempotencyKey"], "幂等键只能出现在 context 内")
        let context = try XCTUnwrap(payload["context"] as? [String: Any])
        XCTAssertEqual(context["idempotencyKey"] as? String, "turn_key")
        let input = try XCTUnwrap(payload["input"] as? [String: Any])
        XCTAssertEqual((input["attachments"] as? [Any])?.count, 0, "P0 恒为空数组")
    }

    func testTurnInterruptAddressesTurnById() throws {
        let params = RACPTurnIDParams(
            turnId: "turn_9",
            context: RACPContext(requestId: "req_9", idempotencyKey: nil)
        )
        let object = try encodedObject(.turnInterrupt, params: params)
        XCTAssertEqual(object["method"] as? String, "turn/interrupt")
        let payload = try XCTUnwrap(object["params"] as? [String: Any])
        XCTAssertEqual(payload["turnId"] as? String, "turn_9")
        XCTAssertNotNil(payload["context"], "v2 契约要求写操作携带 context")
    }

    func testSessionConfigureSendsModelThinkingAndPermissionMode() throws {
        let params = RACPSessionConfigureParams(
            sessionId: "ses_1",
            providerId: "prv_1",
            modelId: "model_a",
            thinkingLevel: .high,
            permissionMode: .acceptEdits
        )
        let object = try encodedObject(.sessionConfigure, params: params)
        XCTAssertEqual(object["method"] as? String, "session/configure")
        let payload = try XCTUnwrap(object["params"] as? [String: Any])
        XCTAssertEqual(payload["sessionId"] as? String, "ses_1")
        XCTAssertEqual(payload["providerId"] as? String, "prv_1")
        XCTAssertEqual(payload["modelId"] as? String, "model_a")
        XCTAssertEqual(payload["thinkingLevel"] as? String, "high")
        XCTAssertEqual(payload["permissionMode"] as? String, "accept-edits")
    }

    func testSessionConfigureOmitsThinkingForModelWithoutLevels() throws {
        let params = RACPSessionConfigureParams(
            sessionId: "ses_1",
            providerId: "prv_1",
            modelId: "model_b"
        )
        let object = try encodedObject(.sessionConfigure, params: params)
        let payload = try XCTUnwrap(object["params"] as? [String: Any])
        XCTAssertNil(payload["thinkingLevel"])
    }

    func testProviderOperationsUseTenSecondUserVisibleBudget() {
        XCTAssertEqual(RemoteProviderOperations.userVisibleTimeout, 10)
    }
}
