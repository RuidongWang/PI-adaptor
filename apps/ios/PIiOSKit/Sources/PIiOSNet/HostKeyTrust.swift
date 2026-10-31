import Foundation
import NIOSSH
import CryptoKit

// MARK: - 主机公钥与指纹（spec AC-02.1 / AC-02.2 / AC-02.3）

/// 一台 SSH 服务器的主机公钥，以及由它算出的 SHA256 指纹。
///
/// 指纹口径与 `ssh-keygen -lf` 一致：对公钥的 SSH 线格式（算法名与各字段连写的 base64 载荷）
/// 做 SHA256，再取 base64 且**去掉补位的 `=`**，前缀 `SHA256:`。
public struct SSHHostKey: Equatable, Sendable {
    public let algorithm: String
    /// SSH 线格式公钥的 base64（带补位），用于和固定记录逐字节比对。
    public let blobBase64: String
    /// 展示给用户的 `SHA256:...` 指纹。
    public let fingerprint: String

    public init(algorithm: String, blobBase64: String) {
        self.algorithm = algorithm
        self.blobBase64 = blobBase64
        let blob = Data(base64Encoded: blobBase64) ?? Data()
        self.fingerprint = SSHHostKey.fingerprint(ofBlob: blob)
    }

    /// 从 OpenSSH 公钥字符串（`"<alg> <base64> [comment]"`）构造。
    public init(openSSHPublicKey: String) throws {
        let parts = openSSHPublicKey.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { throw SSHHostKeyError.malformedOpenSSHPublicKey }
        let algorithm = String(parts[0])
        let blob = String(parts[1])
        guard Data(base64Encoded: blob) != nil else {
            throw SSHHostKeyError.malformedOpenSSHPublicKey
        }
        self.init(algorithm: algorithm, blobBase64: blob)
    }

    /// 直接由 NIOSSH 在握手时给出的公钥构造。
    public init(nioKey: NIOSSHPublicKey) throws {
        try self.init(openSSHPublicKey: String(openSSHPublicKey: nioKey))
    }

    public static func fingerprint(ofBlob blob: Data) -> String {
        let digest = SHA256.hash(data: blob)
        let base64 = Data(digest).base64EncodedString()
        let unpadded = base64.hasSuffix("==")
            ? String(base64.dropLast(2))
            : (base64.hasSuffix("=") ? String(base64.dropLast(1)) : base64)
        return "SHA256:" + unpadded
    }
}

public enum SSHHostKeyError: Error, Equatable, CustomStringConvertible {
    case malformedOpenSSHPublicKey

    public var description: String {
        switch self {
        case .malformedOpenSSHPublicKey:
            return "主机公钥格式不合法，无法计算指纹"
        }
    }
}

/// 与已固定记录比对的结果。
public enum HostKeyTrustStatus: Equatable, Sendable {
    /// 没有固定记录：必须展示指纹并让用户确认后才能建连（AC-02.1）。
    case firstUse
    /// 与固定记录一致。
    case matches
    /// 与固定记录不一致：拒绝连接，且不提供「一键忽略」（AC-02.2）。
    case changed(pinned: SSHHostKey)
}

public enum HostKeyTrust {
    /// 纯函数比对：`pinned == nil` 为首次，否则逐字节比较公钥并核对指纹。
    public static func evaluate(presented: SSHHostKey, pinned: SSHHostKey?) -> HostKeyTrustStatus {
        guard let pinned else { return .firstUse }
        if pinned.blobBase64 == presented.blobBase64
            && pinned.fingerprint == presented.fingerprint
            && pinned.algorithm == presented.algorithm {
            return .matches
        }
        return .changed(pinned: pinned)
    }
}

/// 用户对指纹核对页的选择（S-04「核对指纹」状态）。
public enum HostKeyConfirmation: Equatable, Sendable {
    case trust
    case reject
}

/// 需要 App 层回答「是否信任这个指纹」；由连接层在握手期间调用。
///
/// 握手必须停在这里等用户回答：AC-02.1 要求「展示指纹并要求确认，拒绝则不建立连接」，
/// 所以实现方在拿到 `.reject` 时必须让 SSH 握手失败，而不是先连上再说。
public protocol HostKeyConfirming: Sendable {
    func confirmHostKey(_ key: SSHHostKey, status: HostKeyTrustStatus) async -> HostKeyConfirmation
}

/// 固定记录变化时的本地审计事件（AC-02.3：移除旧指纹后重新固定要记一条本地审计事件）。
public struct HostKeyAuditEvent: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// 首次固定。
        case pinned
        /// 用户显式移除旧指纹。
        case pinRemoved
        /// 移除旧指纹后重新固定为新指纹。
        case repinned
        /// 指纹与固定记录不一致被拒绝。
        case mismatchRejected
    }

    public var id: UUID
    public var kind: Kind
    public var hostAddress: String
    public var fingerprint: String
    public var previousFingerprint: String?
    public var occurredAt: Date

    public init(
        id: UUID = UUID(),
        kind: Kind,
        hostAddress: String,
        fingerprint: String,
        previousFingerprint: String? = nil,
        occurredAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.hostAddress = hostAddress
        self.fingerprint = fingerprint
        self.previousFingerprint = previousFingerprint
        self.occurredAt = occurredAt
    }
}

/// 客户端侧的 host 分区键（契约 §2.4）：未配对时用 `ssh://user@host:port` 的哈希。
///
/// 已配对后应改用 `connection/pair` 返回的 `hostId`；本增量没有配对流程，
/// 因此 Keychain 记录统一用这个稳定值。
public enum HostKeyAccount {
    public static func addressString(username: String, host: String, port: Int) -> String {
        "ssh://\(username)@\(host):\(port)"
    }

    /// SHA256 十六进制小写（64 字符），跨 App 重装稳定。
    public static func identifier(username: String, host: String, port: Int) -> String {
        let digest = SHA256.hash(data: Data(addressString(username: username, host: host, port: port).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
