import Foundation

public struct HostSessionReference: Hashable, Sendable {
    public let hostID: UUID
    public let sessionID: String

    public init(hostID: UUID, sessionID: String) {
        self.hostID = hostID
        self.sessionID = sessionID
    }
}

public struct ForegroundSessionState: Equatable, Sendable {
    public var revision: Int?
    /// nil means this session's approval cards have not been loaded.
    public var pendingApprovalIDs: Set<String>?
    public var status: String?

    public init(revision: Int?, pendingApprovalIDs: Set<String>? = nil, status: String? = nil) {
        self.revision = revision
        self.pendingApprovalIDs = pendingApprovalIDs
        self.status = status
    }
}

public struct ForegroundResumeSnapshot: Equatable, Sendable {
    public let hostID: UUID
    public var sessions: [String: ForegroundSessionState]

    public init(hostID: UUID, sessions: [String: ForegroundSessionState]) {
        self.hostID = hostID
        self.sessions = sessions
    }
}

public enum ForegroundResumePolicy {
    public static func updates(
        baseline: ForegroundResumeSnapshot,
        current: ForegroundResumeSnapshot
    ) -> Set<HostSessionReference> {
        guard baseline.hostID == current.hostID else { return [] }
        return Set(current.sessions.compactMap { sessionID, state in
            if let previous = baseline.sessions[sessionID] {
                let approvalsChanged: Bool
                if let previousIDs = previous.pendingApprovalIDs,
                   let currentIDs = state.pendingApprovalIDs {
                    approvalsChanged = previousIDs != currentIDs
                } else {
                    approvalsChanged = previous.pendingApprovalIDs == nil
                        && state.pendingApprovalIDs?.isEmpty == false
                }
                // Catalog status also identifies approval changes for unattached sessions.
                let approvalStatusChanged = previous.status != state.status
                    && [previous.status, state.status].contains {
                        $0?.lowercased().contains("approval") == true
                    }
                guard previous.revision != state.revision || approvalsChanged || approvalStatusChanged else {
                    return nil
                }
            }
            return HostSessionReference(hostID: current.hostID, sessionID: sessionID)
        })
    }
}

public struct ForegroundSessionUpdateMarkers: Sendable {
    public private(set) var sessions: Set<HostSessionReference> = []

    public init() {}

    public mutating func record(_ updates: Set<HostSessionReference>) {
        sessions.formUnion(updates)
    }

    public mutating func open(hostID: UUID, sessionID: String) {
        sessions.remove(HostSessionReference(hostID: hostID, sessionID: sessionID))
    }

    public mutating func removeHost(_ hostID: UUID) {
        sessions = sessions.filter { $0.hostID != hostID }
    }

    public func contains(_ reference: HostSessionReference) -> Bool {
        sessions.contains(reference)
    }
}

/// Retains the baseline until a successful comparison; only one attempt may run at a time.
public struct ForegroundResumeTracker: Sendable {
    public struct Ticket: Sendable {
        public let id: UUID
        public let baseline: ForegroundResumeSnapshot
    }

    private var pending: ForegroundResumeSnapshot?
    private var activeID: UUID?
    private var openedSessions: Set<HostSessionReference> = []

    public init() {}

    public var hasPendingResume: Bool { pending != nil }

    public mutating func capture(_ baseline: ForegroundResumeSnapshot?) {
        // A failed resume must also survive another background/foreground cycle.
        if baseline == nil || pending?.hostID != baseline?.hostID {
            pending = baseline
            openedSessions = []
        }
        activeID = nil
    }

    public mutating func beginResume() -> Ticket? {
        guard activeID == nil, let pending else { return nil }
        let ticket = Ticket(id: UUID(), baseline: pending)
        activeID = ticket.id
        return ticket
    }

    public mutating func retry(_ ticket: Ticket) {
        guard activeID == ticket.id else { return }
        activeID = nil
    }

    public mutating func open(hostID: UUID, sessionID: String) {
        guard pending?.hostID == hostID else { return }
        openedSessions.insert(HostSessionReference(hostID: hostID, sessionID: sessionID))
    }

    public mutating func complete(
        _ ticket: Ticket,
        current: ForegroundResumeSnapshot
    ) -> Set<HostSessionReference> {
        guard activeID == ticket.id, current.hostID == ticket.baseline.hostID else { return [] }
        let updates = ForegroundResumePolicy.updates(baseline: ticket.baseline, current: current)
            .subtracting(openedSessions)
        pending = nil
        activeID = nil
        openedSessions = []
        return updates
    }
}
