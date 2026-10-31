import Foundation
import PIiOSCore
import XCTest

@testable import PIiOSNet

final class HostV2ClientLifecycleTests: XCTestCase {
    func testReplacingEventStreamFinishesPreviousStream() async {
        let client = HostV2Client()
        let first = await client.stream()
        _ = await client.stream()
        var iterator = first.makeAsyncIterator()
        let value = await iterator.next()
        XCTAssertNil(value)
        await client.close()
    }

    func testDisconnectFinishesPendingRequestAndEventStream() async throws {
        let socket = ClosingV2Socket()
        let client = HostV2Client()
        await client.attachForTesting(socket)
        let stream = await client.stream()
        let result = Task { try await client.request(.projectList, params: .object([:]), timeout: 10) }
        await fulfillment(of: [socket.sent], timeout: 2)
        await socket.close()
        do {
            _ = try await result.value
            XCTFail("请求应在连接关闭后失败")
        } catch let error as RACPV2Error {
            guard case .notConnected = error else { return XCTFail("错误类型不正确：\(error)") }
        }
        var iterator = stream.makeAsyncIterator()
        let value = await iterator.next()
        XCTAssertNil(value)
    }
}

private final class ClosingV2Socket: RACPSocket, @unchecked Sendable {
    let inbound: AsyncStream<Data>
    let sent = XCTestExpectation(description: "request sent")
    private let continuation: AsyncStream<Data>.Continuation

    init() {
        var sink: AsyncStream<Data>.Continuation!
        inbound = AsyncStream { sink = $0 }
        continuation = sink
    }

    func send(text: String) async throws { sent.fulfill() }
    func close() async { continuation.finish() }
    func waitUntilClosed() async {}
}
