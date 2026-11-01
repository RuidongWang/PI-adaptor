import Foundation
import Security
import PIiOSCore
import PIiOSNet

/// 凭证与主机指纹的唯一落盘位置（spec AC-G4）。
///
/// 三条约束来自契约与 spec：
/// 1. `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`，不参与 iCloud 同步；
/// 2. 密码、私钥、设备令牌**不写** `state-v1.json`（AC-04.3 / AC-G4）；
/// 3. 任何对外描述都不含凭证内容（AC-G2）。
enum KeychainStore {
    /// 服务名按用途分开，便于单独撤销。
    private enum Service {
        static let credential = "dev.piios.credential"
        static let deviceToken = "dev.piios.devicetoken"
        static let hostKey = "dev.piios.hostkey"
        static let providerKey = "dev.piios.providerkey"
    }

    /// 存储键：未配对时用 `ssh://user@host:port` 的 SHA256（契约 §2.4 `hostKey` 规则）。
    static func account(username: String, host: String, port: Int) -> String {
        HostKeyAccount.identifier(username: username, host: host, port: port)
    }

    // MARK: - 通用读写

    private static func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    @discardableResult
    static func set(_ value: Data, service: String, account: String) -> Bool {
        let query = baseQuery(service: service, account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: value,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let result = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if result == errSecSuccess { return true }
        guard result == errSecItemNotFound else { return false }
        var insert = query
        attributes.forEach { insert[$0.key] = $0.value }
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    static func get(service: String, account: String) -> Data? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    @discardableResult
    static func delete(service: String, account: String) -> Bool {
        SecItemDelete(baseQuery(service: service, account: account) as CFDictionary) == errSecSuccess
    }

    // MARK: - 凭证

    /// 凭证按 `authKind` 序列化；只进 Keychain，不进 JSON（spec AC-G4）。
    /// 私钥口令与私钥分开存放，但同一条 Keychain 记录里，访问级别同样是
    /// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`。
    private struct StoredCredential: Codable {
        var kind: String
        var secret: String
        /// 私钥口令；`nil` 表示私钥未加密。旧记录没有这个字段，解码后为 `nil`。
        var passphrase: String?
    }

    @discardableResult
    static func saveCredential(_ credential: SSHCredential, kind: AuthKind, account: String) -> Bool {
        let stored: StoredCredential
        switch credential {
        case .password(let value):
            stored = StoredCredential(kind: AuthKind.password.rawValue, secret: value)
        case .privateKey(let text, let passphrase):
            stored = StoredCredential(
                kind: AuthKind.privateKey.rawValue,
                secret: text,
                passphrase: (passphrase?.isEmpty == false) ? passphrase : nil
            )
        }
        _ = kind
        guard let data = try? JSONEncoder().encode(stored) else { return false }
        return set(data, service: Service.credential, account: account)
    }

    static func loadCredential(account: String) -> SSHCredential? {
        guard let data = get(service: Service.credential, account: account),
              let stored = try? JSONDecoder().decode(StoredCredential.self, from: data)
        else { return nil }
        switch AuthKind(rawValue: stored.kind) {
        case .password: return .password(stored.secret)
        case .privateKey: return .privateKey(openSSHText: stored.secret, passphrase: stored.passphrase)
        case nil: return nil
        }
    }

    @discardableResult
    static func deleteCredential(account: String) -> Bool {
        delete(service: Service.credential, account: account)
    }

    private struct StoredPairing: Codable {
        let deviceId: String
        let deviceToken: String
    }

    struct PairingCredential: Equatable {
        let deviceId: String
        let deviceToken: String
    }

    /// Device tokens are scoped by the host record UUID, not only its SSH
    /// endpoint. Two Hosts may intentionally point at the same SSH server with
    /// different PI-adaptor ports and must not overwrite each other.
    private static func deviceTokenAccount(hostID: UUID) -> String {
        "host-token:\(hostID.uuidString.lowercased())"
    }

    private static func pairing(from data: Data?) -> PairingCredential? {
        guard let data,
              let pairing = try? JSONDecoder().decode(StoredPairing.self, from: data),
              !pairing.deviceId.isEmpty,
              pairing.deviceToken.hasPrefix("pdt2.")
        else { return nil }
        return PairingCredential(
            deviceId: pairing.deviceId,
            deviceToken: pairing.deviceToken
        )
    }

    private static func validPairing(hostID: UUID) -> StoredPairing? {
        let data = get(service: Service.deviceToken, account: deviceTokenAccount(hostID: hostID))
        guard let data,
              let pairing = try? JSONDecoder().decode(StoredPairing.self, from: data),
              !pairing.deviceId.isEmpty,
              (pairing.deviceToken.hasPrefix("pdt1.") || pairing.deviceToken.hasPrefix("pdt2."))
        else { return nil }
        return pairing
    }

    /// 单条 Keychain 记录同时保存设备 ID 与令牌，避免部分写入。
    @discardableResult
    static func savePairing(
        deviceId: String,
        deviceToken: String,
        hostID: UUID
    ) -> Bool {
        guard !deviceId.isEmpty,
              (deviceToken.hasPrefix("pdt1.") || deviceToken.hasPrefix("pdt2.")),
              let data = try? JSONEncoder().encode(StoredPairing(deviceId: deviceId, deviceToken: deviceToken)) else { return false }
        return set(data, service: Service.deviceToken, account: deviceTokenAccount(hostID: hostID))
    }

    /// Persists the device credential issued by the current reinstall attempt.
    /// The active host token remains untouched until `promoteStagedPairing`
    /// has verified that the runtime is the configured PI-adaptor release.
    @discardableResult
    static func saveStagedPairing(
        deviceId: String,
        deviceToken: String,
        hostID: UUID,
        attemptId: String,
        targetPort: Int
    ) -> Bool {
        guard let staged = BootstrapStagedCredential(
            hostID: hostID,
            attemptId: attemptId,
            targetPort: targetPort,
            deviceId: deviceId,
            deviceToken: deviceToken
        ),
        let data = try? JSONEncoder().encode(staged)
        else { return false }
        return set(
            data,
            service: Service.deviceToken,
            account: BootstrapStagedCredential.account(
                hostID: hostID,
                attemptId: attemptId
            )
        )
    }

    static func loadStagedPairing(hostID: UUID, attemptId: String) -> PairingCredential? {
        let account = BootstrapStagedCredential.account(
            hostID: hostID,
            attemptId: attemptId
        )
        guard let data = get(service: Service.deviceToken, account: account),
              let staged = BootstrapStagedCredential.decode(
                account: account,
                data: data,
                expectedHostID: hostID
              )
        else { return nil }
        return PairingCredential(
            deviceId: staged.deviceId,
            deviceToken: staged.deviceToken
        )
    }

    /// Enumerates only attempt-scoped accounts for this Host. Primary
    /// `host-token:` records are excluded before decoding, so recovery can
    /// never select or overwrite the currently active credential.
    static func loadAllStagedPairings(hostID: UUID) -> [BootstrapStagedCredential] {
        let prefix = "\(BootstrapStagedCredential.accountPrefix)"
            + "\(hostID.uuidString.lowercased()):"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Service.deviceToken,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]]
        else { return [] }
        let candidates: [(account: String, data: Data)] = items.compactMap { item in
            guard let account = item[kSecAttrAccount as String] as? String,
                  account.hasPrefix(prefix),
                  let data = item[kSecValueData as String] as? Data
            else { return nil }
            return (account, data)
        }
        return BootstrapStagedCredential.recoverable(
            from: candidates,
            expectedHostID: hostID
        )
    }

    static func loadActivePairing(hostID: UUID) -> PairingCredential? {
        guard let pairing = validPairing(hostID: hostID) else { return nil }
        return PairingCredential(
            deviceId: pairing.deviceId,
            deviceToken: pairing.deviceToken
        )
    }

    /// Commits the staged credential only after runtime identity, version, and
    /// ping have all passed. Writing the primary record first means a failed
    /// staging cleanup can only leave redundant data; it can never replace a
    /// valid active token with a half-promoted value.
    @discardableResult
    static func promoteStagedPairing(hostID: UUID, attemptId: String) -> Bool {
        guard let staged = loadStagedPairing(hostID: hostID, attemptId: attemptId),
              savePairing(
                deviceId: staged.deviceId,
                deviceToken: staged.deviceToken,
                hostID: hostID
              )
        else { return false }
        _ = clearStagedPairing(hostID: hostID, attemptId: attemptId)
        return true
    }

    @discardableResult
    static func clearStagedPairing(hostID: UUID, attemptId: String) -> Bool {
        delete(
            service: Service.deviceToken,
            account: BootstrapStagedCredential.account(
                hostID: hostID,
                attemptId: attemptId
            )
        )
    }

    @discardableResult
    static func clearStagedPairing(_ staged: BootstrapStagedCredential) -> Bool {
        delete(
            service: Service.deviceToken,
            account: BootstrapStagedCredential.account(
                hostID: staged.hostID,
                attemptId: staged.attemptId
            )
        )
    }

    static func loadDeviceId(hostID: UUID) -> String? {
        validPairing(hostID: hostID)?.deviceId
    }

    // MARK: - 设备令牌（契约 §2.3）

    static func loadDeviceToken(hostID: UUID) -> String? {
        validPairing(hostID: hostID)?.deviceToken
    }

    static func hasScopedDeviceToken(hostID: UUID) -> Bool {
        validPairing(hostID: hostID) != nil
    }

    /// One-way migration from the old endpoint-scoped account. The raw bytes are
    /// copied so legacy `StoredPairing` and bare-token formats stay readable.
    @discardableResult
    static func migrateLegacyDeviceToken(hostID: UUID, legacyAccount: String) -> Bool {
        let scopedAccount = deviceTokenAccount(hostID: hostID)
        if validPairing(hostID: hostID) != nil {
            return true
        }
        guard let legacy = get(service: Service.deviceToken, account: legacyAccount) else {
            return false
        }
        guard let pairing = try? JSONDecoder().decode(StoredPairing.self, from: legacy),
              !pairing.deviceId.isEmpty,
              (pairing.deviceToken.hasPrefix("pdt1.") || pairing.deviceToken.hasPrefix("pdt2."))
        else { return false }
        return set(legacy, service: Service.deviceToken, account: scopedAccount)
    }

    @discardableResult
    static func deleteLegacyDeviceToken(account: String) -> Bool {
        delete(service: Service.deviceToken, account: account)
    }

    @discardableResult
    static func deleteDeviceToken(
        hostID: UUID,
        legacyAccount: String,
        deleteLegacy: Bool
    ) -> Bool {
        let scoped = delete(service: Service.deviceToken, account: deviceTokenAccount(hostID: hostID))
        let legacy = deleteLegacy
            ? delete(service: Service.deviceToken, account: legacyAccount)
            : false
        return scoped || legacy
    }

    // MARK: - 主机指纹固定记录（TOFU，AC-02.1 / AC-02.2 / AC-02.3）

    static func saveHostKey(_ key: SSHHostKey, account: String) -> Bool {
        let stored = HostKeyPin(algorithm: key.algorithm, blobBase64: key.blobBase64, fingerprint: key.fingerprint)
        guard let data = try? JSONEncoder().encode(stored) else { return false }
        return set(data, service: Service.hostKey, account: account)
    }

    static func loadHostKey(account: String) -> SSHHostKey? {
        guard let data = get(service: Service.hostKey, account: account),
              let stored = try? JSONDecoder().decode(HostKeyPin.self, from: data)
        else { return nil }
        return SSHHostKey(algorithm: stored.algorithm, blobBase64: stored.blobBase64)
    }

    @discardableResult
    static func deleteHostKey(account: String) -> Bool {
        delete(service: Service.hostKey, account: account)
    }

    // MARK: - Provider API keys（模型服务密钥）

    /// The model-provider API key is the only place a provider credential lives
    /// on device. It is sealed by the Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`,
    /// never synced, never written to `state-v1.json`) and scoped by
    /// (host, provider) so the same provider id on two Hosts does not collide.
    ///
    /// Kept locally so a provider imported over the legacy SSH path can be
    /// mirrored into the v2 store (or re-imported) without asking the user to
    /// retype the key.
    private static func providerKeyAccount(hostID: UUID, providerId: String) -> String {
        "provider-key:\(hostID.uuidString.lowercased()):\(providerId)"
    }

    @discardableResult
    static func saveProviderKey(_ key: String, hostID: UUID, providerId: String) -> Bool {
        guard !key.isEmpty, let data = key.data(using: .utf8) else { return false }
        return set(
            data,
            service: Service.providerKey,
            account: providerKeyAccount(hostID: hostID, providerId: providerId)
        )
    }

    static func loadProviderKey(hostID: UUID, providerId: String) -> String? {
        guard let data = get(
            service: Service.providerKey,
            account: providerKeyAccount(hostID: hostID, providerId: providerId)
        ) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func deleteProviderKey(hostID: UUID, providerId: String) -> Bool {
        delete(
            service: Service.providerKey,
            account: providerKeyAccount(hostID: hostID, providerId: providerId)
        )
    }
}

/// Keychain 里的固定记录形态（`SSHHostKey` 的 `Codable` 投影）。
struct HostKeyPin: Codable, Equatable {
    var algorithm: String
    var blobBase64: String
    var fingerprint: String
}
