import XCTest

@testable import PIiOSCore

/// 工具卡片正文（回归：卡片只显示「服务器没有返回工具输出正文。」）。
///
/// 契约 §7.2 只冻结了三类工具帧的载荷：
/// `tool.started {itemId,toolName,input}`、`tool.updated {itemId,delta}`、
/// `tool.completed {itemId,status,result}`。因此 `toolName` 只在第一帧出现，
/// 结果正文只在最后一帧的 `result`（Pi 的 `AgentToolResult`）里出现——
/// 归约器必须把两者都落到同一条 `item.id` 上，否则卡片既丢工具名也丢正文。
final class ToolItemFrameTests: XCTestCase {
    private let cursorEpoch = "ep_tool"

    private func event(_ json: String) throws -> RACPEvent {
        try JSONDecoder().decode(RACPEvent.self, from: Data(json.utf8))
    }

    private func toolStarted(sequence: Int, toolName: String = "bash") throws -> RACPEvent {
        try event(
            """
            {"scope":"session","kind":"tool.started","sessionId":"sess_1","turnId":"turn_1",
             "epoch":"\(cursorEpoch)","sequence":\(sequence),
             "payload":{"itemId":"call_1","toolName":"\(toolName)","input":{"command":"echo hello-from-tool"}}}
            """
        )
    }

    private func toolUpdated(sequence: Int, delta: String) throws -> RACPEvent {
        try event(
            """
            {"scope":"session","kind":"tool.updated","sessionId":"sess_1","turnId":"turn_1",
             "epoch":"\(cursorEpoch)","sequence":\(sequence),
             "payload":{"itemId":"call_1","delta":"\(delta)"}}
            """
        )
    }

    private func toolCompleted(sequence: Int, status: String, result: String) throws -> RACPEvent {
        try event(
            """
            {"scope":"session","kind":"tool.completed","sessionId":"sess_1","turnId":"turn_1",
             "epoch":"\(cursorEpoch)","sequence":\(sequence),
             "payload":{"itemId":"call_1","status":"\(status)","result":\(result)}}
            """
        )
    }

    private func model() -> SessionViewModel {
        let model = SessionViewModel()
        model.applySnapshot(
            RACPSnapshot(cursor: RACPCursor(epoch: cursorEpoch, sequence: 0), revision: 1),
            replayComplete: true
        )
        return model
    }

    /// `tool.completed` 必须把 `result.content[].text` 渲染成卡片正文，并保留工具名与状态。
    func testToolCompletedFrameCarriesToolNameAndResultBody() throws {
        let model = model()
        _ = model.applyEvents([
            try toolStarted(sequence: 1),
            try toolUpdated(sequence: 2, delta: "hello-from-tool"),
            try toolCompleted(
                sequence: 3,
                status: "completed",
                result: #"{"content":[{"type":"text","text":"hello-from-tool"}],"details":null}"#
            ),
        ])

        let item = try XCTUnwrap(model.item(id: "call_1"))
        XCTAssertEqual(item.toolName, "bash", "后续帧不带 toolName，就地更新不得把它丢掉")
        XCTAssertEqual(item.status, "completed")
        XCTAssertEqual(item.text, "hello-from-tool")
    }

    /// `tool.updated` 的 `delta` 是追加文本（契约 §7.2），必须累计到同一条卡片正文上。
    func testToolUpdatedDeltasAccumulateOnTheCardBody() throws {
        let model = model()
        _ = model.applyEvents([
            try toolStarted(sequence: 1),
            try toolUpdated(sequence: 2, delta: "line 1\\n"),
            try toolUpdated(sequence: 3, delta: "line 2\\n"),
        ])

        let item = try XCTUnwrap(model.item(id: "call_1"))
        XCTAssertEqual(item.text, "line 1\nline 2\n")
        XCTAssertEqual(model.items.count, 1, "同 id 的工具帧只产生一行")
    }

    /// 工具被拒 / 未执行时 `result` 为空对象，此时必须保留已经流式到达的正文，
    /// 不能把卡片重新变空。
    func testToolCompletedWithEmptyResultKeepsStreamedBody() throws {
        let model = model()
        _ = model.applyEvents([
            try toolStarted(sequence: 1),
            try toolUpdated(sequence: 2, delta: "partial output"),
            try toolCompleted(sequence: 3, status: "failed", result: "{}"),
        ])

        let item = try XCTUnwrap(model.item(id: "call_1"))
        XCTAssertEqual(item.text, "partial output")
        XCTAssertEqual(item.status, "failed")
        XCTAssertEqual(item.toolName, "bash")
    }

    /// 结果形状容错：字符串结果、`content[]` 多分片都要能读出正文。
    func testToolResultShapeTolerance() throws {
        let single = model()
        _ = single.applyEvents([try toolCompleted(sequence: 1, status: "completed", result: #"{"content":"boom"}"#)])
        XCTAssertEqual(single.item(id: "call_1")?.text, "boom")

        let multi = model()
        _ = multi.applyEvents([
            try toolCompleted(
                sequence: 1,
                status: "completed",
                result: #"{"content":[{"type":"text","text":"a"},{"type":"text","text":"b"}]}"#
            )
        ])
        XCTAssertEqual(multi.item(id: "call_1")?.text, "ab")
    }

    /// 卡片在运行中（尚无正文）时不得被当成「服务器没有返回正文」的完成态：
    /// 归约结果里该条目的 `text` 必须仍是 `nil`，而不是空串之外的猜造内容。
    func testRunningToolItemHasNoBodyYet() throws {
        let model = model()
        _ = model.applyEvents([try toolStarted(sequence: 1)])

        let item = try XCTUnwrap(model.item(id: "call_1"))
        XCTAssertEqual(item.toolName, "bash")
        XCTAssertEqual(item.itemType, "tool")
        XCTAssertNil(item.status)
        XCTAssertNil(item.text)
    }
}
