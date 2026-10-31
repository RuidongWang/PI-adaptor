//===----------------------------------------------------------------------===//
//
// 本文件是 PI-IOS 对 apple/swift-nio-ssh 0.15.1 的本地补丁（Apache-2.0）。
// 上游没有 RSA 支持，这里补上「RSA 公钥 / 私钥 + rsa-sha2-256/512 签名」。
// 实现原则：
//   * 只做 RSA 需要的最小集合，不改 ed25519 / ECDSA 的任何行为；
//   * 签名与验签委托给 Security 框架的 SecKey（Apple 平台自带，避免引入 bignum 实现）；
//   * 密钥在内存里只以 PKCS#1 DER 形式存在，SecKey 按需创建、用完即弃。
// 见 Vendor/swift-nio-ssh/PATCHES.md。
//
//===----------------------------------------------------------------------===//

import Foundation
import NIOCore

/// RSA 签名算法（RFC 8332）。`rsa-sha2-256` / `rsa-sha2-512` 是公钥算法名，
/// 但它们底下的公钥 blob 仍然以 `ssh-rsa` 标识——这是 RFC 8332 的规定，容易踩坑。
public enum NIOSSHRSASignatureAlgorithm: String, Sendable, Hashable {
    case sha256 = "rsa-sha2-256"
    case sha512 = "rsa-sha2-512"

    /// 公钥 blob 里的算法标识符（始终是 "ssh-rsa"）。
    public static let publicKeyIdentifier = "ssh-rsa"
}

// MARK: - 公钥

/// 一个 RSA 公钥：`mpint e` + `mpint n`（Wire 格式顺序就是 e 在前）。
public struct NIOSSHRSAPublicKey: Sendable, Hashable {
    /// 指数 e 的大端字节（保留 mpint 的正号前导 0，直接就是 DER INTEGER 的内容）。
    public let exponent: Data
    /// 模数 n 的大端字节（同上）。
    public let modulus: Data
    /// 用这个公钥做用户认证时优先使用的签名算法；`rsa-sha2-256` 兼容性最好。
    public let preferredSignatureAlgorithm: NIOSSHRSASignatureAlgorithm

    public init(
        modulus: Data,
        exponent: Data,
        preferredSignatureAlgorithm: NIOSSHRSASignatureAlgorithm = .sha256
    ) {
        self.modulus = modulus
        self.exponent = exponent
        self.preferredSignatureAlgorithm = preferredSignatureAlgorithm
    }

    /// 去掉前导零后的模数（用于展示/比较，不参与 DER 编码）。
    public var keySize: Int {
        let bytes = modulus.drop { $0 == 0 }
        return bytes.count * 8
    }

    public static func == (lhs: NIOSSHRSAPublicKey, rhs: NIOSSHRSAPublicKey) -> Bool {
        lhs.modulus == rhs.modulus && lhs.exponent == rhs.exponent
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(modulus)
        hasher.combine(exponent)
    }

    /// PKCS#1 `RSAPublicKey` DER（SEQUENCE { INTEGER n, INTEGER e }）。
    public var pkcs1DER: Data {
        var body = Data()
        body.append(DER.integer(modulus))
        body.append(DER.integer(exponent))
        return DER.sequence(body)
    }

    /// 用这个公钥验证 `signature` 是否为 `message` 的 PKCS#1 v1.5 签名。
    public func isValidSignature(
        _ signature: Data,
        forMessage message: Data,
        algorithm: NIOSSHRSASignatureAlgorithm
    ) -> Bool {
        NIOSSHRSACrypto.verify(
            publicKeyDER: pkcs1DER,
            signature: signature,
            message: message,
            algorithm: algorithm
        )
    }
}

// MARK: - 私钥

/// 一个 RSA 私钥，以 PKCS#1 `RSAPrivateKey` DER 保存（内含 n/e/d/p/q/…）。
public struct NIOSSHRSAPrivateKey: Sendable {
    /// PKCS#1 `RSAPrivateKey` DER。
    public let pkcs1DER: Data
    public let publicKey: NIOSSHRSAPublicKey

    public var signatureAlgorithm: NIOSSHRSASignatureAlgorithm { self.publicKey.preferredSignatureAlgorithm }

    /// - Parameters:
    ///   - pkcs1DER: PKCS#1 `RSAPrivateKey` DER（OpenSSH 私钥里的各字段可直接拼出这个结构）。
    ///   - signatureAlgorithm: 用户认证时使用的签名算法。
    public init(pkcs1DER: Data, signatureAlgorithm: NIOSSHRSASignatureAlgorithm = .sha256) throws {
        let components = try DER.RSAPrivateKeyComponents(pkcs1DER: pkcs1DER)
        self.pkcs1DER = pkcs1DER
        self.publicKey = NIOSSHRSAPublicKey(
            modulus: components.modulus,
            exponent: components.publicExponent,
            preferredSignatureAlgorithm: signatureAlgorithm
        )
    }

    /// 用 PKCS#1 的各整数字段构造（字段顺序与 OpenSSH 私钥一致，便于直接对接）。
    public init(
        modulus: Data,
        publicExponent: Data,
        privateExponent: Data,
        prime1: Data,
        prime2: Data,
        exponent1: Data,
        exponent2: Data,
        coefficient: Data,
        signatureAlgorithm: NIOSSHRSASignatureAlgorithm = .sha256
    ) throws {
        var body = Data()
        body.append(DER.integer(Data([0])))  // version = 0
        body.append(DER.integer(modulus))
        body.append(DER.integer(publicExponent))
        body.append(DER.integer(privateExponent))
        body.append(DER.integer(prime1))
        body.append(DER.integer(prime2))
        body.append(DER.integer(exponent1))
        body.append(DER.integer(exponent2))
        body.append(DER.integer(coefficient))
        try self.init(pkcs1DER: DER.sequence(body), signatureAlgorithm: signatureAlgorithm)
    }

    /// PI-IOS 补丁：用 OpenSSH `ssh-rsa` 私钥里的字段顺序构造（n, e, d, iqmp, p, q）。
    ///
    /// OpenSSH 不存 `d mod (p-1)` 与 `d mod (q-1)`，但 PKCS#1 `RSAPrivateKey` 需要它们，
    /// 这里用 `NIOSSHBigUInt` 现算。
    public init(
        openSSHModulus modulus: Data,
        publicExponent: Data,
        privateExponent: Data,
        coefficient: Data,
        prime1: Data,
        prime2: Data,
        signatureAlgorithm: NIOSSHRSASignatureAlgorithm = .sha256
    ) throws {
        let d = NIOSSHBigUInt(privateExponent)
        let p = NIOSSHBigUInt(prime1)
        let q = NIOSSHBigUInt(prime2)
        let one = NIOSSHBigUInt(Data([1]))
        guard p.compare(to: one) > 0, q.compare(to: one) > 0 else {
            throw NIOSSHError.invalidRSAKey(reason: "RSA 素数必须大于 1")
        }
        let exponent1 = NIOSSHBigUInt.modulus(d, p.subtractingOne())
        let exponent2 = NIOSSHBigUInt.modulus(d, q.subtractingOne())
        try self.init(
            modulus: modulus,
            publicExponent: publicExponent,
            privateExponent: privateExponent,
            prime1: prime1,
            prime2: prime2,
            exponent1: exponent1.bigEndianBytes,
            exponent2: exponent2.bigEndianBytes,
            coefficient: coefficient,
            signatureAlgorithm: signatureAlgorithm
        )
    }

    /// 对 `message` 做 PKCS#1 v1.5 签名（哈希函数由 `signatureAlgorithm` 决定）。
    public func signature(for message: Data) throws -> Data {
        try NIOSSHRSACrypto.sign(
            privateKeyDER: self.pkcs1DER,
            message: message,
            algorithm: self.signatureAlgorithm
        )
    }
}

// MARK: - 最小 DER 编解码

enum DER {
    static func length(_ count: Int) -> Data {
        if count < 0x80 {
            return Data([UInt8(count)])
        }
        var bytes: [UInt8] = []
        var remaining = count
        while remaining > 0 {
            bytes.insert(UInt8(remaining & 0xFF), at: 0)
            remaining >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }

    static func sequence(_ body: Data) -> Data {
        Data([0x30]) + length(body.count) + body
    }

    static func integer(_ raw: Data) -> Data {
        var content = Data(raw.drop { $0 == 0 })
        if content.isEmpty { content = Data([0]) }
        if content[content.startIndex] & 0x80 != 0 {
            content = Data([0]) + content
        }
        return Data([0x02]) + length(content.count) + content
    }

    /// 顺序读取 DER 里的 INTEGER 内容（不做符号扩展，直接给原字节）。
    struct IntegerReader {
        private let data: Data
        private var offset: Int

        init(_ data: Data) {
            self.data = data
            self.offset = 0
        }

        mutating func readSequenceHeader() -> Bool {
            guard offset < data.count, data[offset] == 0x30 else { return false }
            offset += 1
            guard readLength() != nil else { return false }
            return true
        }

        mutating func readInteger() -> Data? {
            guard offset < data.count, data[offset] == 0x02 else { return nil }
            offset += 1
            guard let length = readLength(), length <= data.count - offset else { return nil }
            let value = Data(data[offset..<(offset + length)])
            offset += length
            return value
        }

        private mutating func readLength() -> Int? {
            guard offset < data.count else { return nil }
            let first = data[offset]
            offset += 1
            if first < 0x80 { return Int(first) }
            let byteCount = Int(first & 0x7F)
            guard byteCount > 0, offset + byteCount <= data.count else { return nil }
            var value = 0
            for _ in 0..<byteCount {
                let byte = Int(data[offset])
                guard value <= (Int.max - byte) / 256 else { return nil }
                value = value * 256 + byte
                offset += 1
            }
            return value
        }
    }

    /// PKCS#1 RSAPrivateKey 的字段（顺序固定）。
    struct RSAPrivateKeyComponents {
        var version: Data
        var modulus: Data
        var publicExponent: Data
        var privateExponent: Data
        var prime1: Data
        var prime2: Data
        var exponent1: Data
        var exponent2: Data
        var coefficient: Data

        init(pkcs1DER: Data) throws {
            var reader = DER.IntegerReader(pkcs1DER)
            guard reader.readSequenceHeader() else {
                throw NIOSSHError.invalidRSAKey(reason: "缺少 SEQUENCE 头")
            }
            guard let version = reader.readInteger(),
                  let modulus = reader.readInteger(),
                  let publicExponent = reader.readInteger(),
                  let privateExponent = reader.readInteger(),
                  let prime1 = reader.readInteger(),
                  let prime2 = reader.readInteger(),
                  let exponent1 = reader.readInteger(),
                  let exponent2 = reader.readInteger(),
                  let coefficient = reader.readInteger()
            else {
                throw NIOSSHError.invalidRSAKey(reason: "PKCS#1 RSAPrivateKey 字段不完整")
            }
            self.version = version
            self.modulus = modulus
            self.publicExponent = publicExponent
            self.privateExponent = privateExponent
            self.prime1 = prime1
            self.prime2 = prime2
            self.exponent1 = exponent1
            self.exponent2 = exponent2
            self.coefficient = coefficient
        }
    }
}

// MARK: - 签名 / 验签（Security 框架）

enum NIOSSHRSACrypto {
    static func verify(
        publicKeyDER: Data,
        signature: Data,
        message: Data,
        algorithm: NIOSSHRSASignatureAlgorithm
    ) -> Bool {
        #if canImport(Security)
        guard let key = secKey(der: publicKeyDER, isPrivate: false) else { return false }
        return SecKeyVerifySignature(
            key,
            secAlgorithm(algorithm),
            message as CFData,
            signature as CFData,
            nil
        )
        #else
        return false
        #endif
    }

    static func sign(
        privateKeyDER: Data,
        message: Data,
        algorithm: NIOSSHRSASignatureAlgorithm
    ) throws -> Data {
        #if canImport(Security)
        guard let key = secKey(der: privateKeyDER, isPrivate: true) else {
            throw NIOSSHError.invalidRSAKey(reason: "Security 无法从 PKCS#1 DER 构造 RSA 私钥")
        }
        var error: Unmanaged<CFError>?
        guard
            let signature = SecKeyCreateSignature(
                key,
                secAlgorithm(algorithm),
                message as CFData,
                &error
            )
        else {
            let detail = error.map { String(describing: $0.takeRetainedValue()) } ?? "未知原因"
            throw NIOSSHError.invalidRSAKey(reason: "RSA 签名失败：\(detail)")
        }
        return signature as Data
        #else
        throw NIOSSHError.invalidRSAKey(reason: "当前平台没有 Security 框架，无法做 RSA 签名")
        #endif
    }

    #if canImport(Security)
    private static func secKey(der: Data, isPrivate: Bool) -> SecKey? {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: isPrivate ? kSecAttrKeyClassPrivate : kSecAttrKeyClassPublic,
        ]
        return SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil)
    }

    private static func secAlgorithm(_ algorithm: NIOSSHRSASignatureAlgorithm) -> SecKeyAlgorithm {
        switch algorithm {
        case .sha256: return .rsaSignatureMessagePKCS1v15SHA256
        case .sha512: return .rsaSignatureMessagePKCS1v15SHA512
        }
    }
    #endif
}
