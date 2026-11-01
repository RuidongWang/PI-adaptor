import Foundation

public enum RACPV2Method: String, CaseIterable, Sendable {
    case initialize = "connection/initialize"
    case ping = "connection/ping"
    case pair = "connection/pair"
    case revoke = "connection/revoke"
    case rotateToken = "connection/rotate-token"
    case confirmRotation = "connection/confirm-rotation"
    case deviceList = "device/list"
    case pairingToken = "device/pairing-token"
    case projectList = "project/list"
    case projectBrowse = "project/browse"
    case projectRegister = "project/register"
    case projectUpdate = "project/update"
    case projectDelete = "project/delete"
    case sessionList = "session/list"
    case sessionSearch = "session/search"
    case sessionGet = "session/get"
    case sessionCreate = "session/create"
    case sessionAttach = "session/attach"
    case sessionHistory = "session/history"
    case sessionConfigure = "session/configure"
    case sessionRename = "session/rename"
    case sessionArchive = "session/archive"
    case sessionBranch = "session/branch"
    case sessionDelete = "session/delete"
    case eventsSubscribe = "events/subscribe"
    case eventsUnsubscribe = "events/unsubscribe"
    case eventsAck = "events/ack"
    case turnStart = "turn/start"
    case turnGet = "turn/get"
    case turnInterrupt = "turn/interrupt"
    case turnCancel = "turn/cancel"
    case approvalRespond = "approval/respond"
    case inputRespond = "input/respond"
    case providerList = "provider/list"
    case providerCreate = "provider/create"
    case providerUpdate = "provider/update"
    case providerDelete = "provider/delete"
    case providerTest = "provider/test"
    case providerDiscover = "provider/discover"
    case skillList = "skill/list"
    case skillGet = "skill/get"
    case skillInstall = "skill/install"
    case skillUpdate = "skill/update"
    case skillDelete = "skill/delete"
    case attachmentCreate = "attachment/create"
    case attachmentChunk = "attachment/chunk"
    case attachmentComplete = "attachment/complete"
    case attachmentRead = "attachment/read"
}

public enum RACPV2Protocol {
    public static let version = "2.0.0"
    public static let subprotocol = "pi-racp.v2.jsonrpc"
}

public struct RACPV2ServerInfo: Codable, Equatable, Sendable {
    public struct Server: Codable, Equatable, Sendable {
        public var name: String
        public var version: String
        public var hostId: String
        public var piVersion: String
    }
    public var protocolVersion: String
    public var server: Server
    public var connectionId: String
    public var roles: [String]
    public var policy: JSONValue
    public var capabilities: JSONValue
}

public struct RACPV2ProviderModel: Codable, Equatable, Sendable {
    public var id: String
    public var displayName: String
    public var contextWindow: Int
    public var maxTokens: Int
    public var thinkingLevels: [String]
    public var defaultThinkingLevel: String?
    public var supportsImages: Bool
}

public struct RACPV2Provider: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var vendorKey: String
    public var type: String
    public var protocolName: String
    public var baseUrl: String
    public var authKind: String
    public var hasApiKey: Bool
    public var apiKeyMask: String?
    public var isDefault: Bool
    public var models: [RACPV2ProviderModel]
    public var createdAt: String
    public var updatedAt: String

    private enum CodingKeys: String, CodingKey {
        case id, name, vendorKey, type, protocolName = "protocol", baseUrl, authKind,
             hasApiKey, apiKeyMask, isDefault, models, createdAt, updatedAt
    }
}

public struct RACPV2Skill: Codable, Equatable, Sendable {
    public struct Source: Codable, Equatable, Sendable {
        public var type: String
        public var url: String?
        public var path: String?
        public var subdir: String?
        public var ref: String?
        public var refType: String?
    }
    public var id: String
    public var name: String
    public var description: String
    public var source: Source
    public var installedAt: String
    public var updatedAt: String
    public var status: String
    public var path: String
}

public struct RACPV2Attachment: Codable, Equatable, Sendable {
    public var id: String
    public var sessionId: String
    public var kind: String
    public var fileName: String
    public var mimeType: String
    public var byteLength: Int
    public var sha256: String
    public var state: String
    public var createdAt: String
}

public struct RACPV2AttachmentReadResult: Codable, Equatable, Sendable {
    public var attachment: RACPV2Attachment
    public var dataBase64: String
    public var eof: Bool
}

public struct RACPV2Context: Codable, Equatable, Sendable {
    public var requestId: String
    public var idempotencyKey: String?
    public var expectedRevision: Int?

    public init(requestId: String = "req_\(UUID().uuidString)", idempotencyKey: String? = nil, expectedRevision: Int? = nil) {
        self.requestId = requestId
        self.idempotencyKey = idempotencyKey
        self.expectedRevision = expectedRevision
    }
}

public struct RACPV2RevokeParams: Encodable, Equatable, Sendable {
    public var deviceId: String
    public var context: RACPV2Context

    public init(deviceId: String, context: RACPV2Context) {
        self.deviceId = deviceId
        self.context = context
    }
}

public struct RACPV2RawRequest<Params: Encodable & Sendable>: Encodable, Sendable {
    public let jsonrpc = "2.0"
    public let id: RACPIdentifier
    public let method: String
    public let params: Params

    public init(id: RACPIdentifier, method: String, params: Params) {
        self.id = id
        self.method = method
        self.params = params
    }
}

public enum RACPV2Error: Error, Equatable, Sendable, CustomStringConvertible {
    case server(code: String, message: String?)
    case protocolViolation(String)
    case notConnected

    public var description: String {
        switch self {
        case .server(let code, let message): return message ?? code
        case .protocolViolation(let message): return message
        case .notConnected: return "Host v2 未连接"
        }
    }
}
