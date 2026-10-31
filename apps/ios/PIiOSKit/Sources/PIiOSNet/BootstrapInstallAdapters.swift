import Foundation
import PIiOSCore

public enum BootstrapInstallAdapterError: Error, Equatable, CustomStringConvertible {
    case requiresSSHTransport
    case persistenceFailed

    public var description: String {
        switch self {
        case .requiresSSHTransport:
            return "安装器没有取得可复用的 SSH 连接"
        case .persistenceFailed:
            return "设备令牌已签发，但未能写入本机 Keychain"
        }
    }
}

/// Bridges the bootstrap pairing callback to the RACP client while keeping the
/// exact SSH transport used for polling. Persistence is injected so this
/// network target does not depend on the App's Keychain wrapper.
public struct BootstrapInstallPairingAdapter: BootstrapPairingCallback {
    public typealias Exchange = @Sendable (
        any BootstrapCommandTransport,
        BootstrapPairingMaterial,
        String?
    ) async throws -> RACPPairResult
    public typealias Persist = @Sendable (BootstrapPairedDevice) async throws -> Void

    private let exchange: Exchange
    private let persist: Persist

    public init(
        clientVersion: String = "0.1.0",
        exchange: Exchange? = nil,
        persist: Persist? = nil
    ) {
        self.exchange = exchange ?? { transport, material, deviceLabel in
            guard let ssh = transport as? SSHTransport else {
                throw BootstrapInstallAdapterError.requiresSSHTransport
            }
            return try await RACPClient.pairOnce(
                using: ssh,
                hostPort: material.port,
                pairingToken: material.token,
                clientVersion: clientVersion,
                deviceLabel: deviceLabel
            )
        }
        self.persist = persist ?? { _ in }
    }

    public func pair(
        using transport: any BootstrapCommandTransport,
        material: BootstrapPairingMaterial,
        deviceLabel: String?
    ) async throws -> BootstrapPairedDevice {
        let result = try await exchange(transport, material, deviceLabel)
        let device = BootstrapPairedDevice(
            deviceId: result.deviceId,
            deviceToken: result.deviceToken,
            roles: result.roles
        )
        try await persist(device)
        return device
    }
}

/// Validates the newly paired device through `connection/initialize` followed
/// by `connection/ping`, again without opening another SSH connection.
public struct BootstrapInstallVerificationAdapter: BootstrapDeviceVerificationCallback {
    public typealias Verify = @Sendable (
        any BootstrapCommandTransport,
        Int,
        BootstrapPairedDevice
    ) async throws -> RACPServerInfo

    private let verifyExchange: Verify
    private let retryTimeout: TimeInterval
    private let retryInterval: TimeInterval
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    public init(
        clientVersion: String = "0.1.0",
        retryTimeout: TimeInterval = 30,
        retryInterval: TimeInterval = 0.5,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000))
        },
        verify: Verify? = nil
    ) {
        self.verifyExchange = verify ?? { transport, port, device in
            guard let ssh = transport as? SSHTransport else {
                throw BootstrapInstallAdapterError.requiresSSHTransport
            }
            return try await RACPClient.verifyDevice(
                using: ssh,
                hostPort: port,
                deviceToken: device.deviceToken,
                clientVersion: clientVersion
            )
        }
        self.retryTimeout = max(0, retryTimeout)
        self.retryInterval = max(0.01, retryInterval)
        self.sleep = sleep
    }

    public func verify(
        using transport: any BootstrapCommandTransport,
        port: Int,
        device: BootstrapPairedDevice
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(retryTimeout))
        var lastError: Error?
        repeat {
            do {
                _ = try await verifyExchange(transport, port, device)
                return
            } catch {
                lastError = error
                guard Self.isRetryable(error), clock.now < deadline else { throw error }
                try await sleep(retryInterval)
            }
        } while !Task.isCancelled
        throw lastError ?? CancellationError()
    }

    private static func isRetryable(_ error: Error) -> Bool {
        if let error = error as? SSHTransportError {
            switch error {
            case .tunnelRefused, .closedByPeer, .channelClosed, .networkFailure, .timedOut:
                return true
            case .authenticationFailed, .hostKeyRejected, .invalidPrivateKey,
                 .hostKeyAlgorithmUnsupported, .hostKeyUnreadable:
                return false
            }
        }
        if let error = error as? RACPClientError {
            switch error {
            case .notConnected, .timedOut:
                return true
            case .protocolMismatch, .server, .malformedFrame:
                return false
            }
        }
        if error is RACPWebSocketError {
            return true
        }
        return false
    }
}

public enum BootstrapInstallDiagnostics {
    /// Bootstrap stdout/stderr are redirected to an owner-only file by the
    /// remote launcher. The pairing token travels through a FIFO and is removed
    /// before this file is exposed.
    public static let logCommand =
        #"tail -n 240 "$HOME/.pi-desktop/pi-host/.bootstrap/bootstrap.log" 2>/dev/null || true"#

    /// Enables lingering for the current Linux account. The sudo password is
    /// supplied only through SSH stdin and never appears in this command.
    public static let enableLingerCommand =
        #"sudo -S -p '' loginctl enable-linger "$(id -un)""#
}
