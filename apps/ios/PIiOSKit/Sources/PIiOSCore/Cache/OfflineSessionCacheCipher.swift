import Foundation

#if canImport(CryptoKit) && canImport(Security)
import CryptoKit
import Security

/// 离线缓存敏感内容的静态加密（契约「缓存需加密容器」）。
///
/// 本包没有 SQLCipher 依赖，SQLite 容器本身仍是明文（只靠文件保护）——因此
/// 逐列把**敏感值**（消息正文、草稿、审批 payload、会话标题）用 AES-GCM 密封，
/// 密钥保存在 Keychain，且不参与备份。密封值带 `enc:v1:` 前缀：
///
/// - 旧版本写下的明文行没有前缀，读取时按明文返回，下次写入时自动重新密封；
/// - Keychain 不可用时**降级为明文**而不是拒绝工作：离线缓存是辅助能力，
///   让它彻底失效比暂时不加密更糟。降级只影响加密，文件保护仍然生效。
public enum OfflineCacheCipher {
    static let prefix = "enc:v1:"
    private static let service = "com.pi-ios.offline-cache"
    private static let account = "content-key"

    /// 密封一段文本；无法加密时原样返回（见类型注释的降级说明）。
    public static func seal(_ plaintext: String) -> String {
        guard let key = loadKey(), let data = plaintext.data(using: .utf8) else { return plaintext }
        guard let sealed = try? AES.GCM.seal(data, using: key), let combined = sealed.combined else {
            return plaintext
        }
        return prefix + combined.base64EncodedString()
    }

    /// 还原一段文本；无前缀视为明文，密钥不可用时返回空串而不是把密文当正文。
    public static func open(_ stored: String) -> String {
        openOrNil(stored) ?? ""
    }

    /// 还原一段文本；解密失败返回 nil，供持久化层识别「解密失败不可静默覆盖为默认值」。
    public static func openOrNil(_ stored: String) -> String? {
        guard stored.hasPrefix(prefix) else { return stored }
        let base64 = String(stored.dropFirst(prefix.count))
        guard let key = loadKey(),
              let combined = Data(base64Encoded: base64),
              let box = try? AES.GCM.SealedBox(combined: combined),
              let data = try? AES.GCM.open(box, using: key),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        return text
    }

    public static func seal(optional: String?) -> String? { optional.map(seal) }

    public static func open(optional: String?) -> String? { optional.map(open) }

    public static func openOrNil(optional: String?) -> String? {
        guard let optional else { return nil }
        return openOrNil(optional)
    }

    // MARK: - Keychain 密钥

    private static let keyLock = NSLock()
    private static var cachedKey: SymmetricKey?

    private static func loadKey() -> SymmetricKey? {
        keyLock.lock()
        defer { keyLock.unlock() }
        if let cached = cachedKey { return cached }

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data, data.count == 32 {
            let key = SymmetricKey(data: data)
            cachedKey = key
            return key
        }

        // Only generate a new key if Keychain confirmed the item does NOT exist.
        // If Keychain returned an error (e.g. locked, permissions), return nil rather than
        // generating an ephemeral key that would corrupt data on subsequent reads.
        guard status == errSecItemNotFound else { return nil }

        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return nil
        }
        let data = Data(bytes)
        let addAttributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data
        ]
        let addStatus = SecItemAdd(addAttributes as CFDictionary, nil)
        if addStatus == errSecSuccess {
            let key = SymmetricKey(data: data)
            cachedKey = key
            return key
        } else if addStatus == errSecDuplicateItem {
            // Concurrent key creation by another thread/process: re-read the winning key.
            // Never overwrite existing keys with SecItemUpdate, which would corrupt previously encrypted data.
            var retryItem: CFTypeRef?
            if SecItemCopyMatching(query as CFDictionary, &retryItem) == errSecSuccess,
               let retryData = retryItem as? Data, retryData.count == 32 {
                let key = SymmetricKey(data: retryData)
                cachedKey = key
                return key
            }
        }
        return nil
    }
}

#else

/// 平台没有 CryptoKit/Security（例如非 Apple 目标）时的直通实现：
/// 不加密，但保证接口一致、缓存仍可用。
public enum OfflineCacheCipher {
    public static func seal(_ plaintext: String) -> String { plaintext }
    public static func open(_ stored: String) -> String { stored }
    public static func openOrNil(_ stored: String) -> String? { stored }
    public static func seal(optional: String?) -> String? { optional }
    public static func open(optional: String?) -> String? { optional }
    public static func openOrNil(optional: String?) -> String? { optional }
}

#endif
