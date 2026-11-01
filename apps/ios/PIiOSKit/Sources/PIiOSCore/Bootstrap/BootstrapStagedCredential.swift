import Foundation

/// Persisted metadata for a device token issued by an incomplete install.
///
/// The active device token is stored under a different account. Recovery can
/// enumerate this envelope, revoke the Host-side device with its staged token,
/// and remove the attempt without ever reading or replacing the active token.
public struct BootstrapStagedCredential: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    public static let accountPrefix = "staged-host-token:"

    public let version: Int
    public let hostID: UUID
    public let attemptId: String
    public let targetPort: Int
    public let deviceId: String
    public let deviceToken: String
    public let createdAt: Date

    public init?(
        hostID: UUID,
        attemptId: String,
        targetPort: Int,
        deviceId: String,
        deviceToken: String,
        createdAt: Date = Date()
    ) {
        guard Self.isValidAttemptId(attemptId),
              (1...65_535).contains(targetPort),
              !deviceId.isEmpty,
              deviceToken.hasPrefix("pdt2."),
              !deviceToken.contains(where: \.isWhitespace)
        else { return nil }
        version = Self.schemaVersion
        self.hostID = hostID
        self.attemptId = attemptId
        self.targetPort = targetPort
        self.deviceId = deviceId
        self.deviceToken = deviceToken
        self.createdAt = createdAt
    }

    public static func account(hostID: UUID, attemptId: String) -> String {
        "\(accountPrefix)\(hostID.uuidString.lowercased()):\(attemptId)"
    }

    public static func decode(
        account: String,
        data: Data,
        expectedHostID: UUID
    ) -> Self? {
        guard let staged = try? JSONDecoder().decode(Self.self, from: data),
              staged.version == schemaVersion,
              staged.hostID == expectedHostID,
              account == self.account(hostID: staged.hostID, attemptId: staged.attemptId),
              isValidAttemptId(staged.attemptId),
              (1...65_535).contains(staged.targetPort),
              !staged.deviceId.isEmpty,
              staged.deviceToken.hasPrefix("pdt2."),
              !staged.deviceToken.contains(where: \.isWhitespace)
        else { return nil }
        return staged
    }

    public static func recoverable(
        from items: [(account: String, data: Data)],
        expectedHostID: UUID
    ) -> [Self] {
        items.compactMap {
            decode(
                account: $0.account,
                data: $0.data,
                expectedHostID: expectedHostID
            )
        }
    }

    static func isValidAttemptId(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 128
            && value.unicodeScalars.allSatisfy {
                $0.isASCII
                    && (CharacterSet.alphanumerics.contains($0)
                        || "._-".unicodeScalars.contains($0))
            }
    }
}

public enum BootstrapStagingRecoveryAction: Equatable, Sendable {
    /// Promotion reached the primary token but staging cleanup did not complete.
    case clearOnly
    /// The staged token is different from the primary and must be revoked.
    case revokeThenClear
}

extension BootstrapStagedCredential {
    public func recoveryAction(
        activeDeviceId: String?,
        activeDeviceToken: String?
    ) -> BootstrapStagingRecoveryAction {
        if activeDeviceId == deviceId,
           activeDeviceToken == deviceToken {
            return .clearOnly
        }
        return .revokeThenClear
    }
}

public enum BootstrapStagingRecoveryCoordinator {
    /// Applies recovery decisions and returns staging records whose deletion
    /// failed. Running the same coordinator again is safe after promotion: if
    /// the primary token still exactly matches staging, it never revokes.
    @discardableResult
    public static func recover(
        staging: [BootstrapStagedCredential],
        activeDeviceId: String?,
        activeDeviceToken: String?,
        revoke: @Sendable (BootstrapStagedCredential) async -> Void,
        clear: @Sendable (BootstrapStagedCredential) async -> Bool
    ) async -> [BootstrapStagedCredential] {
        var remaining: [BootstrapStagedCredential] = []
        for attempt in staging {
            if attempt.recoveryAction(
                activeDeviceId: activeDeviceId,
                activeDeviceToken: activeDeviceToken
            ) == .revokeThenClear {
                await revoke(attempt)
            }
            if !(await clear(attempt)) {
                remaining.append(attempt)
            }
        }
        return remaining
    }
}
