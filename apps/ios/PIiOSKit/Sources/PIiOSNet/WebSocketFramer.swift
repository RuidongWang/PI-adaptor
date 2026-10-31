import Foundation

// MARK: - RFC 6455 客户端帧编解码（只做契约需要的最小集合）

/// WebSocket 操作码（RFC 6455 §5.2）。
public enum WebSocketOpcode: UInt8, Sendable, Equatable {
    case continuation = 0x0
    case text = 0x1
    case binary = 0x2
    case close = 0x8
    case ping = 0x9
    case pong = 0xA
}

public struct WebSocketFrame: Equatable, Sendable {
    public var fin: Bool
    public var opcode: WebSocketOpcode
    public var payload: Data

    public init(fin: Bool = true, opcode: WebSocketOpcode, payload: Data) {
        self.fin = fin
        self.opcode = opcode
        self.payload = payload
    }
}

public enum WebSocketFramingError: Error, Equatable, CustomStringConvertible {
    case payloadTooLarge(Int)
    case unmaskedClientFrame
    case unexpectedContinuation

    public var description: String {
        switch self {
        case .payloadTooLarge(let bytes):
            return "WebSocket 帧超过接收上限：\(bytes) 字节"
        case .unmaskedClientFrame:
            return "客户端发出的帧必须加掩码"
        case .unexpectedContinuation:
            return "收到无起始帧的 continuation 帧"
        }
    }
}

/// 客户端编码器：按 RFC 6455 §5.3，客户端发出的每一帧都必须加掩码。
public enum WebSocketFrameEncoder {
    /// - Parameter maskKey: 4 字节掩码；测试可传入固定值，生产用随机数。
    public static func encode(_ frame: WebSocketFrame, maskKey: Data) throws -> Data {
        guard maskKey.count == 4 else { throw WebSocketFramingError.unmaskedClientFrame }
        var out = Data()
        out.append((frame.fin ? 0x80 : 0x00) | frame.opcode.rawValue)
        let length = frame.payload.count
        let maskBit: UInt8 = 0x80
        if length < 126 {
            out.append(maskBit | UInt8(length))
        } else if length <= 0xFFFF {
            out.append(maskBit | 126)
            out.append(UInt8((length >> 8) & 0xFF))
            out.append(UInt8(length & 0xFF))
        } else {
            out.append(maskBit | 127)
            for shift in stride(from: 56, through: 0, by: -8) {
                out.append(UInt8((UInt64(length) >> UInt64(shift)) & 0xFF))
            }
        }
        out.append(maskKey)
        var masked = Data(capacity: length)
        let key = [UInt8](maskKey)
        for (index, byte) in frame.payload.enumerated() {
            masked.append(byte ^ key[index % 4])
        }
        out.append(masked)
        return out
    }

    /// 生成 4 字节随机掩码（系统 CSPRNG）。
    public static func randomMaskKey() -> Data {
        var bytes = [UInt8](repeating: 0, count: 4)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: 0...255)
        }
        return Data(bytes)
    }
}

/// 服务端 → 客户端的帧解码器：增量喂字节，吐出完整消息帧。
///
/// 大消息可能被服务端拆成多个 continuation 帧，这里按 RFC 6455 §5.4 拼回一条消息后
/// 以 `.text`/`.binary` 交出；控制帧（ping/pong/close）单独交出。
public struct WebSocketFrameDecoder {
    /// 单帧上限：契约 §2.2 的 `maxReceiveBytes` 是 1 MiB，这里按同一量级设防。
    public static let maximumFrameBytes = 4 * 1024 * 1024

    private var buffer = Data()
    private var fragmentOpcode: WebSocketOpcode?
    private var fragmentPayload = Data()

    public init() {}

    public mutating func append(_ bytes: Data) {
        buffer.append(bytes)
    }

    /// 取出所有已完整的帧；数据不完整时返回空数组（剩余字节留到下次）。
    public mutating func drainFrames() throws -> [WebSocketFrame] {
        var frames: [WebSocketFrame] = []
        while true {
            guard let head = try parseHeader() else { break }
            if head.opcode == WebSocketOpcode.continuation.rawValue, fragmentOpcode != nil,
               head.payloadLength > Self.maximumFrameBytes - fragmentPayload.count {
                throw WebSocketFramingError.payloadTooLarge(fragmentPayload.count + head.payloadLength)
            }
            guard buffer.count >= head.totalLength else { break }
            let payloadStart = buffer.startIndex + head.headerLength
            let payloadEnd = payloadStart + head.payloadLength
            var payload = Data(buffer[payloadStart..<payloadEnd])
            if head.masked {
                let mask = [UInt8](buffer[head.maskOffset..<(head.maskOffset + 4)])
                payload = Data(payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
            }
            buffer.removeFirst(head.totalLength)
            frames.append(contentsOf: try assemble(head: head, payload: payload))
        }
        return frames
    }

    private struct Header {
        var fin: Bool
        var opcode: UInt8
        var masked: Bool
        var payloadLength: Int
        var headerLength: Int
        var maskOffset: Int
        var totalLength: Int
    }

    private func parseHeader() throws -> Header? {
        guard buffer.count >= 2 else { return nil }
        let base = buffer.startIndex
        let first = buffer[base]
        let second = buffer[base + 1]
        let fin = (first & 0x80) != 0
        let opcode = first & 0x0F
        let masked = (second & 0x80) != 0
        var payloadLength = Int(second & 0x7F)
        var offset = 2

        if payloadLength == 126 {
            guard buffer.count >= 4 else { return nil }
            payloadLength = Int(buffer[base + 2]) << 8 | Int(buffer[base + 3])
            offset = 4
        } else if payloadLength == 127 {
            guard buffer.count >= 10 else { return nil }
            var length: UInt64 = 0
            for index in 2..<10 {
                length = length << 8 | UInt64(buffer[base + index])
            }
            guard length <= UInt64(Self.maximumFrameBytes) else {
                throw WebSocketFramingError.payloadTooLarge(Int(clamping: length))
            }
            payloadLength = Int(length)
            offset = 10
        }
        guard payloadLength <= Self.maximumFrameBytes else {
            throw WebSocketFramingError.payloadTooLarge(payloadLength)
        }
        let maskOffset = base + offset
        let headerLength = offset + (masked ? 4 : 0)
        return Header(
            fin: fin,
            opcode: opcode,
            masked: masked,
            payloadLength: payloadLength,
            headerLength: headerLength,
            maskOffset: maskOffset,
            totalLength: headerLength + payloadLength
        )
    }

    private mutating func assemble(head: Header, payload: Data) throws -> [WebSocketFrame] {
        guard let opcode = WebSocketOpcode(rawValue: head.opcode) else { return [] }

        switch opcode {
        case .ping, .pong, .close:
            return [WebSocketFrame(fin: head.fin, opcode: opcode, payload: payload)]
        case .continuation:
            guard fragmentOpcode != nil else { throw WebSocketFramingError.unexpectedContinuation }
            fragmentPayload.append(payload)
            if head.fin {
                let message = WebSocketFrame(
                    fin: true,
                    opcode: fragmentOpcode ?? .text,
                    payload: fragmentPayload
                )
                fragmentOpcode = nil
                fragmentPayload = Data()
                return [message]
            }
            return []
        case .text, .binary:
            if head.fin {
                return [WebSocketFrame(fin: true, opcode: opcode, payload: payload)]
            }
            fragmentOpcode = opcode
            fragmentPayload = payload
            return []
        }
    }
}
