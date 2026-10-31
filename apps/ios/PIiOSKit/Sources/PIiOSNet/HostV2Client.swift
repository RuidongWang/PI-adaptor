import Foundation
import PIiOSCore

private struct V2IncomingFrame: Decodable {
    var id: RACPIdentifier?
    var method: String?
    var params: JSONValue?
    var result: JSONValue?
    var error: RACPErrorBody?
}

private struct PendingV2Request {
    let continuation: CheckedContinuation<JSONValue, Error>
}

public actor HostV2Client {
    private var transport: SSHTransport?
    private var socket: (any RACPSocket)?
    private var receiveTask: Task<Void, Never>?
    private var connectionID: UUID?
    private var nextID = 1
    private var pending: [RACPIdentifier: PendingV2Request] = [:]
    private var eventContinuation: AsyncStream<JSONValue>.Continuation?
    public private(set) var info: RACPV2ServerInfo?

    public init() {}

    public func connect(
        ssh: SSHConnectionRequest,
        hostPort: Int,
        token: String,
        confirmer: any HostKeyConfirming
    ) async throws -> RACPV2ServerInfo {
        await close()
        let id = UUID()
        connectionID = id
        do {
            let transport = try await SSHTransport.connect(ssh, confirmer: confirmer)
            guard connectionID == id else {
                await transport.close()
                throw RACPV2Error.notConnected
            }
            self.transport = transport
            let channel = try await transport.directTCPIP(port: hostPort)
            guard connectionID == id else { throw RACPV2Error.notConnected }
            let socket = try await RACPWebSocket.connect(
                on: channel,
                path: "/v1/racp/ws",
                subprotocol: RACPV2Protocol.subprotocol,
                bearerToken: token
            )
            guard connectionID == id else {
                await socket.close()
                throw RACPV2Error.notConnected
            }
            attach(socket, id: id)
            let initialize: JSONValue = .object([
            "client": .object([
                "name": .string("PI-IOS"),
                "version": .string("1.0.0"),
                "capabilities": .object([
                    "attachments": .bool(true),
                    "imageOutput": .bool(true),
                    "skills": .bool(true),
                    "providers": .bool(true),
                    "sessionBranches": .bool(true)
                ])
            ]),
            "protocolVersion": .string(RACPV2Protocol.version)
        ])
            let result = try await request(.initialize, params: initialize)
            guard connectionID == id else { throw RACPV2Error.notConnected }
            let decoded = try RACPV2ServerInfo.decoded(from: result)
            guard decoded.protocolVersion == RACPV2Protocol.version else {
                throw RACPV2Error.protocolViolation("协议版本不匹配：\(decoded.protocolVersion)")
            }
            info = decoded
            try await notify("notifications/initialized", params: .object([:]))
            guard connectionID == id else { throw RACPV2Error.notConnected }
            return decoded
        } catch {
            if connectionID == id { await close() }
            throw error
        }
    }

    public func stream() -> AsyncStream<JSONValue> {
        eventContinuation?.finish()
        var continuation: AsyncStream<JSONValue>.Continuation!
        let stream = AsyncStream<JSONValue> { continuation = $0 }
        eventContinuation = continuation
        return stream
    }

    public func request(_ method: RACPV2Method, params: JSONValue, timeout: TimeInterval = 30) async throws -> JSONValue {
        guard let socket else { throw RACPV2Error.notConnected }
        let id = RACPIdentifier.number(nextID)
        nextID += 1
        let frame: JSONValue = .object([
            "jsonrpc": .string("2.0"),
            "id": .number(Double(idValue(id))),
            "method": .string(method.rawValue),
            "params": params
        ])
        let data = try JSONEncoder().encode(frame)
        guard let text = String(data: data, encoding: .utf8) else {
            throw RACPV2Error.protocolViolation("请求编码失败")
        }
        let result = try await withCheckedThrowingContinuation { continuation in
            pending[id] = PendingV2Request(continuation: continuation)
            Task {
                do {
                    try await socket.send(text: text)
                } catch {
                    if let waiter = pending.removeValue(forKey: id) {
                        waiter.continuation.resume(throwing: error)
                    }
                }
            }
            Task {
                try? await Task.sleep(for: .seconds(timeout))
                if let waiter = pending.removeValue(forKey: id) {
                    waiter.continuation.resume(throwing: RACPV2Error.protocolViolation("请求超时：\(method.rawValue)"))
                }
            }
        }
        return result
    }

    public func notify(_ method: String, params: JSONValue) async throws {
        guard let socket else { throw RACPV2Error.notConnected }
        let frame: JSONValue = .object([
            "jsonrpc": .string("2.0"),
            "method": .string(method),
            "params": params
        ])
        try await socket.send(text: String(decoding: JSONEncoder().encode(frame), as: UTF8.self))
    }

    public func listProjects() async throws -> [RACPProjectSummary] {
        let result = try await request(.projectList, params: .object([:]))
        return try RACPV2ProjectListResult.decoded(from: result).projects
    }

    public func listSessions() async throws -> [RACPSessionSummary] {
        let result = try await request(.sessionList, params: .object(["includeArchived": .bool(true)]))
        return try RACPV2SessionListResult.decoded(from: result).sessions
    }

    public func attach(sessionId: String) async throws -> RACPSessionView {
        let result = try await request(.sessionAttach, params: .object(["sessionId": .string(sessionId)]))
        return try RACPV2AttachResult.decoded(from: result).view
    }

    public func startTurn(
        sessionId: String,
        text: String,
        attachments: [String] = [],
        idempotencyKey: String
    ) async throws -> RACPV2Turn {
        let result = try await request(
            .turnStart,
            params: .object([
                "sessionId": .string(sessionId),
                "input": .object([
                    "text": .string(text),
                    "attachments": .array(attachments.map(JSONValue.string))
                ]),
                "context": .object([
                    "requestId": .string("req_\(UUID().uuidString)"),
                    "idempotencyKey": .string(idempotencyKey)
                ])
            ])
        )
        return try RACPV2TurnResult.decoded(from: result).turn
    }

    public func listProviders() async throws -> [RACPV2Provider] {
        let result = try await request(.providerList, params: .object([:]))
        return try RACPV2ProviderListResult.decoded(from: result).providers
    }

    public func listSkills() async throws -> [RACPV2Skill] {
        let result = try await request(.skillList, params: .object([:]))
        return try RACPV2SkillListResult.decoded(from: result).skills
    }

    public func close() async {
        connectionID = nil
        receiveTask?.cancel()
        receiveTask = nil
        let oldSocket = socket
        socket = nil
        let oldTransport = transport
        transport = nil
        info = nil
        eventContinuation?.finish()
        eventContinuation = nil
        for waiter in pending.values {
            waiter.continuation.resume(throwing: RACPV2Error.notConnected)
        }
        pending.removeAll()
        await oldSocket?.close()
        await oldTransport?.close()
    }

    private func attach(_ socket: any RACPSocket, id: UUID) {
        self.socket = socket
        receiveTask = Task { [weak self] in
            for await data in socket.inbound {
                await self?.receive(data, connectionID: id)
            }
            await self?.connectionEnded(id)
        }
    }

    private func connectionEnded(_ id: UUID) async {
        if connectionID == id { await close() }
    }

    func attachForTesting(_ socket: any RACPSocket) async {
        await close()
        let id = UUID()
        connectionID = id
        attach(socket, id: id)
    }

    private func receive(_ data: Data, connectionID id: UUID) async {
        guard connectionID == id else { return }
        guard let frame = try? JSONDecoder().decode(V2IncomingFrame.self, from: data) else { return }
        if let id = frame.id, frame.method == nil {
            guard let waiter = pending.removeValue(forKey: id) else { return }
            if let error = frame.error {
                let business = error.data?.value(at: ["code"])?.stringValue ?? error.code
                waiter.continuation.resume(throwing: RACPV2Error.server(code: business, message: error.message))
            } else {
                waiter.continuation.resume(returning: frame.result ?? .null)
            }
            return
        }
        if frame.method == "events/event", let event = frame.params?.value(at: ["event"]) {
            eventContinuation?.yield(event)
        }
    }

    private func idValue(_ id: RACPIdentifier) -> Int {
        if case let .number(value) = id { return value }
        return 0
    }
}

private struct RACPV2ProjectListResult: Decodable {
    var projects: [RACPProjectSummary]
}

private struct RACPV2SessionListResult: Decodable {
    var sessions: [RACPSessionSummary]
}

private struct RACPV2ProviderListResult: Decodable {
    var providers: [RACPV2Provider]
}

private struct RACPV2SkillListResult: Decodable {
    var skills: [RACPV2Skill]
}

public struct RACPV2Turn: Codable, Equatable, Sendable {
    public var id: String
    public var sessionId: String
    public var status: String
    public var createdAt: String
    public var settledAt: String?
}

private struct RACPV2TurnResult: Decodable {
    var turn: RACPV2Turn
}

private struct RACPV2AttachResult: Decodable {
    var session: RACPSessionSummary
    var snapshot: RACPSnapshot
    var replayComplete: Bool
    var view: RACPSessionView {
        RACPSessionView(
            sessionId: session.id,
            summary: session,
            items: snapshot.items,
            activeItems: snapshot.activeItems,
            queuedTurns: [],
            pendingApprovals: snapshot.pendingApprovals,
            pendingInputs: snapshot.pendingInputs,
            expiredApprovalIds: [],
            cursor: snapshot.cursor,
            revision: snapshot.revision,
            replayComplete: replayComplete,
            hasMoreHistory: snapshot.hasMoreHistory,
            runningTurnId: snapshot.activeTurn?.id
        )
    }
}
