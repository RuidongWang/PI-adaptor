import Foundation
import PIiOSCore
import XCTest

@testable import PIiOSNet

final class RACPInboundAckTests: XCTestCase {
    func testSessionAckResponseIsConsumedWhileReceiveLoopContinues() async throws {
        let socket = AckingSocket()
        let client = RACPClient(
            testingSocket: socket,
            subscriptionId: "sub_1",
            subscribedSessionId: "session_1"
        )
        let pump = Task {
            for await data in socket.inbound {
                await client.receiveForTesting(data)
            }
        }

        let event = """
        {"jsonrpc":"2.0","method":"events/event","params":{"sequence":1,"epoch":"epoch_1","item":{"id":"item_1","kind":"message","text":"hello"}}}
        """
        socket.enqueue(Data(event.utf8))

        await fulfillment(of: [socket.firstAck], timeout: 2)
        XCTAssertEqual(socket.ackRecords(), [RecordedAck(subscriptionId: "sub_1", sequence: 1)])

        let deadline = ContinuousClock.now + .seconds(1)
        var pending = await client.pendingRequestCountForTesting()
        while pending != 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
            pending = await client.pendingRequestCountForTesting()
        }
        XCTAssertEqual(pending, 0, "ACK 响应必须能进入接收循环；不能在 ACK 等待中自锁")

        await socket.close()
        pump.cancel()
    }

    func testLateAckFromReplacedSubscriptionNeverUsesNewSubscriptionID() async throws {
        let socket = AckingSocket()
        let client = RACPClient(
            testingSocket: socket,
            subscriptionId: "sub_old",
            subscribedSessionId: "session_1"
        )
        await client.setSessionSubscriptionForTesting("sub_new")
        await client.enqueueSessionAckForTesting(subscriptionId: "sub_old", sequence: 9)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(socket.ackRecords().isEmpty)

        let pump = Task {
            for await data in socket.inbound {
                await client.receiveForTesting(data)
            }
        }
        await client.enqueueSessionAckForTesting(subscriptionId: "sub_new", sequence: 10)
        let deadline = ContinuousClock.now + .seconds(1)
        while socket.ackRecords().isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(socket.ackRecords(), [RecordedAck(subscriptionId: "sub_new", sequence: 10)])

        await socket.close()
        pump.cancel()
    }

    /// v2 Host 把事件包在 `params.event` 里（见冻结 golden 的 `events/event`）。
    /// 客户端必须解包后再归约并按 durable sequence ACK，否则实时流会被静默丢弃。
    func testV2WrappedEventEnvelopeIsDecodedAndAcknowledged() async throws {
        let socket = AckingSocket()
        let client = RACPClient(
            testingSocket: socket,
            subscriptionId: "sub_1",
            subscribedSessionId: "session_1"
        )
        let pump = Task {
            for await data in socket.inbound {
                await client.receiveForTesting(data)
            }
        }

        let event = """
        {"jsonrpc":"2.0","method":"events/event","params":{"event":{"scope":"session","kind":"item.delta","epoch":"epoch_1","sequence":1,"payload":{"itemId":"item_1","itemType":"message","delta":"hi"}}}}
        """
        socket.enqueue(Data(event.utf8))

        await fulfillment(of: [socket.firstAck], timeout: 2)
        XCTAssertEqual(socket.ackRecords(), [RecordedAck(subscriptionId: "sub_1", sequence: 1)])

        await socket.close()
        pump.cancel()
    }

    func testTerminalClosedNoticeEmitsErrorAndClosesSubscription() async throws {
        let socket = TerminalClosingSocket()
        let client = RACPClient(
            testingSocket: socket,
            subscriptionId: "sub_1",
            subscribedSessionId: "session_1"
        )
        let updates = await client.stream()
        let errorTask = Task<RACPErrorCode?, Never> {
            for await update in updates {
                if case let .error(code, _) = update {
                    return code
                }
            }
            return nil
        }
        let notice = """
        {"jsonrpc":"2.0","method":"events/closed","params":{"subscriptionId":"sub_1","error":{"code":"FORBIDDEN","message":"permission denied"}}}
        """
        await client.receiveForTesting(Data(notice.utf8))

        let code = await errorTask.value
        XCTAssertEqual(code, .forbidden)
        await fulfillment(of: [socket.closed], timeout: 2)
        errorTask.cancel()
    }
}

private struct RecordedAck: Equatable {
    let subscriptionId: String
    let sequence: Int
}

private final class AckingSocket: RACPSocket, @unchecked Sendable {
    let inbound: AsyncStream<Data>
    let firstAck = XCTestExpectation(description: "first events/ack sent")

    private let continuation: AsyncStream<Data>.Continuation
    private let lock = NSLock()
    private var records: [RecordedAck] = []
    private var fulfilledFirstAck = false

    init() {
        var sink: AsyncStream<Data>.Continuation!
        inbound = AsyncStream { sink = $0 }
        continuation = sink
    }

    func enqueue(_ data: Data) {
        continuation.yield(data)
    }

    func ackRecords() -> [RecordedAck] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }

    func send(text: String) async throws {
        guard let data = text.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["method"] as? String == "events/ack",
              let id = object["id"],
              let params = object["params"] as? [String: Any],
              let subscriptionId = params["subscriptionId"] as? String,
              let sequence = params["sequence"] as? Int
        else { return }
        lock.lock()
        records.append(RecordedAck(subscriptionId: subscriptionId, sequence: sequence))
        let shouldFulfillFirst = !fulfilledFirstAck
        fulfilledFirstAck = true
        lock.unlock()
        if shouldFulfillFirst {
            firstAck.fulfill()
        }
        let response = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": id,
            "result": [:],
        ])
        continuation.yield(response)
    }

    func close() async {
        continuation.finish()
    }

    func waitUntilClosed() async {
        await Task.yield()
    }
}

private final class TerminalClosingSocket: RACPSocket, @unchecked Sendable {
    let inbound: AsyncStream<Data>
    let closed = XCTestExpectation(description: "socket closed")
    private let continuation: AsyncStream<Data>.Continuation

    init() {
        var sink: AsyncStream<Data>.Continuation!
        inbound = AsyncStream { sink = $0 }
        continuation = sink
    }

    func send(text: String) async throws {}

    func close() async {
        closed.fulfill()
        continuation.finish()
    }

    func waitUntilClosed() async {
        await Task.yield()
    }
}
