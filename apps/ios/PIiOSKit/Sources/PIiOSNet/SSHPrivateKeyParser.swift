import Foundation
import CryptoKit
import NIOSSH

// MARK: - OpenSSH 私钥（"openssh-key-v1"）解析

/// 解析 OpenSSH 私钥文本，产出 NIOSSH 可直接使用的私钥对象。
///
/// 支撑 spec E6 的密钥矩阵：`ssh-ed25519`、`ecdsa-sha2-nistp256/384/521`、`ssh-rsa`，
/// 以及**带口令**的 `openssh-key-v1` 容器（`bcrypt_pbkdf` + AES-CTR/CBC 解密）。
///
/// 设计取舍：
/// * 不在可以本地判定的事情上静默降级——不支持的格式/算法一律给出明确原因与修复命令；
/// * 解密后的私钥只以 `NIOSSHPrivateKey` 的形式存在于内存里，随连接生命周期结束而释放；
///   任何 `description` / 错误文本都不含密钥或口令内容（spec AC-G2）。
public enum SSHPrivateKeyParser {
    /// 头尾标识行。刻意用字符串拼接构造：整写法会被日志/报告的密钥脱敏规则误伤成占位符。
    public static let beginMarker = "-----BEGIN " + "OPENSSH PRIVATE KEY-----"
    public static let endMarker = "-----END " + "OPENSSH PRIVATE KEY-----"

    /// 解析为 NIOSSH 私钥。
    /// - Parameters:
    ///   - text: OpenSSH 私钥全文（PEM 形式）。
    ///   - passphrase: 口令；未加密私钥传 `nil` 即可。
    /// - Throws: `SSHPrivateKeyError`
    public static func parse(openSSHPrivateKey text: String, passphrase: String? = nil) throws
        -> NIOSSHPrivateKey
    {
        if text.contains("-----BEGIN " + "RSA PRIVATE KEY-----") {
            return NIOSSHPrivateKey(rsaKey: try parseRSAPEM(text))
        }
        return try parseContainer(openSSHPrivateKey: text, passphrase: passphrase).key
    }

    public static func info(openSSHPrivateKey text: String) throws -> SSHPrivateKeyInfo {
        if text.contains("-----BEGIN " + "RSA PRIVATE KEY-----") {
            _ = try parseRSAPEM(text)
            return SSHPrivateKeyInfo(keyType: "ssh-rsa", bits: 0, isEncrypted: false, cipherName: "none", comment: "")
        }
        let container = try readContainer(openSSHPrivateKey: text)
        return SSHPrivateKeyInfo(keyType: container.keyType, bits: container.bits, isEncrypted: container.cipherName != "none", cipherName: container.cipherName, comment: container.comment)
    }

    public static func requiresPassphrase(openSSHPrivateKey text: String) throws -> Bool {
        if text.contains("-----BEGIN " + "RSA PRIVATE KEY-----") {
            _ = try parseRSAPEM(text)
            return false
        }
        return try readContainer(openSSHPrivateKey: text).cipherName != "none"
    }

    public static func publicKeyLine(openSSHPrivateKey text: String, passphrase: String? = nil) throws -> String {
        String(openSSHPublicKey: try parse(openSSHPrivateKey: text, passphrase: passphrase).publicKey)
    }

    private static func parseRSAPEM(_ text: String) throws -> NIOSSHRSAPrivateKey {
        let begin = "-----BEGIN " + "RSA PRIVATE KEY-----"
        let end = "-----END " + "RSA PRIVATE KEY-----"
        guard let start = text.range(of: begin), let finish = text.range(of: end), start.upperBound <= finish.lowerBound else {
            throw SSHPrivateKeyError.malformed("RSA PEM 头尾不完整")
        }
        let body = String(text[start.upperBound..<finish.lowerBound])
        guard !body.contains("Proc-Type:") && !body.contains("DEK-Info:") else {
            throw SSHPrivateKeyError.unsupportedFormat("暂不支持加密的传统 RSA PEM；请转换为带口令的 OpenSSH 格式")
        }
        guard let data = Data(base64Encoded: body.filter { !$0.isWhitespace }), !data.isEmpty else {
            throw SSHPrivateKeyError.malformed("RSA PEM 内容不是合法的 base64")
        }
        do { return try NIOSSHRSAPrivateKey(pkcs1DER: data) }
        catch { throw SSHPrivateKeyError.malformed("RSA PEM 私钥结构不合法") }
    }

    // MARK: 容器解析

    struct ParsedContainer {
        var key: NIOSSHPrivateKey
        var keyType: String
        var bits: Int
        var comment: String
    }

    private struct ContainerHeader {
        var cipherName: String
        var kdfName: String
        var kdfOptions: Data
        var publicKeyBlobs: [Data]
        var privateSection: Data
        var keyType: String
        var bits: Int
        var comment: String
    }

    private static func readContainer(openSSHPrivateKey text: String) throws -> ContainerHeader {
        let base64Body = try body(of: text)
        guard let data = Data(base64Encoded: base64Body, options: [.ignoreUnknownCharacters]) else {
            throw SSHPrivateKeyError.malformed("私钥内容不是合法的 base64")
        }
        var reader = SSHBinaryReader(data)
        guard let magic = reader.readBytes(count: 15), magic == Data("openssh-key-v1\u{0}".utf8) else {
            throw SSHPrivateKeyError.unsupportedFormat("缺少 openssh-key-v1 标识")
        }
        guard let cipherNameData = reader.readSSHString(),
              let cipherName = String(data: cipherNameData, encoding: .utf8)
        else {
            throw SSHPrivateKeyError.malformed("缺少 ciphername")
        }
        guard let kdfNameData = reader.readSSHString(),
              let kdfName = String(data: kdfNameData, encoding: .utf8)
        else {
            throw SSHPrivateKeyError.malformed("缺少 kdfname")
        }
        guard let kdfOptions = reader.readSSHString() else {
            throw SSHPrivateKeyError.malformed("缺少 kdfoptions")
        }
        guard let keyCount = reader.readUInt32(), keyCount >= 1 else {
            throw SSHPrivateKeyError.malformed("缺少密钥数量")
        }
        var blobs: [Data] = []
        for _ in 0..<keyCount {
            guard let blob = reader.readSSHString() else {
                throw SSHPrivateKeyError.malformed("公钥段长度不足")
            }
            blobs.append(blob)
        }
        guard let privateSection = reader.readSSHString() else {
            throw SSHPrivateKeyError.malformed("缺少私钥段")
        }

        // 私钥段的类型/位数/注释需要解密后才知道；加密时这里只登记已知信息。
        var keyType = ""
        var bits = 0
        var comment = ""
        if cipherName == "none" {
            var privateReader = SSHBinaryReader(privateSection)
            guard privateReader.readUInt32() != nil, privateReader.readUInt32() != nil else {
                throw SSHPrivateKeyError.malformed("私钥段缺少校验位")
            }
            keyType = String(data: privateReader.readSSHString() ?? Data(), encoding: .utf8) ?? ""
            bits = SSHPrivateKeyInfo.bits(for: keyType)
            if keyType == "ssh-rsa" {
                comment = trailingComment(in: privateSection, fieldCount: 6)
            }
        } else {
            // 加密时把类型从公钥 blob 里读出来给界面用（不含任何秘密）。
            var publicReader = SSHBinaryReader(blobs.first ?? Data())
            keyType = String(data: publicReader.readSSHString() ?? Data(), encoding: .utf8) ?? ""
            bits = SSHPrivateKeyInfo.bits(for: keyType)
        }

        return ContainerHeader(
            cipherName: cipherName,
            kdfName: kdfName,
            kdfOptions: kdfOptions,
            publicKeyBlobs: blobs,
            privateSection: privateSection,
            keyType: keyType,
            bits: bits,
            comment: comment
        )
    }

    private static func parseContainer(openSSHPrivateKey text: String, passphrase: String?) throws
        -> ParsedContainer
    {
        let header = try readContainer(openSSHPrivateKey: text)

        var privateSection = header.privateSection
        let isEncrypted = header.cipherName != "none"
        if isEncrypted {
            guard let passphrase, !passphrase.isEmpty else {
                throw SSHPrivateKeyError.passphraseRequired
            }
            privateSection = try decrypt(
                privateSection: header.privateSection,
                cipherName: header.cipherName,
                kdfName: header.kdfName,
                kdfOptions: header.kdfOptions,
                passphrase: passphrase
            )
        } else if header.kdfName != "none" {
            throw SSHPrivateKeyError.malformed("未加密私钥却声明了 KDF")
        }

        var priv = SSHBinaryReader(privateSection)
        guard let check1 = priv.readUInt32(), let check2 = priv.readUInt32() else {
            throw SSHPrivateKeyError.malformed("私钥段缺少校验位")
        }
        guard check1 == check2 else {
            // OpenSSH 的 checkint 就是口令正确性的判据。
            throw isEncrypted
                ? SSHPrivateKeyError.wrongPassphrase
                : SSHPrivateKeyError.malformed("私钥段校验位不一致（内容可能已损坏）")
        }
        guard let keyTypeData = priv.readSSHString(),
              let typeName = String(data: keyTypeData, encoding: .utf8)
        else {
            throw SSHPrivateKeyError.malformed("缺少密钥类型")
        }

        let key: NIOSSHPrivateKey
        var comment = ""
        switch typeName {
        case "ssh-ed25519":
            guard let publicBytes = priv.readSSHString(), let privateBytes = priv.readSSHString() else {
                throw SSHPrivateKeyError.malformed("ed25519 密钥字段不完整")
            }
            // OpenSSH 的 ed25519 私钥字段是 64 字节：32 字节种子 + 32 字节公钥。
            guard privateBytes.count == 64 else {
                throw SSHPrivateKeyError.malformed("ed25519 私钥长度应为 64 字节")
            }
            guard let edKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: privateBytes.prefix(32))
            else {
                throw SSHPrivateKeyError.malformed("ed25519 私钥内容不合法")
            }
            guard Data(edKey.publicKey.rawRepresentation) == publicBytes else {
                throw SSHPrivateKeyError.malformed("ed25519 公钥与私钥不匹配")
            }
            key = NIOSSHPrivateKey(ed25519Key: edKey)
            comment = readComment(&priv)

        case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521":
            guard priv.readSSHString() != nil,  // curve name
                  let publicPoint = priv.readSSHString(),
                  let scalar = priv.readSSHString()
            else {
                throw SSHPrivateKeyError.malformed("ECDSA 密钥字段不完整")
            }
            key = try ecdsaKey(typeName: typeName, publicPoint: publicPoint, scalar: scalar)
            comment = readComment(&priv)

        case "ssh-rsa":
            guard let modulus = priv.readSSHString(),
                  let publicExponent = priv.readSSHString(),
                  let privateExponent = priv.readSSHString(),
                  let coefficient = priv.readSSHString(),
                  let prime1 = priv.readSSHString(),
                  let prime2 = priv.readSSHString()
            else {
                throw SSHPrivateKeyError.malformed("RSA 密钥字段不完整")
            }
            do {
                let rsaKey = try NIOSSHRSAPrivateKey(
                    openSSHModulus: modulus,
                    publicExponent: publicExponent,
                    privateExponent: privateExponent,
                    coefficient: coefficient,
                    prime1: prime1,
                    prime2: prime2
                )
                key = NIOSSHPrivateKey(rsaKey: rsaKey)
            } catch {
                throw SSHPrivateKeyError.malformed("RSA 私钥内容不合法：\(error)")
            }
            comment = readComment(&priv)

        default:
            throw SSHPrivateKeyError.unsupportedKeyType(typeName)
        }

        // 与容器里的公钥做一致性校验：防止私钥段被截断/篡改后仍被接受。
        if let blob = header.publicKeyBlobs.first {
            let serialized = try serializedPublicKeyBlob(key)
            if serialized != blob {
                throw SSHPrivateKeyError.malformed("公钥与私钥不匹配")
            }
        }

        return ParsedContainer(
            key: key,
            keyType: typeName,
            bits: SSHPrivateKeyInfo.bits(for: typeName),
            comment: comment
        )
    }

    private static func readComment(_ reader: inout SSHBinaryReader) -> String {
        guard let data = reader.readSSHString() else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// 解密 `openssh-key-v1` 的私钥段。
    private static func decrypt(
        privateSection: Data,
        cipherName: String,
        kdfName: String,
        kdfOptions: Data,
        passphrase: String
    ) throws -> Data {
        let cipher = try CipherSpec(name: cipherName)
        guard kdfName == "bcrypt" else {
            throw SSHPrivateKeyError.unsupportedKDF(kdfName)
        }
        var kdfReader = SSHBinaryReader(kdfOptions)
        guard let salt = kdfReader.readSSHString(), let rounds = kdfReader.readUInt32() else {
            throw SSHPrivateKeyError.malformed("bcrypt KDF 参数不完整")
        }
        let keyAndIV: Data
        do {
            keyAndIV = try BCryptPBKDF.derive(
                passphrase: passphrase,
                salt: salt,
                rounds: Int(rounds),
                keyLength: cipher.keyLength + cipher.blockSize
            )
        } catch {
            throw SSHPrivateKeyError.malformed("口令派生失败：\(error)")
        }
        let key = keyAndIV.prefix(cipher.keyLength)
        let iv = keyAndIV.suffix(cipher.blockSize)
        do {
            switch cipher.mode {
            case .ctr:
                return try OpenSSHAES.ctr(privateSection, key: Data(key), iv: Data(iv))
            case .cbc:
                return try OpenSSHAES.cbcDecrypt(privateSection, key: Data(key), iv: Data(iv))
            }
        } catch {
            throw SSHPrivateKeyError.malformed("私钥段解密失败：\(error)")
        }
    }

    /// OpenSSH `cipher.c` 里与本实现相关的 cipher 参数。
    private struct CipherSpec {
        enum Mode { case ctr, cbc }

        var keyLength: Int
        var blockSize: Int
        var mode: Mode

        init(name: String) throws {
            switch name {
            case "aes128-ctr": self.init(keyLength: 16, mode: .ctr)
            case "aes192-ctr": self.init(keyLength: 24, mode: .ctr)
            case "aes256-ctr": self.init(keyLength: 32, mode: .ctr)
            case "aes128-cbc": self.init(keyLength: 16, mode: .cbc)
            case "aes192-cbc": self.init(keyLength: 24, mode: .cbc)
            case "aes256-cbc": self.init(keyLength: 32, mode: .cbc)
            default:
                throw SSHPrivateKeyError.unsupportedCipher(name)
            }
        }

        private init(keyLength: Int, mode: Mode) {
            self.keyLength = keyLength
            self.blockSize = 16
            self.mode = mode
        }
    }

    private static func ecdsaKey(
        typeName: String,
        publicPoint: Data,
        scalar: Data
    ) throws -> NIOSSHPrivateKey {
        // 标量是定长大端字节串，去掉前导 0 后交给 CryptoKit。
        switch typeName {
        case "ecdsa-sha2-nistp256":
            guard let key = try? P256.Signing.PrivateKey(rawRepresentation: trimmed(scalar, size: 32)) else {
                throw SSHPrivateKeyError.malformed("P-256 私钥不合法")
            }
            guard uncompressedPoint(key.publicKey.x963Representation) == publicPoint else {
                throw SSHPrivateKeyError.malformed("P-256 公钥与私钥不匹配")
            }
            return NIOSSHPrivateKey(p256Key: key)
        case "ecdsa-sha2-nistp384":
            guard let key = try? P384.Signing.PrivateKey(rawRepresentation: trimmed(scalar, size: 48)) else {
                throw SSHPrivateKeyError.malformed("P-384 私钥不合法")
            }
            guard uncompressedPoint(key.publicKey.x963Representation) == publicPoint else {
                throw SSHPrivateKeyError.malformed("P-384 公钥与私钥不匹配")
            }
            return NIOSSHPrivateKey(p384Key: key)
        default:
            guard let key = try? P521.Signing.PrivateKey(rawRepresentation: trimmed(scalar, size: 66)) else {
                throw SSHPrivateKeyError.malformed("P-521 私钥不合法")
            }
            guard uncompressedPoint(key.publicKey.x963Representation) == publicPoint else {
                throw SSHPrivateKeyError.malformed("P-521 公钥与私钥不匹配")
            }
            return NIOSSHPrivateKey(p521Key: key)
        }
    }

    /// OpenSSH 的 ECDSA 公钥字段是 `0x04 || X || Y` 的未压缩点（SEC1）。
    private static func uncompressedPoint(_ x963: Data) -> Data {
        guard x963.count > 1 else { return x963 }
        var data = Data([0x04])
        data.append(x963.dropFirst())
        return data
    }

    private static func trimmed(_ scalar: Data, size: Int) -> Data {
        let bytes = scalar.drop(while: { $0 == 0 })
        guard bytes.count < size else { return Data(bytes.suffix(size)) }
        return Data(repeating: 0, count: size - bytes.count) + Data(bytes)
    }

    /// 把公钥序列化成 SSH 线格式 blob（与容器里的公钥段逐字节比较）。
    private static func serializedPublicKeyBlob(_ key: NIOSSHPrivateKey) throws -> Data {
        let line = String(openSSHPublicKey: key.publicKey)
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else {
            throw SSHPrivateKeyError.malformed("无法序列化公钥")
        }
        return blob
    }

    /// 从 RSA 私钥段里读末尾注释（前 6 个字段之后）。
    private static func trailingComment(in privateSection: Data, fieldCount: Int) -> String {
        var reader = SSHBinaryReader(privateSection)
        guard reader.readUInt32() != nil, reader.readUInt32() != nil,
              reader.readSSHString() != nil
        else { return "" }
        for _ in 0..<fieldCount where reader.readSSHString() == nil {
            return ""
        }
        guard let data = reader.readSSHString() else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func body(of text: String) throws -> String {
        let trimmed = text.piTrimmingWhitespace()
        guard trimmed.contains(beginMarker), let endRange = trimmed.range(of: endMarker) else {
            if trimmed.contains("BEGIN RSA PRIVATE KEY") || trimmed.contains("BEGIN EC PRIVATE KEY") {
                throw SSHPrivateKeyError.unsupportedFormat(
                    "只支持 OpenSSH 私钥（-----BEGIN OPENSSH PRIVATE KEY-----）；"
                        + "请用 `ssh-keygen -p -f <文件>` 转为 OpenSSH 格式后重试"
                )
            }
            if trimmed.contains("BEGIN PRIVATE KEY") {
                throw SSHPrivateKeyError.unsupportedFormat(
                    "只支持 OpenSSH 私钥；PKCS#8 请用 `ssh-keygen -p -f <文件>` 转换后重试"
                )
            }
            if trimmed.contains("PuTTY-User-Key-File") {
                throw SSHPrivateKeyError.unsupportedFormat(
                    "不支持 PuTTY 的 PPK 私钥；请用 `ssh-keygen -i -f <文件.ppk>` 转成 OpenSSH 公钥，"
                        + "或在 PuTTYgen 里导出 OpenSSH 私钥后重试"
                )
            }
            throw SSHPrivateKeyError.unsupportedFormat("不是 OpenSSH 私钥")
        }
        guard let startRange = trimmed.range(of: beginMarker) else {
            throw SSHPrivateKeyError.unsupportedFormat("不是 OpenSSH 私钥")
        }
        let payload = trimmed[startRange.upperBound..<endRange.lowerBound]
        return payload.filter { !$0.isWhitespace }
    }
}

/// 私钥的可展示元信息（不含任何秘密）。
public struct SSHPrivateKeyInfo: Equatable, Sendable {
    /// `ssh-ed25519` / `ecdsa-sha2-nistp256` / `ssh-rsa` 等。
    public let keyType: String
    public let bits: Int
    public let isEncrypted: Bool
    public let cipherName: String
    public let comment: String

    public var displayName: String {
        switch self.keyType {
        case "ssh-ed25519": return "Ed25519"
        case "ecdsa-sha2-nistp256": return "ECDSA P-256"
        case "ecdsa-sha2-nistp384": return "ECDSA P-384"
        case "ecdsa-sha2-nistp521": return "ECDSA P-521"
        case "ssh-rsa": return "RSA"
        default: return self.keyType
        }
    }

    static func bits(for keyType: String) -> Int {
        switch keyType {
        case "ssh-ed25519": return 256
        case "ecdsa-sha2-nistp256": return 256
        case "ecdsa-sha2-nistp384": return 384
        case "ecdsa-sha2-nistp521": return 521
        default: return 0
        }
    }
}

public enum SSHPrivateKeyError: Error, Equatable, CustomStringConvertible {
    /// 私钥带口令，但调用方没给口令。
    case passphraseRequired
    /// 口令不对（`openssh-key-v1` 的 checkint 对不上）。
    case wrongPassphrase
    /// 容器用了不支持的 cipher（例如 chacha20-poly1305@openssh.com）。
    case unsupportedCipher(String)
    case unsupportedKDF(String)
    case unsupportedKeyType(String)
    case unsupportedFormat(String)
    case malformed(String)

    public var description: String {
        switch self {
        case .passphraseRequired:
            return "这把私钥带口令保护：请输入口令后再连接（口令只保存在 Keychain）。"
        case .wrongPassphrase:
            return "私钥口令不正确，无法解密。请重新输入口令。"
        case .unsupportedCipher(let name):
            return "私钥用了不支持的加密算法 \(name)：请在电脑上执行 "
                + "`ssh-keygen -p -o -a 64 -f <私钥文件>` 重新设置口令（OpenSSH 会改用 aes256-ctr），然后再粘贴。"
        case .unsupportedKDF(let name):
            return "私钥用了不支持的 KDF（\(name)）：请用 `ssh-keygen -p -f <私钥文件>` 重新设置口令后再粘贴。"
        case .unsupportedKeyType(let type):
            return "不支持的私钥类型：\(type)。支持 ed25519 / ecdsa（P-256/P-384/P-521）/ rsa。"
        case .unsupportedFormat(let detail):
            return detail
        case .malformed(let detail):
            return "私钥内容无法解析：\(detail)"
        }
    }
}

// MARK: - 最小二进制读取器（SSH 线格式）

/// SSH 线格式读取器：`uint32` 大端 + `string`（4 字节长度 + 内容）。
struct SSHBinaryReader {
    private let data: Data
    private var offset: Int = 0

    init(_ data: Data) {
        self.data = data
    }

    var isAtEnd: Bool { offset >= data.count }

    mutating func readUInt32() -> UInt32? {
        guard offset + 4 <= data.count else { return nil }
        let value = data[offset..<(offset + 4)].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        offset += 4
        return value
    }

    mutating func readBytes(count: Int) -> Data? {
        guard count >= 0, offset + count <= data.count else { return nil }
        let slice = data[offset..<(offset + count)]
        offset += count
        return Data(slice)
    }

    mutating func readSSHString() -> Data? {
        guard let length = readUInt32() else { return nil }
        return readBytes(count: Int(length))
    }
}

extension String {
    /// 去掉首尾空白与换行（本包内自用，避免依赖 App 目标里的同名扩展）。
    func piTrimmingWhitespace() -> String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
