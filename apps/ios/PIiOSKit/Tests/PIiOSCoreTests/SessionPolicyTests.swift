import XCTest
@testable import PIiOSCore

/// 本轮新增的纯逻辑：档位回落、决策可提交性、排队准入。
final class SessionPolicyTests: XCTestCase {
    // MARK: - AC-07.6 / AC-07.7 档位

    func testKeepsCurrentLevelWhenModelDeclaresIt() {
        let support = ThinkingLevelSupport(declared: [.off, .high], defaultLevel: .off)
        let result = ThinkingLevelPolicy.resolve(current: .high, support: support)
        XCTAssertEqual(result.level, .high)
        XCTAssertFalse(result.didFallback)
        XCTAssertNil(result.fallbackSource)
    }

    func testFallsBackToModelDefaultWhenCurrentLevelIsNotDeclared() {
        let support = ThinkingLevelSupport(declared: [.off, .high], defaultLevel: .high)
        let result = ThinkingLevelPolicy.resolve(current: .low, support: support)
        XCTAssertEqual(result.level, .high)
        XCTAssertTrue(result.didFallback)
        XCTAssertEqual(result.fallbackSource, .modelDefault)
    }

    func testFallsBackToFirstDeclaredWhenDefaultIsNotDeclared() {
        // 上游允许 defaultThinkingLevel 不在声明列表里；把它下发会被服务器拒绝。
        let support = ThinkingLevelSupport(declared: [.minimal, .medium], defaultLevel: .max)
        let result = ThinkingLevelPolicy.resolve(current: .xhigh, support: support)
        XCTAssertEqual(result.level, .minimal)
        XCTAssertTrue(result.didFallback)
        XCTAssertEqual(result.fallbackSource, .firstDeclared)
    }

    func testHidesPickerAndOmitsLevelWhenModelDeclaresNone() {
        let support = ThinkingLevelSupport(declared: [], defaultLevel: .high)
        XCTAssertFalse(ThinkingLevelPolicy.showsPicker(support))
        let result = ThinkingLevelPolicy.resolve(current: .high, support: support)
        XCTAssertNil(result.level)
        XCTAssertFalse(result.didFallback)
    }

    func testFallbackExplanationNamesBothLevels() {
        let text = ThinkingLevelPolicy.fallbackExplanation(from: .low, to: .high)
        XCTAssertEqual(text, "原档位「low」不被新模型声明，已改用「high」。")
    }

    func testFallbackExplanationDistinguishesMissingOriginalLevel() {
        XCTAssertEqual(
            ThinkingLevelPolicy.fallbackExplanation(
                from: nil,
                to: .high,
                fallbackSource: .modelDefault
            ),
            "会话原本没有档位，已采用模型默认档位「high」。"
        )
        XCTAssertEqual(
            ThinkingLevelPolicy.fallbackExplanation(
                from: nil,
                to: .low,
                fallbackSource: .firstDeclared
            ),
            "模型没有可用默认档位，已采用声明列表首项「low」。"
        )
    }

    // MARK: - AC-14.5 / AC-14.6 决策

    func testApprovalUsesItsOwnSnapshotRevision() {
        let card = RACPApprovalRequest(id: "ap_1", payload: .object(["id": .string("ap_1"), "revision": .number(7)]))
        let availability = DecisionPolicy.approvalAvailability(id: "ap_1", pending: [card], expiredIds: [])
        XCTAssertEqual(availability, .actionable(revision: 7))
    }

    func testMissingApprovalIsNotActionableAndNeverFallsBackToSessionRevision() {
        let availability = DecisionPolicy.approvalAvailability(id: "ap_gone", pending: [], expiredIds: ["ap_gone"])
        XCTAssertEqual(availability, .expired)
        XCTAssertFalse(availability.isActionable)
        XCTAssertNil(DecisionPolicy.approvalAvailability(id: "ap_unknown", pending: [], expiredIds: []).isActionable ? 1 : nil)
    }

    func testQueuedTurnDoesNotReplaceRunningTurnID() {
        XCTAssertEqual(
            TurnQueuePolicy.runningTurnIdAfterStart(
                current: "turn_running",
                startedTurnId: "turn_queued",
                admission: .queue
            ),
            "turn_running"
        )
        XCTAssertEqual(
            TurnQueuePolicy.runningTurnIdAfterStart(
                current: nil,
                startedTurnId: "turn_started",
                admission: nil
            ),
            "turn_started"
        )
    }

    func testInterruptRemainsAvailableWhenActiveItemsLackResolvedTurnID() {
        XCTAssertTrue(
            TurnQueuePolicy.canInterrupt(
                online: true,
                activeItemCount: 1,
                runningTurnId: nil
            )
        )
        XCTAssertFalse(
            TurnQueuePolicy.canInterrupt(
                online: false,
                activeItemCount: 1,
                runningTurnId: nil
            )
        )
    }

    func testStaleErrorMarksCardExpiredButTimeoutDoesNot() {
        XCTAssertTrue(DecisionPolicy.marksCardStale(after: .approvalStale))
        XCTAssertTrue(DecisionPolicy.marksCardStale(after: .approvalExpired))
        XCTAssertFalse(DecisionPolicy.marksCardStale(after: .unknown("TIMEOUT")))
        XCTAssertFalse(DecisionPolicy.marksCardStale(after: .rateLimited))
    }

    func testExplicitStaleMarkOverridesPendingUntilAuthoritativeSnapshot() {
        let model = SessionViewModel()
        let card = RACPApprovalRequest(id: "approval", payload: .object(["revision": .number(3)]))
        model.applySnapshot(RACPSnapshot(cursor: RACPCursor(epoch: "fixture", sequence: 1), revision: 30, pendingApprovals: [card]), replayComplete: true)
        XCTAssertTrue(DecisionPolicy.marksCardStale(after: .approvalStale))
        model.markApprovalExpired(id: card.id)
        XCTAssertEqual(DecisionPolicy.approvalAvailability(id: card.id, pending: model.pendingApprovals, expiredIds: model.expiredApprovalIds), .expired)
        XCTAssertFalse(model.pendingApprovals.isEmpty, "The explicit stale mark must win even before a new snapshot arrives")
        model.applySnapshot(RACPSnapshot(cursor: RACPCursor(epoch: "fixture", sequence: 2), revision: 31, pendingApprovals: [card]), replayComplete: true)
        model.markSnapshotExpiredApprovalsCleared()
        XCTAssertEqual(DecisionPolicy.approvalAvailability(id: card.id, pending: model.pendingApprovals, expiredIds: model.expiredApprovalIds), .expired, "Replaying the rejected card revision must not re-enable submission")
        let rebuilt = RACPApprovalRequest(id: card.id, payload: .object(["revision": .number(9)]))
        model.applySnapshot(RACPSnapshot(cursor: RACPCursor(epoch: "fixture", sequence: 2), revision: 40, pendingApprovals: [rebuilt]), replayComplete: false)
        XCTAssertEqual(DecisionPolicy.approvalAvailability(id: card.id, pending: model.pendingApprovals, expiredIds: model.expiredApprovalIds), .actionable(revision: 9))
    }

    func testContractModePrefersCurrentThenFirstAllowed() throws {
        let card = RACPApprovalRequest(id: "contract", payload: .object(["allowedPermissionModes": .array([.string("ask"), .string("auto")])]))
        XCTAssertEqual(try DecisionPolicy.contractAction(for: card, decision: .approve, currentMode: .auto), .contract(decision: .approve, permissionMode: .auto))
        XCTAssertEqual(try DecisionPolicy.contractAction(for: card, decision: .approve, currentMode: .acceptEdits), .contract(decision: .approve, permissionMode: .ask))
        XCTAssertEqual(try DecisionPolicy.contractAction(for: card, decision: .reject, currentMode: .auto), .contract(decision: .reject, permissionMode: .auto))
    }

    func testContractDecisionRejectsMissingEmptyOrUnknownModesForApproveAndReject() throws {
        let invalid: [JSONValue] = [.object([:]), .object(["allowedPermissionModes": .array([])]),
                                   .object(["allowedPermissionModes": .array([.string("ask"), .string("future")])]),
                                   .object(["allowedPermissionModes": .array([.number(1)])])]
        for payload in invalid {
            let card = RACPApprovalRequest(id: "contract", payload: payload)
            XCTAssertThrowsError(try DecisionPolicy.contractAction(for: card, decision: .approve, currentMode: .ask))
            XCTAssertThrowsError(try DecisionPolicy.contractAction(for: card, decision: .reject, currentMode: .ask))
        }
    }

    func testInputAvailabilityFollowsSnapshot() {
        let card = RACPInputRequest(id: "in_1", payload: .object(["id": .string("in_1"), "revision": .number(2)]))
        XCTAssertEqual(DecisionPolicy.inputAvailability(id: "in_1", pending: [card]), .actionable(revision: 2))
        XCTAssertEqual(DecisionPolicy.inputAvailability(id: "in_2", pending: [card]), .missing)
    }

    // MARK: - AC-13.1 / AC-13.2 排队

    func testQueueParsingDropsEntriesWithoutIdentifier() {
        let payloads: [JSONValue] = [
            .object(["id": .string("turn_1"), "text": .string("补充")]),
            .object(["text": .string("没有 id")]),
            .object(["id": .string("turn_1"), "text": .string("重复")]),
            .object(["id": .string("turn_2"), "input": .object(["text": .string("嵌套")])]),
        ]
        let parsed = QueuedTurn.parse(payloads)
        XCTAssertEqual(parsed.map(\.id), ["turn_1", "turn_2"])
        XCTAssertEqual(parsed[0].text, "补充")
        XCTAssertEqual(parsed[1].text, "嵌套")
    }

    func testAdmissionIsQueueWhileRunningAndBlockedOffline() {
        XCTAssertEqual(TurnQueuePolicy.admission(online: false, activeItemCount: 0, runningTurnId: nil), .blockedOffline)
        XCTAssertEqual(TurnQueuePolicy.admission(online: true, activeItemCount: 0, runningTurnId: nil), .start)
        XCTAssertEqual(
            TurnQueuePolicy.admission(online: true, activeItemCount: 1, runningTurnId: "turn_9"),
            .queue(runningTurnId: "turn_9")
        )
        XCTAssertNil(SendAdmission.start.turnAdmission)
        XCTAssertEqual(SendAdmission.queue(runningTurnId: nil).turnAdmission, .queue)
    }

    func testInterruptAndCancelRequireMatchingState() {
        XCTAssertFalse(TurnQueuePolicy.canInterrupt(online: true, runningTurnId: nil))
        XCTAssertTrue(TurnQueuePolicy.canInterrupt(online: true, runningTurnId: "turn_3"))
        XCTAssertFalse(TurnQueuePolicy.canInterrupt(online: false, runningTurnId: "turn_3"))
        let queued = [QueuedTurn(id: "turn_4")]
        XCTAssertTrue(TurnQueuePolicy.canCancel(queued: queued, id: "turn_4"))
        XCTAssertFalse(TurnQueuePolicy.canCancel(queued: queued, id: "turn_5"))
    }
}
