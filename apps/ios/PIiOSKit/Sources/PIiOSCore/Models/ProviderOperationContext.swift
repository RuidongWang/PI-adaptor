import Foundation

/// No credentials: only the identity and epochs needed to reject a late SSH result.
public struct ProviderOperationContext: Equatable, Sendable {
    public let hostID: UUID
    public let address: String
    public let sshPort: Int
    public let username: String
    public let hostPort: Int?
    public let authKind: String
    public let hostGeneration: Int
    public let identityGeneration: Int
    public let connectionGeneration: Int

    public init(
        hostID: UUID, address: String, sshPort: Int, username: String,
        hostPort: Int?, authKind: String, hostGeneration: Int, identityGeneration: Int,
        connectionGeneration: Int
    ) {
        self.hostID = hostID
        self.address = address
        self.sshPort = sshPort
        self.username = username
        self.hostPort = hostPort
        self.authKind = authKind
        self.hostGeneration = hostGeneration
        self.identityGeneration = identityGeneration
        self.connectionGeneration = connectionGeneration
    }

    public func canApply(to current: ProviderOperationContext?) -> Bool {
        self == current
    }
}
