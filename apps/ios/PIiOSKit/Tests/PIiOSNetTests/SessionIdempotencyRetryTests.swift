import Foundation
import XCTest
import PIiOSCore
@testable import PIiOSNet

/// Boundary tests model pinned v0.21.0 approval results and input consumption.
final class SessionIdempotencyRetryTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL { directory.appendingPathComponent("request-keys.json") }
    private var store: SessionRequestKeyStore { SessionRequestKeyStore(fileURL: fileURL) }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func identity(_ action: SessionRequestAction) -> SessionRequestIdentity {
        SessionRequestIdentity(hostID: "fixture-host", sessionID: "fixture-session", itemID: itemID(action), action: action)
    }

    private func itemID(_ action: SessionRequestAction) -> String? {
        switch action {
        case .turn: return nil
        case .input: return "input"
        default: return "approval"
        }
    }

    func testTurnAcceptedBeforeTimeoutIsNotExecutedTwiceAfterRelaunch() throws {
        try verifyAcceptedRetry(.turn(text: "fixture message"))
    }

    func testApprovalAndContractReturnAlreadyResolvedAfterLostAcknowledgement() throws {
        try verifyAcceptedRetry(.approval(decision: .allowOnce, permissionMode: nil))
        try verifyAcceptedRetry(.contract(decision: .approve, permissionMode: .ask))
    }

    private func verifyAcceptedRetry(_ action: SessionRequestAction) throws {
        let first = try store.prepare(identity(action))
        let model = SessionViewModel()
        applySnapshot(to: model, revision: 3)
        let contract: Bool
        if case .contract = action { contract = true } else { contract = false }
        var host = FixtureHost(contract: contract)
        let original = try frame(action, attempt: first, model: model)
        XCTAssertThrowsError(try host.receive(original, dropResponse: true)) {
            XCTAssertEqual($0 as? RACPClientError, .timedOut("fixture response"))
        }
        let restarted = SessionRequestKeyStore(fileURL: fileURL)
        let retried = try restarted.prepare(identity(action), admission: .queue)
        XCTAssertEqual(retried, first)
        applySnapshot(to: model, revision: 9)
        let retry = try frame(action, attempt: retried, model: model, requestID: "retry")
        XCTAssertNotEqual(original.value(at: ["params", "context", "requestId"]), retry.value(at: ["params", "context", "requestId"]))
        let result = try host.receive(retry)
        if itemID(action) != nil {
            XCTAssertEqual(result.value(at: ["alreadyResolved"])?.boolValue, true)
            XCTAssertEqual(retry.value(at: ["params", "context", "expectedRevision"])?.intValue, 9)
        } else { XCTAssertNil(retry.value(at: ["params", "admission"])) }
        XCTAssertEqual(host.executionCount, 1)
        try restarted.acknowledge(retried)
        XCTAssertNotEqual(try store.prepare(identity(action)).idempotencyKey, first.idempotencyKey)
    }

    func testUnacceptedApprovalRetryUsesCurrentCardRevisionWithSameKey() throws {
        let action = SessionRequestAction.approval(decision: .allowOnce, permissionMode: nil)
        let first = try store.prepare(identity(action))
        let model = SessionViewModel()
        applySnapshot(to: model, revision: 3)
        var host = FixtureHost(approvalRevision: 9)
        assertCode(.approvalStale) { try host.receive(frame(action, attempt: first, model: model)) }
        XCTAssertEqual(host.executionCount, 0)
        applySnapshot(to: model, revision: 9)
        let retry = try store.prepare(identity(action))
        XCTAssertEqual(first, retry)
        _ = try host.receive(frame(action, attempt: retry, model: model))
        XCTAssertEqual(host.executionCount, 1)
    }

    func testAcceptedInputRetryReturnsNotFoundInsteadOfFakeDedupSuccess() throws {
        let action = SessionRequestAction.input(answers: [["fixture answer"], nil])
        let first = try store.prepare(identity(action))
        let model = SessionViewModel()
        applySnapshot(to: model, revision: 3)
        var host = FixtureHost()
        XCTAssertThrowsError(try host.receive(frame(action, attempt: first, model: model), dropResponse: true))
        let retry = try store.prepare(identity(action))
        assertCode(.notFound) { try host.receive(frame(action, attempt: retry, model: model)) }
        XCTAssertEqual(host.executionCount, 1)
        XCTAssertEqual(try store.prepare(identity(action)), first, "NOT_FOUND is not a success acknowledgement")
    }

    func testUndeliveredInputRetryCarriesCurrentRevisionAndUnchangedAnswers() throws {
        let action = SessionRequestAction.input(answers: [["fixture answer"], nil])
        let first = try store.prepare(identity(action))
        let model = SessionViewModel()
        applySnapshot(to: model, revision: 3)
        let original = try frame(action, attempt: first, model: model)
        // The first request never reached the Host, so it has no remembered result.
        applySnapshot(to: model, revision: 9)
        let retry = try store.prepare(identity(action))
        let updated = try frame(action, attempt: retry, model: model, requestID: "retry")
        XCTAssertEqual(first, retry)
        XCTAssertEqual(original.value(at: ["params", "answers"]), updated.value(at: ["params", "answers"]))
        XCTAssertEqual(updated.value(at: ["params", "context", "expectedRevision"])?.intValue, 9)
        var host = FixtureHost()
        XCTAssertEqual(try host.receive(updated).value(at: ["status"])?.stringValue, "resolved")
        try store.acknowledge(retry)
    }

    func testMissingDisallowedPermissionAndInvalidToolDecisionAreRejected() throws {
        let model = SessionViewModel()
        applySnapshot(to: model, revision: 3)
        let action = SessionRequestAction.contract(decision: .approve, permissionMode: .auto)
        let attempt = try store.prepare(identity(action))
        var host = FixtureHost(contract: true)
        assertCode(.invalidArgument) { try host.receive(frame(action, attempt: attempt, model: model)) }
        let missingMode = try encoded(.approvalRespond, RACPApprovalRespondParams(approvalId: "approval", contractDecision: .approve, context: RACPContext(requestId: "missing", idempotencyKey: attempt.idempotencyKey, expectedRevision: 3)), requestID: "missing")
        assertCode(.invalidArgument) { try host.receive(missingMode) }
        var tool = FixtureHost()
        assertCode(.invalidArgument) { try tool.receive(frame(action, attempt: attempt, model: model)) }
        XCTAssertEqual(host.executionCount + tool.executionCount, 0)
    }

    func testInvalidInputCountAndPayloadShapeAreRejected() throws {
        let model = SessionViewModel()
        applySnapshot(to: model, revision: 3)
        var host = FixtureHost()
        let action = SessionRequestAction.input(answers: [["one question"]])
        let attempt = try store.prepare(identity(action))
        assertCode(.invalidArgument) { try host.receive(frame(action, attempt: attempt, model: model)) }
        let malformed = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"method":"input/respond","params":{"inputId":"input","answers":["wrong",null],"context":{"requestId":"request","idempotencyKey":"key"}}}"#.utf8))
        assertCode(.invalidArgument) { try host.receive(malformed) }
        XCTAssertEqual(host.executionCount, 0)
    }

    func testPinnedHostDoesNotCompareInputExpectedRevision() throws {
        // v0.21.0 checks answer count but ignores input expectedRevision; do not invent a guard.
        let params = RACPInputRespondParams(inputId: "input", answers: [nil, nil], context: RACPContext(requestId: "request", idempotencyKey: "key", expectedRevision: 999))
        var host = FixtureHost()
        _ = try host.receive(encoded(.inputRespond, params, requestID: "request"))
        XCTAssertEqual(host.executionCount, 1)
    }

    func testTurnKeyReusedWithChangedPayloadConflicts() throws {
        let action = SessionRequestAction.turn(text: "first")
        let attempt = try store.prepare(identity(action))
        let model = SessionViewModel()
        var host = FixtureHost()
        _ = try host.receive(frame(action, attempt: attempt, model: model))
        assertCode(.idempotencyConflict) { try host.receive(frame(.turn(text: "changed"), attempt: attempt, model: model)) }
        XCTAssertEqual(host.executionCount, 1)
    }

    private func assertCode(_ code: RACPErrorCode, _ body: () throws -> JSONValue, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            guard case let RACPClientError.server(actual, _) = $0 else { return XCTFail("Expected server error", file: file, line: line) }
            XCTAssertEqual(actual, code, file: file, line: line)
        }
    }

    private func applySnapshot(to model: SessionViewModel, revision: Int) {
        model.applySnapshot(RACPSnapshot(cursor: RACPCursor(epoch: "fixture", sequence: revision), revision: 1000,
            pendingApprovals: [RACPApprovalRequest(id: "approval", payload: .object(["revision": .number(Double(revision))]))],
            pendingInputs: [RACPInputRequest(id: "input", payload: .object(["revision": .number(Double(revision))]))]), replayComplete: false)
    }

    private func encoded<P: Encodable>(_ method: RACPMethod, _ params: P, requestID: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(RACPRequest(id: .string(requestID), method: method, params: params)))
    }

    private func frame(_ action: SessionRequestAction, attempt: SessionRequestAttempt, model: SessionViewModel, requestID: String = "first") throws -> JSONValue {
        let revision = itemID(action) == "input" ? model.expectedRevisionForInput(id: "input") : model.expectedRevisionForApproval(id: "approval")
        let context = RACPContext(requestId: requestID, idempotencyKey: attempt.idempotencyKey, expectedRevision: revision)
        switch action {
        case .turn(let text):
            return try encoded(.turnStart, RACPTurnStartParams(sessionId: "fixture-session", admission: attempt.admission, input: RACPTurnInput(text: text), context: context), requestID: requestID)
        case .turnAttachments(let text, let attachmentIds):
            return try encoded(
                .turnStart,
                RACPTurnStartParams(
                    sessionId: "fixture-session",
                    admission: attempt.admission,
                    input: RACPTurnInput(
                        text: text,
                        attachments: attachmentIds.map(JSONValue.string)
                    ),
                    context: context
                ),
                requestID: requestID
            )
        case .approval, .contract:
            return try encoded(.approvalRespond, RACPApprovalRespondParams(approvalId: "approval", action: action, context: context), requestID: requestID)
        case .input(let answers):
            return try encoded(.inputRespond, RACPInputRespondParams(inputId: "input", answers: answers, context: context), requestID: requestID)
        }
    }
}

private struct FixtureHost {
    let contract: Bool
    let approvalRevision: Int
    private var turnInputs: [String: JSONValue] = [:]
    private var approvalResolved = false
    private var inputOpen = true
    private(set) var executionCount = 0

    init(contract: Bool = false, approvalRevision: Int = 3) {
        self.contract = contract
        self.approvalRevision = approvalRevision
    }

    mutating func receive(_ frame: JSONValue, dropResponse: Bool = false) throws -> JSONValue {
        func fail(_ code: RACPErrorCode) -> RACPClientError { .server(code: code, message: "fixture") }
        guard let method = frame.value(at: ["method"])?.stringValue, let params = frame.value(at: ["params"]),
              let requestID = params.value(at: ["context", "requestId"])?.stringValue, !requestID.isEmpty,
              let key = params.value(at: ["context", "idempotencyKey"])?.stringValue, !key.isEmpty
        else { throw fail(.invalidArgument) }
        let result: JSONValue
        switch method {
        case "turn/start":
            guard params.value(at: ["sessionId"])?.stringValue == "fixture-session",
                  let input = params.value(at: ["input"]), input.value(at: ["text"])?.stringValue != nil
            else { throw fail(.invalidArgument) }
            if let previous = turnInputs[key] {
                guard previous == input else { throw fail(.idempotencyConflict) }
            } else { turnInputs[key] = input; executionCount += 1 }
            result = .object(["accepted": .bool(true), "turn": .object(["id": .string("turn-fixture")])])
        case "approval/respond":
            guard params.value(at: ["approvalId"])?.stringValue == "approval" else { throw fail(.notFound) }
            if approvalResolved {
                result = .object(["approvalId": .string("approval"), "status": .string("resolved"), "alreadyResolved": .bool(true)])
            } else {
                if let expected = params.value(at: ["context", "expectedRevision"])?.intValue,
                   expected != approvalRevision { throw fail(.approvalStale) }
                guard let decision = params.value(at: ["decision"])?.stringValue,
                      (contract ? ["approve", "reject"] : ["allow-once", "allow-session", "deny"]).contains(decision)
                else { throw fail(.invalidArgument) }
                if contract && decision == "approve" {
                    guard params.value(at: ["permissionMode"])?.stringValue == "ask" else { throw fail(.invalidArgument) }
                }
                result = .object(["approvalId": .string("approval"), "status": .string("resolved"), "alreadyResolved": .bool(false)])
                approvalResolved = true
                executionCount += 1
            }
        case "input/respond":
            guard inputOpen, params.value(at: ["inputId"])?.stringValue == "input" else { throw fail(.notFound) }
            guard let answers = params.value(at: ["answers"])?.arrayValue, answers.count == 2,
                  answers.allSatisfy({ answer in
                      if answer == .null { return true }
                      guard let choices = answer.arrayValue else { return false }
                      return choices.allSatisfy { $0.stringValue != nil }
                  }) else { throw fail(.invalidArgument) }
            inputOpen = false
            executionCount += 1
            result = .object(["inputId": .string("input"), "status": .string("resolved")])
        default: throw fail(.methodNotFound)
        }
        if dropResponse { throw RACPClientError.timedOut("fixture response") }
        return result
    }
}
