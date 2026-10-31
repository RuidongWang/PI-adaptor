import Foundation

/// 协议保真的 JSON 容器。
///
/// 契约只冻结了部分对象的形状（`docs/api/ios-client.md` §3.1 说明「参数形状以上游
/// operations.ts 的 typebox schema 为准」）。对未冻结形状的部分（事件帧、`items[]`、
/// `project/browse` 的 `entries[]`），客户端**不得**臆造字段名：这里保留原始 JSON，
/// 需要时再用 `value(at:)` 读已知键，避免把猜测写进类型。
public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// 按路径读取嵌套字段（对象键序列）。任何一段类型不符即返回 nil。
    public func value(at path: [String]) -> JSONValue? {
        var current = self
        for key in path {
            guard case let .object(dict) = current, let next = dict[key] else { return nil }
            current = next
        }
        return current
    }

    public var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        switch self {
        case let .number(value):
            guard value.rounded() == value, value.magnitude < Double(Int.max) else { return nil }
            return Int(value)
        case let .string(text):
            return Int(text)
        default:
            return nil
        }
    }

    public var boolValue: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case let .array(value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case let .object(value) = self { return value }
        return nil
    }
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "不支持的 JSON 值"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }
}

public extension Decodable {
    /// 从原始 JSON 值解出具体类型（先重编码再解码，用于「保留原样 + 需要时解析」的场景）。
    static func decoded(from value: JSONValue) throws -> Self {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(Self.self, from: data)
    }
}
