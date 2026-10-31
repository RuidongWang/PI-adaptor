import XCTest

@testable import PIiOSNet

final class WebSocketFramerTests: XCTestCase {
    private let mask = Data([0x01, 0x02, 0x03, 0x04])

    func testEncodedClientFrameIsMaskedAndRoundTrips() throws {
        let payload = Data("{\"jsonrpc\":\"2.0\"}".utf8)
        let encoded = try WebSocketFrameEncoder.encode(
            WebSocketFrame(opcode: .text, payload: payload),
            maskKey: mask
        )
        // 客户端帧的 MASK 位必须是 1（RFC 6455 §5.3）。
        XCTAssertEqual(encoded[1] & 0x80, 0x80)
        var decoder = WebSocketFrameDecoder()
        decoder.append(encoded)
        let frames = try decoder.drainFrames()
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first?.opcode, .text)
        XCTAssertEqual(frames.first?.payload, payload)
    }

    func testExtendedLengthPayloadUses126Marker() throws {
        let payload = Data(repeating: 0x7A, count: 300)
        let encoded = try WebSocketFrameEncoder.encode(
            WebSocketFrame(opcode: .text, payload: payload),
            maskKey: mask
        )
        XCTAssertEqual(encoded[1] & 0x7F, 126)
        var decoder = WebSocketFrameDecoder()
        decoder.append(encoded)
        XCTAssertEqual(try decoder.drainFrames().first?.payload.count, 300)
    }

    func testPartialFrameWaitsForMoreBytes() throws {
        let payload = Data("hello".utf8)
        let encoded = try WebSocketFrameEncoder.encode(
            WebSocketFrame(opcode: .text, payload: payload),
            maskKey: mask
        )
        var decoder = WebSocketFrameDecoder()
        decoder.append(encoded.prefix(4))
        XCTAssertEqual(try decoder.drainFrames().count, 0)
        decoder.append(encoded.dropFirst(4))
        XCTAssertEqual(try decoder.drainFrames().first?.payload, payload)
    }

    func testFragmentedMessageIsReassembled() throws {
        var decoder = WebSocketFrameDecoder()
        // 服务端帧不加掩码；先 text(fin=false)，再 continuation(fin=true)。
        decoder.append(serverFrame(opcode: 0x1, fin: false, payload: Data("ab".utf8)))
        decoder.append(serverFrame(opcode: 0x0, fin: true, payload: Data("cd".utf8)))
        let frames = try decoder.drainFrames()
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first?.payload, Data("abcd".utf8))
        XCTAssertEqual(frames.first?.opcode, .text)
    }

    func testControlFramesAreSurfaced() throws {
        var decoder = WebSocketFrameDecoder()
        decoder.append(serverFrame(opcode: 0x9, fin: true, payload: Data([0x01])))
        let frames = try decoder.drainFrames()
        XCTAssertEqual(frames.first?.opcode, .ping)
    }

    func testUnexpectedContinuationThrows() {
        var decoder = WebSocketFrameDecoder()
        decoder.append(serverFrame(opcode: 0x0, fin: true, payload: Data()))
        XCTAssertThrowsError(try decoder.drainFrames())
    }

    func testEncoderPreservesNonFinalFragment() throws {
        let frame = WebSocketFrame(fin: false, opcode: .text, payload: Data("a".utf8))
        let encoded = try WebSocketFrameEncoder.encode(frame, maskKey: mask)
        XCTAssertEqual(encoded[0] & 0x80, 0)
    }

    func testOversizedLengthIsRejectedFromHeaderAlone() {
        var decoder = WebSocketFrameDecoder()
        decoder.append(Data([0x81, 127, 0, 0, 0, 0, 0, 0x40, 0, 1]))
        XCTAssertThrowsError(try decoder.drainFrames()) { error in
            XCTAssertEqual(error as? WebSocketFramingError, .payloadTooLarge(4 * 1024 * 1024 + 1))
        }
    }

    func testUnrepresentableLengthIsRejected() {
        var decoder = WebSocketFrameDecoder()
        decoder.append(Data([0x81, 127, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]))
        XCTAssertThrowsError(try decoder.drainFrames())
    }

    func testFragmentedMessageCannotExceedLimit() throws {
        var decoder = WebSocketFrameDecoder()
        let size = WebSocketFrameDecoder.maximumFrameBytes
        let first = try WebSocketFrameEncoder.encode(
            WebSocketFrame(fin: false, opcode: .text, payload: Data(repeating: 0x61, count: size)),
            maskKey: mask
        )
        decoder.append(first)
        XCTAssertTrue(try decoder.drainFrames().isEmpty)
        decoder.append(Data([0x80, 1, 0x62]))
        XCTAssertThrowsError(try decoder.drainFrames()) { error in
            XCTAssertEqual(error as? WebSocketFramingError, .payloadTooLarge(size + 1))
        }
    }

    private func serverFrame(opcode: UInt8, fin: Bool, payload: Data) -> Data {
        var out = Data()
        out.append((fin ? 0x80 : 0x00) | opcode)
        out.append(UInt8(payload.count & 0x7F))
        out.append(payload)
        return out
    }
}
