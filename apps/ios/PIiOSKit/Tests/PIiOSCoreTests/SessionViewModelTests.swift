import XCTest

@testable import PIiOSCore

/// 契约 §3.2 / §6；spec AC-14.1 / AC-14.2 / AC-14.5 / AC-14.6。
final class SessionViewModelTests: XCTestCase {
    func testSnapshotRebuildClearsExpiredCursorWithoutDroppingCurrentView() {
        let model = SessionViewModel()
        let item = RACPItem(
            id: "item-1",
            payload: .object(["text": .string("keep me")])
        )
        _ = model.applyEvents([
            RACPEvent(sequence: 7, epoch: "epoch-1", item: item),
        ])
        XCTAssertEqual(model.items.count, 1)

        model.discardCursorForSnapshotRebuild()

        XCTAssertNil(model.cursor)
        XCTAssertEqual(model.items.count, 1)
        XCTAssertEqual(model.items.first?.id, "item-1")
    }

    func testAC14_4_changedDraftTextRotatesKeyButIdenticalTextKeepsIt() {
        let model = SessionViewModel()
        model.beginDraft(idempotencyKey: "draft-fixture", text: "fixture")
        model.updateDraft(text: "fixture")
        XCTAssertEqual(model.draft?.idempotencyKey, "draft-fixture")
        model.updateDraft(text: "edited fixture")
        let editedKey = model.draft?.idempotencyKey
        XCTAssertNotEqual(editedKey, "draft-fixture")
        model.updateDraft(text: "edited fixture")
        XCTAssertEqual(model.draft?.idempotencyKey, editedKey)
    }

    func testAC14_4_decisionsUseRebuiltCardRevisionAndNeverSessionRevision() {
        let model = SessionViewModel()
        for revision in [2, 9] {
            model.applySnapshot(
                RACPSnapshot(
                    cursor: RACPCursor(epoch: "fixture", sequence: revision), revision: 1000,
                    pendingApprovals: [approval("approval", revision: revision)],
                    pendingInputs: [RACPInputRequest(id: "input", payload: .object(["revision": .number(Double(revision + 1))]))]
                ), replayComplete: false
            )
            XCTAssertEqual(model.expectedRevisionForApproval(id: "approval"), revision)
            XCTAssertEqual(model.expectedRevisionForInput(id: "input"), revision + 1)
        }
        model.applySnapshot(RACPSnapshot(cursor: RACPCursor(epoch: "fixture", sequence: 20), revision: 2000), replayComplete: true)
        XCTAssertNil(model.expectedRevisionForApproval(id: "approval"))
        XCTAssertNil(model.expectedRevisionForInput(id: "input"))
    }

    // MARK: - 去重与游标（AC-14.1）

    func testAC14_1_deduplicatesItemsByID() {
        let viewModel = SessionViewModel()
        viewModel.applySnapshot(
            RACPSnapshot(cursor: RACPCursor(epoch: "ep_7f", sequence: 314), revision: 22, items: [item("itm_1", text: "a"), item("itm_2", text: "b")]),
            replayComplete: true
        )

        // 同一 id 的更新与新增混在一批里；同 id 不得产生重复行。
        let outcome = viewModel.applyEvents([
            RACPEvent(sequence: 315, epoch: "ep_7f", item: item("itm_1", text: "a-updated")),
            RACPEvent(sequence: 316, epoch: "ep_7f", item: item("itm_3", text: "c")),
            RACPEvent(sequence: 317, epoch: "ep_7f", item: item("itm_1", text: "a-updated")),
        ])

        XCTAssertEqual(viewModel.items.map(\.id), ["itm_1", "itm_2", "itm_3"])
        XCTAssertEqual(viewModel.item(id: "itm_1")?.text, "a-updated")
        XCTAssertEqual(viewModel.items.count, 3, "不得按追加顺序合并出重复条目")
        if case let .applied(appended, updated, ignored) = outcome {
            XCTAssertEqual(appended, 1)
            XCTAssertEqual(updated, 1)
            XCTAssertEqual(ignored, 1)
        } else {
            XCTFail("应正常应用事件：\(outcome)")
        }
        XCTAssertEqual(viewModel.cursor, RACPCursor(epoch: "ep_7f", sequence: 317))
    }

    func testAC14_1_ignoresStaleAndDuplicateSequences() {
        let viewModel = SessionViewModel()
        viewModel.applySnapshot(
            RACPSnapshot(cursor: RACPCursor(epoch: "ep_7f", sequence: 314), revision: 1),
            replayComplete: true
        )

        let duplicate = viewModel.applyEvents([RACPEvent(sequence: 314, epoch: "ep_7f", item: item("itm_old", text: "dup"))])
        XCTAssertEqual(duplicate, .applied(appended: 0, updated: 0, ignored: 1))
        XCTAssertEqual(viewModel.items, [])
        XCTAssertEqual(viewModel.cursor?.sequence, 314)

        viewModel.applyEvents([RACPEvent(sequence: 315, epoch: "ep_7f", item: item("itm_1", text: "x"))])
        let expired = viewModel.applyEvents([RACPEvent(sequence: 300, epoch: "ep_7f", item: item("itm_2", text: "stale"))])
        XCTAssertEqual(expired, .applied(appended: 0, updated: 0, ignored: 1))
        XCTAssertEqual(viewModel.items.map(\.id), ["itm_1"])
        XCTAssertEqual(viewModel.cursor?.sequence, 315)
    }

    func testAC14_1_decodesEventFrameAndItemPayloadVerbatim() throws {
        let json = """
        {"sequence":315,"epoch":"ep_7f","type":"item.updated","item":{
          "id":"itm_1","kind":"message","role":"assistant","text":"hi","toolName":"shell","status":"ok","extra":{"n":1}
        }}
        """
        let event = try JSONDecoder().decode(RACPEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.sequence, 315)
        XCTAssertEqual(event.epoch, "ep_7f")
        XCTAssertEqual(event.item?.id, "itm_1")
        XCTAssertEqual(event.item?.kind, "message")
        XCTAssertEqual(event.item?.role, "assistant")
        XCTAssertEqual(event.item?.text, "hi")
        XCTAssertEqual(event.item?.toolName, "shell")
        XCTAssertEqual(event.item?.status, "ok")
        // 未冻结字段原样保留
        XCTAssertEqual(event.item?.payload.value(at: ["extra", "n"])?.intValue, 1)
        XCTAssertEqual(event.payload.value(at: ["type"])?.stringValue, "item.updated")

        // 重新编码后保持同一形状
        let reencoded = try JSONEncoder().encode(event)
        let roundTrip = try JSONDecoder().decode(JSONValue.self, from: reencoded)
        XCTAssertEqual(roundTrip.value(at: ["item", "id"])?.stringValue, "itm_1")
        XCTAssertEqual(roundTrip.value(at: ["item", "extra", "n"])?.intValue, 1)
    }

    func testAC14_1_itemAccessorsAreOptionalForUnknownPayloads() {
        let bare = RACPItem(id: "itm_bare", payload: .object(["id": .string("itm_bare")]))
        XCTAssertNil(bare.kind)
        XCTAssertNil(bare.role)
        XCTAssertNil(bare.text)
        XCTAssertNil(bare.toolName)
        XCTAssertNil(bare.status)
    }

    func testHostItemSummaryProjectsCanonicalMessageContent() {
        let item = RACPItem(
            id: "msg_1",
            payload: .object([
                "id": .string("msg_1"),
                "turnId": .string("turn_1"),
                "itemType": .string("message"),
                "status": .string("completed"),
                "content": .object([
                    "id": .string("msg_1"),
                    "role": .string("assistant"),
                    "content": .string("真实 pi-host 回复"),
                    "status": .string("complete"),
                ]),
            ])
        )

        XCTAssertEqual(item.kind, "message")
        XCTAssertEqual(item.role, "assistant")
        XCTAssertEqual(item.text, "真实 pi-host 回复")
        XCTAssertEqual(item.status, "complete")
        XCTAssertEqual(item.turnId, "turn_1")
    }

    func testHostMessageEventAndDeltaProjectToSameCanonicalRow() throws {
        let start = try JSONDecoder().decode(
            RACPEvent.self,
            from: Data(
                #"{"sequence":1,"epoch":"ep","kind":"item.started","turnId":"turn_1","payload":{"itemType":"message","itemId":"msg_1","event":{"type":"message_start","message":{"id":"msg_1","role":"assistant","content":"","status":"streaming","createdAt":"2026-10-30T00:00:00Z"}}}}"#.utf8
            )
        )
        XCTAssertEqual(start.item?.role, "assistant")

        let model = SessionViewModel()
        model.applySnapshot(
            RACPSnapshot(cursor: RACPCursor(epoch: "ep", sequence: 0), revision: 0),
            replayComplete: true
        )
        model.applyEvents([start])
        let delta = try JSONDecoder().decode(
            RACPEvent.self,
            from: Data(
                #"{"afterSequence":1,"epoch":"ep","kind":"item.delta","turnId":"turn_1","payload":{"itemType":"message","itemId":"msg_1","event":{"type":"message_update","message":{"id":"msg_1","role":"assistant","content":"","status":"streaming","createdAt":"2026-10-30T00:00:00Z"},"deltaText":"真实回复"}}}"#.utf8
            )
        )
        XCTAssertEqual(delta.item?.id, "msg_1")
    }

    // MARK: - 快照整体替换（AC-14.2）

    func testAC14_2_snapshotReplacesWholeViewAndDropsDraft() {
        let viewModel = SessionViewModel()
        viewModel.applySnapshot(
            RACPSnapshot(
                cursor: RACPCursor(epoch: "ep_7f", sequence: 314),
                revision: 22,
                items: [item("itm_1", text: "a"), item("itm_2", text: "b"), item("itm_3", text: "c")],
                activeItems: [item("itm_3", text: "c")],
                pendingInputs: [RACPInputRequest(id: "inp_1", payload: .object(["id": .string("inp_1")]))],
                hasMoreHistory: true
            ),
            replayComplete: true
        )
        viewModel.beginDraft(idempotencyKey: "idem_1", text: "半截输入")
        viewModel.updateDraft(text: "半截输入，正在流式")

        let outcome = viewModel.applySnapshot(
            RACPSnapshot(
                cursor: RACPCursor(epoch: "ep_80", sequence: 1),
                revision: 23,
                items: [item("itm_9", text: "rebuild")],
                hasMoreHistory: false
            ),
            replayComplete: false
        )

        XCTAssertEqual(viewModel.items.map(\.id), ["itm_9"], "必须整体替换，不做合并")
        XCTAssertEqual(viewModel.activeItems, [])
        XCTAssertEqual(viewModel.pendingInputs, [])
        XCTAssertFalse(viewModel.hasMoreHistory)
        XCTAssertEqual(viewModel.revision, 23)
        XCTAssertEqual(viewModel.cursor, RACPCursor(epoch: "ep_80", sequence: 1))
        XCTAssertNil(viewModel.draft, "快照重建必须丢弃未完成草稿")
        XCTAssertTrue(outcome.discardedDraft)
        XCTAssertFalse(viewModel.lastReplayComplete)
        // 旧 item 不能残留
        XCTAssertNil(viewModel.item(id: "itm_1"))
    }

    func testAC14_2_epochChangeRequiresSnapshotRebuild() {
        let viewModel = SessionViewModel()
        viewModel.applySnapshot(
            RACPSnapshot(cursor: RACPCursor(epoch: "ep_7f", sequence: 314), revision: 22, items: [item("itm_1", text: "a")]),
            replayComplete: true
        )

        let outcome = viewModel.applyEvents([RACPEvent(sequence: 1, epoch: "ep_9a", item: item("itm_2", text: "b"))])
        XCTAssertEqual(outcome, .requiresSnapshotRebuild(.epochChanged(from: "ep_7f", to: "ep_9a")))
        XCTAssertTrue(outcome.needsRebuild)
        XCTAssertEqual(viewModel.items.map(\.id), ["itm_1"], "epoch 变化时不得就地应用事件")
        XCTAssertEqual(viewModel.cursor?.epoch, "ep_7f", "游标只在快照重建后更新")
    }

    func testSnapshotActiveTurnSurvivesEmptyActiveItems() {
        let viewModel = SessionViewModel()
        viewModel.applySnapshot(
            RACPSnapshot(
                cursor: RACPCursor(epoch: "ep_turn", sequence: 1),
                revision: 1,
                activeItems: [],
                activeTurn: RACPTurnRef(id: "turn_waiting", status: "waiting_approval")
            ),
            replayComplete: true
        )

        XCTAssertEqual(viewModel.activeTurnId, "turn_waiting")
    }

    func testTurnLifecyclePromotesQueuedTurnAndIgnoresLateOldCompletion() {
        let viewModel = SessionViewModel()
        viewModel.applySnapshot(
            RACPSnapshot(
                cursor: RACPCursor(epoch: "ep_turn", sequence: 10),
                revision: 1,
                activeTurn: RACPTurnRef(id: "turn_a", status: "running")
            ),
            replayComplete: true
        )

        viewModel.applyEvents([
            RACPEvent(
                sequence: 11,
                epoch: "ep_turn",
                payload: .object([
                    "kind": .string("turn.completed"),
                    "turnId": .string("turn_a"),
                ])
            ),
            RACPEvent(
                sequence: 12,
                epoch: "ep_turn",
                payload: .object([
                    "kind": .string("turn.started"),
                    "turnId": .string("turn_q"),
                ])
            ),
            RACPEvent(
                sequence: 13,
                epoch: "ep_turn",
                payload: .object([
                    "kind": .string("turn.completed"),
                    "turnId": .string("turn_a"),
                ])
            ),
        ])

        XCTAssertEqual(viewModel.activeTurnId, "turn_q")
    }

    func testQueuedTurnDoesNotBecomeActiveUntilStartedEvent() {
        let viewModel = SessionViewModel()
        viewModel.applySnapshot(
            RACPSnapshot(
                cursor: RACPCursor(epoch: "ep_turn", sequence: 20),
                revision: 1
            ),
            replayComplete: true
        )

        viewModel.applyEvents([
            RACPEvent(
                sequence: 21,
                epoch: "ep_turn",
                payload: .object([
                    "kind": .string("turn.queued"),
                    "turnId": .string("turn_q"),
                ])
            )
        ])
        XCTAssertNil(viewModel.activeTurnId)
        XCTAssertEqual(viewModel.queuedTurns.count, 1)

        viewModel.applyEvents([
            RACPEvent(
                sequence: 22,
                epoch: "ep_turn",
                payload: .object([
                    "kind": .string("turn.started"),
                    "turnId": .string("turn_q"),
                ])
            )
        ])
        XCTAssertEqual(viewModel.activeTurnId, "turn_q")
        XCTAssertTrue(viewModel.queuedTurns.isEmpty)
    }

    func testInputRequestedAndResolvedReduceIntoPendingInputs() {
        let viewModel = SessionViewModel()
        viewModel.applySnapshot(
            RACPSnapshot(cursor: RACPCursor(epoch: "ep_input", sequence: 40), revision: 1),
            replayComplete: true
        )

        viewModel.applyEvents([
            RACPEvent(
                sequence: 41,
                epoch: "ep_input",
                payload: .object([
                    "kind": .string("input.requested"),
                    "payload": .object([
                        "input": .object([
                            "id": .string("inp_1"),
                            "revision": .number(5),
                            "questions": .array([]),
                        ])
                    ]),
                ])
            )
        ])
        XCTAssertEqual(viewModel.pendingInputs.map(\.id), ["inp_1"])
        XCTAssertEqual(viewModel.expectedRevisionForInput(id: "inp_1"), 5)

        viewModel.applyEvents([
            RACPEvent(
                sequence: 42,
                epoch: "ep_input",
                payload: .object([
                    "kind": .string("input.resolved"),
                    "payload": .object([
                        "inputId": .string("inp_1"),
                        "status": .string("answered"),
                    ]),
                ])
            )
        ])
        XCTAssertTrue(viewModel.pendingInputs.isEmpty)
    }

    func testAC14_1_sequenceGapInGlobalCursorDoesNotForceRebuild() {
        // `sequence` 是全局持久游标（契约 §3.2）：本会话订阅只会收到本会话事件，
        // 其它会话/主机事件的序号会穿插进来。因此「本会话序号跳号」是常态，
        // 不得据此触发重建；真正的缺口由服务端 CURSOR_EXPIRED 告知。
        let viewModel = SessionViewModel()
        viewModel.applySnapshot(
            RACPSnapshot(
                cursor: RACPCursor(epoch: "ep_7f", sequence: 100),
                revision: 1,
                items: [item("itm_0", text: "baseline")]
            ),
            replayComplete: true
        )

        let outcome = viewModel.applyEvents([
            RACPEvent(sequence: 101, epoch: "ep_7f", item: item("itm_1", text: "first")),
            RACPEvent(sequence: 103, epoch: "ep_7f", item: item("itm_3", text: "gap")),
        ])

        XCTAssertEqual(outcome, .applied(appended: 2, updated: 0, ignored: 0))
        XCTAssertEqual(viewModel.items.map(\.id), ["itm_0", "itm_1", "itm_3"])
        XCTAssertEqual(viewModel.cursor?.sequence, 103, "跳号事件仍按顺序推进游标")
    }

    func testTurnLifecycleSupportsContractNestedTurnPayloadAndClearsActiveItems() throws {
        let viewModel = SessionViewModel()
        let activeItem = try RACPItem(payload: .object([
            "id": .string("msg_active"),
            "itemType": .string("assistant_message"),
            "status": .string("streaming"),
            "text": .string("generating..."),
        ]))
        viewModel.applySnapshot(
            RACPSnapshot(
                cursor: RACPCursor(epoch: "ep_turn", sequence: 10),
                revision: 1,
                activeItems: [activeItem],
                activeTurn: RACPTurnRef(id: "turn_nested", status: "running")
            ),
            replayComplete: true
        )
        XCTAssertEqual(viewModel.activeTurnId, "turn_nested")
        XCTAssertEqual(viewModel.activeItems.count, 1)

        // Golden shape: nested under payload.turn.id, with no root turnId
        viewModel.applyEvents([
            RACPEvent(
                sequence: 11,
                epoch: "ep_turn",
                payload: .object([
                    "kind": .string("turn.completed"),
                    "payload": .object([
                        "turn": .object([
                            "id": .string("turn_nested"),
                            "status": .string("completed")
                        ])
                    ])
                ])
            )
        ])

        XCTAssertNil(viewModel.activeTurnId)
        XCTAssertTrue(viewModel.activeItems.isEmpty, "Active items must be cleared when turn settles")
    }

    func testInitialItemDeltaAppliesDeltaTextEvenWhenItemNotYetInIndex() throws {
        let viewModel = SessionViewModel()
        viewModel.applySnapshot(
            RACPSnapshot(cursor: RACPCursor(epoch: "ep_delta", sequence: 50), revision: 1),
            replayComplete: true
        )

        let initialItem = try RACPItem(payload: .object([
            "id": .string("msg_first_chunk"),
            "itemType": .string("assistant_message"),
            "status": .string("streaming"),
            "text": .string(""),
        ]))

        viewModel.applyEvents([
            RACPEvent(
                sequence: 51,
                epoch: "ep_delta",
                item: initialItem,
                payload: .object([
                    "kind": .string("item.delta"),
                    "payload": .object([
                        "delta": .string("Hello ")
                    ])
                ])
            )
        ])

        XCTAssertEqual(viewModel.items.count, 1)
        XCTAssertEqual(viewModel.items.first?.text, "Hello ")
    }

    func testSessionSwitchResetDropsPriorApprovalsCursorAndDraft() {
        let viewModel = SessionViewModel()
        viewModel.applySnapshot(
            RACPSnapshot(
                cursor: RACPCursor(epoch: "ep_session_a", sequence: 41),
                revision: 7,
                items: [item("itm_a", text: "A")],
                activeItems: [item("itm_a", text: "A running")],
                pendingApprovals: [approval("approval_a", revision: 3)],
                hasMoreHistory: true
            ),
            replayComplete: false
        )
        viewModel.beginDraft(idempotencyKey: "draft_a", text: "A draft")

        viewModel.resetForSession()

        XCTAssertNil(viewModel.cursor)
        XCTAssertEqual(viewModel.revision, 0)
        XCTAssertEqual(viewModel.items, [])
        XCTAssertEqual(viewModel.activeItems, [])
        XCTAssertEqual(viewModel.pendingApprovals, [])
        XCTAssertNil(viewModel.draft)
        XCTAssertFalse(viewModel.hasMoreHistory)
        XCTAssertFalse(viewModel.lastReplayComplete)
        XCTAssertTrue(viewModel.expiredApprovalIds.isEmpty)
    }

    func testAC14_2_decodesContractSnapshotShape() throws {
        let json = """
        {
          "cursor": { "epoch": "ep_7f", "sequence": 314 },
          "revision": 22,
          "items": [],
          "activeItems": [],
          "queuedTurns": [],
          "pendingApprovals": [],
          "pendingInputs": [],
          "hasMoreHistory": true
        }
        """
        let snapshot = try JSONDecoder().decode(RACPSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.cursor, RACPCursor(epoch: "ep_7f", sequence: 314))
        XCTAssertEqual(snapshot.revision, 22)
        XCTAssertEqual(snapshot.items, [])
        XCTAssertTrue(snapshot.hasMoreHistory)

        let viewModel = SessionViewModel()
        viewModel.applySnapshot(snapshot, replayComplete: true)
        XCTAssertEqual(viewModel.cursor?.sequence, 314)
        XCTAssertTrue(viewModel.hasMoreHistory)
        XCTAssertTrue(viewModel.lastReplayComplete)
    }

    func testAC14_2_snapshotDropsDuplicateItemIds() throws {
        let json = """
        {"cursor":{"epoch":"ep_1","sequence":1},"revision":1,
         "items":[{"id":"itm_1","text":"first"},{"id":"itm_1","text":"second"}]}
        """
        let snapshot = try JSONDecoder().decode(RACPSnapshot.self, from: Data(json.utf8))
        let viewModel = SessionViewModel()
        viewModel.applySnapshot(snapshot, replayComplete: true)
        XCTAssertEqual(viewModel.items.count, 1)
        XCTAssertEqual(viewModel.items.first?.text, "first")
    }

    // MARK: - 审批卡（AC-14.5 / AC-14.6）

    func testAC14_5_pendingApprovalsRebuiltFromSnapshotAndStaleMarked() {
        let viewModel = SessionViewModel()
        viewModel.applySnapshot(
            RACPSnapshot(
                cursor: RACPCursor(epoch: "ep_7f", sequence: 314),
                revision: 22,
                pendingApprovals: [
                    approval("ap_a", revision: 5),
                    approval("ap_b", revision: 6),
                ]
            ),
            replayComplete: true
        )

        // 离线期间留下的两张卡，重建后只剩 ap_b（revision 变成 9）。
        let outcome = viewModel.applySnapshot(
            RACPSnapshot(
                cursor: RACPCursor(epoch: "ep_80", sequence: 1),
                revision: 30,
                pendingApprovals: [approval("ap_b", revision: 9)]
            ),
            replayComplete: false
        )

        XCTAssertEqual(viewModel.pendingApprovals.map(\.id), ["ap_b"])
        XCTAssertEqual(outcome.newlyExpiredApprovalIds, ["ap_a"])
        XCTAssertEqual(viewModel.expiredApprovalIds, Set(["ap_a"]), "已失效的卡片应显示为过期而不是可点击")
        XCTAssertTrue(viewModel.pendingApprovals.allSatisfy { !viewModel.expiredApprovalIds.contains($0.id) })
    }

    func testAC14_6_approvalRevisionComesFromSnapshot() {
        let viewModel = SessionViewModel()
        viewModel.applySnapshot(
            RACPSnapshot(
                cursor: RACPCursor(epoch: "ep_80", sequence: 1),
                revision: 30,
                pendingApprovals: [approval("ap_b", revision: 9)]
            ),
            replayComplete: false
        )
        XCTAssertEqual(viewModel.expectedRevisionForApproval(id: "ap_b"), 9, "必须用快照里该卡的 revision")
        XCTAssertNil(viewModel.expectedRevisionForApproval(id: "ap_missing"))
        XCTAssertEqual(viewModel.approval(id: "ap_b")?.revision, 9)
        XCTAssertEqual(viewModel.approval(id: "ap_b")?.status, "pending")
    }

    // MARK: - 审查返工（fix 4 / 5）

    func testFix4_staleEpochReplayDoesNotForceRebuildOrDropDraft() {
        let viewModel = SessionViewModel()
        viewModel.applySnapshot(
            RACPSnapshot(cursor: RACPCursor(epoch: "ep_7f", sequence: 314), revision: 22, items: [item("itm_1", text: "a")]),
            replayComplete: true
        )
        // 重建到新 epoch：ep_7f 变成陈旧 epoch。
        viewModel.applySnapshot(
            RACPSnapshot(cursor: RACPCursor(epoch: "ep_80", sequence: 1), revision: 23, items: [item("itm_9", text: "b")]),
            replayComplete: true
        )
        viewModel.beginDraft(idempotencyKey: "idem_1", text: "还没发出去")

        let outcome = viewModel.applyEvents([RACPEvent(sequence: 315, epoch: "ep_7f", item: item("itm_old", text: "replay"))])

        XCTAssertEqual(outcome, .applied(appended: 0, updated: 0, ignored: 1), "旧 epoch 的重放帧必须丢弃：\(outcome)")
        XCTAssertFalse(outcome.needsRebuild, "旧 epoch 的重放帧不得要求重建")
        XCTAssertEqual(viewModel.cursor, RACPCursor(epoch: "ep_80", sequence: 1))
        XCTAssertNotNil(viewModel.draft, "不得因旧 epoch 重放触发重建而清空未发送草稿")
        XCTAssertEqual(viewModel.items.map(\.id), ["itm_9"])
    }

    func testFix5_reappearingApprovalIsNoLongerMarkedExpired() {
        let viewModel = SessionViewModel()
        viewModel.applySnapshot(
            RACPSnapshot(
                cursor: RACPCursor(epoch: "ep_7f", sequence: 314),
                revision: 22,
                pendingApprovals: [approval("ap_a", revision: 5), approval("ap_stale", revision: 2)]
            ),
            replayComplete: true
        )
        // 重建后 ap_a 与 ap_stale 都不在快照里：两张卡都标过期。
        viewModel.applySnapshot(
            RACPSnapshot(cursor: RACPCursor(epoch: "ep_80", sequence: 1), revision: 30, pendingApprovals: []),
            replayComplete: false
        )
        XCTAssertEqual(viewModel.expiredApprovalIds, Set(["ap_a", "ap_stale"]))

        // ap_a 重新出现在快照里：必须恢复成可点击，不能一直标过期。
        viewModel.applySnapshot(
            RACPSnapshot(
                cursor: RACPCursor(epoch: "ep_80", sequence: 2),
                revision: 31,
                pendingApprovals: [approval("ap_a", revision: 7)]
            ),
            replayComplete: false
        )
        XCTAssertEqual(viewModel.expiredApprovalIds, Set(["ap_stale"]), "现存于快照的卡片不得再标过期")
        XCTAssertEqual(viewModel.expectedRevisionForApproval(id: "ap_a"), 7)
    }

    // MARK: - 工具

    private func item(_ id: String, text: String) -> RACPItem {
        RACPItem(id: id, payload: .object(["id": .string(id), "text": .string(text)]))
    }

    /// 修复：工具的审批是实时 session 事件（不是历史条目）。客户端若不归约
    /// `approval.requested`，卡片永远不出现，工具调用会一直等一个无法做出的决定。
    func testLiveApprovalRequestedEventSurfacesCard() {
        let model = SessionViewModel()
        let outcome = model.applyEvents([approvalEvent(kind: "approval.requested", sequence: 31, id: "ap_live", revision: 4)])
        XCTAssertEqual(outcome, .applied(appended: 0, updated: 0, ignored: 0))
        XCTAssertEqual(model.pendingApprovals.map(\.id), ["ap_live"])
        XCTAssertEqual(model.expectedRevisionForApproval(id: "ap_live"), 4)
    }

    func testLiveApprovalResolvedEventRemovesCard() {
        let model = SessionViewModel()
        model.applyEvents([approvalEvent(kind: "approval.requested", sequence: 31, id: "ap_live", revision: 1)])
        XCTAssertEqual(model.pendingApprovals.count, 1)
        model.applyEvents([approvalEvent(kind: "approval.resolved", sequence: 32, id: "ap_live", revision: 1)])
        XCTAssertTrue(model.pendingApprovals.isEmpty)
    }

    private func approvalEvent(kind: String, sequence: Int, id: String, revision: Int) -> RACPEvent {
        let inner: [String: JSONValue] = kind == "approval.requested"
            ? ["approval": .object([
                "id": .string(id),
                "revision": .number(Double(revision)),
                "kind": .string("tool"),
                "title": .string("bash"),
                "input": .object(["command": .string("echo hi")]),
                "expiresAt": .null,
            ])]
            : ["approvalId": .string(id), "status": .string("allowed")]
        return RACPEvent(
            sequence: sequence,
            epoch: "ep_live",
            payload: .object([
                "kind": .string(kind),
                "sequence": .number(Double(sequence)),
                "epoch": .string("ep_live"),
                "sessionId": .string("ses_1"),
                "payload": .object(inner),
            ])
        )
    }

    /// 返工复审新增：同一张卡消失只上报一次。
    ///
    /// 重复 attach / 重建时，界面若把累计过期集合当作「新失效」上报，会反复弹同一条提示。
    func testFix20_newlyExpiredApprovalIsReportedOnce() {
        let viewModel = SessionViewModel()
        viewModel.applySnapshot(
            RACPSnapshot(
                cursor: RACPCursor(epoch: "ep_1", sequence: 5),
                revision: 3,
                pendingApprovals: [approval("ap_1", revision: 1)]
            ),
            replayComplete: true
        )

        let first = viewModel.applySnapshot(
            RACPSnapshot(cursor: RACPCursor(epoch: "ep_1", sequence: 6), revision: 4, pendingApprovals: []),
            replayComplete: false
        )
        XCTAssertEqual(first.newlyExpiredApprovalIds, ["ap_1"])

        let second = viewModel.applySnapshot(
            RACPSnapshot(cursor: RACPCursor(epoch: "ep_1", sequence: 7), revision: 5, pendingApprovals: []),
            replayComplete: false
        )
        XCTAssertEqual(second.newlyExpiredApprovalIds, [], "同一张失效卡不得被重复上报为新失效")
        XCTAssertEqual(viewModel.expiredApprovalIds, Set(["ap_1"]), "累计过期集合仍保留该卡，用于置灰")
    }

    private func approval(_ id: String, revision: Int) -> RACPApprovalRequest {
        RACPApprovalRequest(
            id: id,
            payload: .object([
                "id": .string(id),
                "revision": .number(Double(revision)),
                "status": .string("pending"),
            ])
        )
    }
}
