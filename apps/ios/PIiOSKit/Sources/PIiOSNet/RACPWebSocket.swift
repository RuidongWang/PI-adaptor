import Foundation
import NIOCore
import CryptoKit

// MARK: - WebSocket over 已建立的 SSH direct-tcpip 通道

public enum RACPWebSocketError: Error, Equatable, CustomStringConvertible {
    case upgradeRejected(status: Int)
    case protocolViolation(String)
    case closed

    public var description: String {
        switch self {
        case .upgradeRejected(let status):
            return "WebSocket 升级被拒绝：HTTP \(status)"
        case .protocolViolation(let detail):
            return "WebSocket 协议异常：\(detail)"
        case .closed:
            return "WebSocket 连接已关闭"
        }
    }
}

/// 在一条已建立的字节流通道上完成 WebSocket 客户端握手，并收发**文本帧**。
///
/// 契约 §2.1：路径 `/v1/racp/ws`，升级请求必须携带子协议 `pi-racp.v1.jsonrpc`；
/// §2.3：设备令牌放 `Authorization: Bearer <token>` 请求头（不进 URL、不进日志）。
protocol RACPSocket: AnyObject {
    var inbound: AsyncStream<Data> { get }
    func send(text: String) async throws
    func close() async
    func waitUntilClosed() async
}

public final class RACPWebSocket: RACPSocket {
    /// 契约 §2.1 的上游常量。
    public static let path = "/v1/racp/ws"
    public static let subprotocol = "pi-racp.v1.jsonrpc"

    private let channel: Channel
    private let handler: WebSocketClientHandler
    private let continuation: AsyncStream<Data>.Continuation
    /// 入站文本消息（已按帧拼回完整消息）。
    public let inbound: AsyncStream<Data>

    public static func connect(
        on channel: Channel,
        path: String = RACPWebSocket.path,
        subprotocol: String = RACPWebSocket.subprotocol,
        bearerToken: String?,
        timeout: TimeInterval = 10
    ) async throws -> RACPWebSocket {
        let key = WebSocketHandshake.makeKey()
        let request = WebSocketHandshake.request(
            path: path,
            hostHeader: "127.0.0.1",
            subprotocol: subprotocol,
            key: key,
            bearerToken: bearerToken
        )
        let expectedAccept = WebSocketHandshake.accept(for: key)
        let ready = channel.eventLoop.makePromise(of: Void.self)
        var continuation: AsyncStream<Data>.Continuation!
        let stream = AsyncStream<Data> { continuation = $0 }
        let handler = WebSocketClientHandler(
            request: request,
            expectedAccept: expectedAccept,
            expectedSubprotocol: subprotocol,
            onText: { continuation.yield($0) },
            onClosed: { continuation.finish() },
            ready: ready
        )
        try await channel.eventLoop.submit {
            try channel.pipeline.syncOperations.addHandler(handler)
        }.get()
        try await withTimeout(seconds: timeout, phase: "WebSocket 升级") {
            try await handler.waitUntilUpgraded()
        }
        continuation.onTermination = { _ in
            channel.eventLoop.execute { _ = channel.close() }
        }
        return RACPWebSocket(channel: channel, handler: handler, inbound: stream, continuation: continuation)
    }

    private init(
        channel: Channel,
        handler: WebSocketClientHandler,
        inbound: AsyncStream<Data>,
        continuation: AsyncStream<Data>.Continuation
    ) {
        self.channel = channel
        self.handler = handler
        self.inbound = inbound
        self.continuation = continuation
    }

    /// 发送一条文本帧（JSON-RPC 帧）。
    public func send(text: String) async throws {
        let frame = WebSocketFrame(opcode: .text, payload: Data(text.utf8))
        let bytes = try WebSocketFrameEncoder.encode(frame, maskKey: WebSocketFrameEncoder.randomMaskKey())
        var buffer = channel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        try await channel.writeAndFlush(buffer).get()
    }

    /// 主动关闭（先发 close 帧再关通道）。
    public func close() async {
        let frame = WebSocketFrame(opcode: .close, payload: Data())
        if let bytes = try? WebSocketFrameEncoder.encode(frame, maskKey: WebSocketFrameEncoder.randomMaskKey()) {
            var buffer = channel.allocator.buffer(capacity: bytes.count)
            buffer.writeBytes(bytes)
            _ = try? await channel.writeAndFlush(buffer).get()
        }
        continuation.finish()
        try? await channel.close().get()
    }

    /// 通道关闭（含对端断开）时恢复，用于驱动退避重连。
    public func waitUntilClosed() async {
        try? await channel.closeFuture.get()
    }
}

// MARK: - 握手文本

enum WebSocketHandshake {
    static let guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    static func makeKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: 0...255)
        }
        return Data(bytes).base64EncodedString()
    }

    static func accept(for key: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data((key + guid).utf8))
        return Data(digest).base64EncodedString()
    }

    /// 渲染 HTTP/1.1 升级请求。令牌只出现在 `Authorization` 头里（契约 §2.3）。
    static func request(
        path: String,
        hostHeader: String,
        subprotocol: String,
        key: String,
        bearerToken: String?
    ) -> String {
        var lines = [
            "GET \(path) HTTP/1.1",
            "Host: \(hostHeader)",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Key: \(key)",
            "Sec-WebSocket-Version: 13",
            "Sec-WebSocket-Protocol: \(subprotocol)",
        ]
        if let bearerToken, !bearerToken.isEmpty {
            lines.append("Authorization: Bearer \(bearerToken)")
        }
        return lines.joined(separator: "\r\n") + "\r\n\r\n"
    }

    struct Response {
        var status: Int
        var headers: [String: String]
    }

    /// 解析手响应；`nil` 表示字节还不够。
    static func parse(_ data: Data) -> Response? {
        let terminator = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: terminator) else { return nil }
        let head = data[data.startIndex..<range.lowerBound]
        guard let text = String(data: head, encoding: .utf8) else { return nil }
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let statusLine = lines.removeFirst()
        let parts = statusLine.split(separator: " ")
        let status = parts.count >= 2 ? Int(parts[1]) ?? 0 : 0
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        return Response(status: status, headers: headers)
    }
}

// MARK: - 通道 Handler

private final class WebSocketClientHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let request: String
    private let expectedAccept: String
    private let expectedSubprotocol: String
    private let onText: @Sendable (Data) -> Void
    private let onClosed: @Sendable () -> Void
    private let ready: EventLoopPromise<Void>
    private var buffered = Data()
    private var decoder = WebSocketFrameDecoder()
    private var upgraded = false
    private var upgradeFailure: Error?

    init(
        request: String,
        expectedAccept: String,
        expectedSubprotocol: String,
        onText: @escaping @Sendable (Data) -> Void,
        onClosed: @escaping @Sendable () -> Void,
        ready: EventLoopPromise<Void>
    ) {
        self.request = request
        self.expectedAccept = expectedAccept
        self.expectedSubprotocol = expectedSubprotocol
        self.onText = onText
        self.onClosed = onClosed
        self.ready = ready
    }

    func waitUntilUpgraded() async throws {
        try await ready.futureResult.get()
    }

    func handlerAdded(context: ChannelHandlerContext) {
        if !upgraded {
            var buffer = context.channel.allocator.buffer(capacity: request.utf8.count)
            buffer.writeString(request)
            context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        buffered.append(Data(buffer.readableBytesView))
        if !upgraded {
            guard let response = WebSocketHandshake.parse(buffered) else { return }
            let terminator = Data("\r\n\r\n".utf8)
            let consumed = buffered.range(of: terminator)!.upperBound
            let rest = buffered.suffix(from: consumed)
            buffered = Data(rest)
            guard response.status == 101 else {
                upgradeFailure = RACPWebSocketError.upgradeRejected(status: response.status)
                ready.fail(upgradeFailure!)
                context.close(promise: nil)
                return
            }
            guard response.headers["sec-websocket-accept"] == expectedAccept else {
                upgradeFailure = RACPWebSocketError.protocolViolation("Sec-WebSocket-Accept 不匹配")
                ready.fail(upgradeFailure!)
                context.close(promise: nil)
                return
            }
            if let negotiated = response.headers["sec-websocket-protocol"],
               negotiated != expectedSubprotocol {
                upgradeFailure = RACPWebSocketError.protocolViolation("子协议协商为 \(negotiated)")
                ready.fail(upgradeFailure!)
                context.close(promise: nil)
                return
            }
            upgraded = true
            ready.succeed(())
        }
        decoder.append(buffered)
        buffered = Data()
        do {
            for frame in try decoder.drainFrames() {
                switch frame.opcode {
                case .text:
                    onText(frame.payload)
                case .binary:
                    // 契约 §2.1：只接受文本帧，二进制帧以 1003 关闭。
                    var payload = context.channel.allocator.buffer(capacity: 2)
                    payload.writeInteger(UInt16(1003))
                    sendClose(context: context, payload: payload)
                case .ping:
                    sendPong(context: context, payload: frame.payload)
                case .close:
                    context.close(promise: nil)
                case .pong, .continuation:
                    break
                }
            }
        } catch {
            upgradeFailure = error
            context.close(promise: nil)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !upgraded {
            ready.fail(upgradeFailure ?? RACPWebSocketError.closed)
        }
        onClosed()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if !upgraded {
            upgradeFailure = error
            ready.fail(error)
        }
        context.close(promise: nil)
    }

    private func sendPong(context: ChannelHandlerContext, payload: Data) {
        guard let bytes = try? WebSocketFrameEncoder.encode(
            WebSocketFrame(opcode: .pong, payload: payload),
            maskKey: WebSocketFrameEncoder.randomMaskKey()
        ) else { return }
        var buffer = context.channel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
    }

    private func sendClose(context: ChannelHandlerContext, payload: ByteBuffer) {
        var payload = payload
        let data = Data(payload.readableBytesView)
        payload.clear()
        guard let bytes = try? WebSocketFrameEncoder.encode(
            WebSocketFrame(opcode: .close, payload: data),
            maskKey: WebSocketFrameEncoder.randomMaskKey()
        ) else { return }
        var buffer = context.channel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        context.writeAndFlush(wrapOutboundOut(buffer)).whenComplete { _ in
            context.close(promise: nil)
        }
    }
}
