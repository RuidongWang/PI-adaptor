import XCTest
import NIOSSH

@testable import PIiOSNet

/// RSA 用户密钥 / 主机密钥（spec E6 + AC-02 系列）在 NIOSSH 层的可用性验证。
///
/// 这些用例直接打 PI-IOS 对 swift-nio-ssh 的 RSA 补丁（`Vendor/swift-nio-ssh`）：
/// 上游 0.15.1 既没有 RSA 私钥签名，也没有 rsa-sha2-* 主机密钥，所以必须有测试盯着。
final class RSAKeyTests: XCTestCase {
    func testRSAPrivateKeySignsAndVerifiesOnSHA256() throws {
        let privateKey = try makePrivateKey(fixture: "rsa2048_none")
        let message = Data("pi-ios-userauth-payload".utf8)
        let signature = try privateKey.signature(for: message)

        XCTAssertTrue(
            privateKey.publicKey.isValidSignature(signature, forMessage: message, algorithm: .sha256)
        )
        // 内容被改过必须验签失败。
        XCTAssertFalse(
            privateKey.publicKey.isValidSignature(
                signature,
                forMessage: message + Data([0x00]),
                algorithm: .sha256
            )
        )
    }

    func testRSASignatureOnSHA512AndAlgorithmMismatchFails() throws {
        let privateKey = try makePrivateKey(fixture: "rsa2048_none", algorithm: .sha512)
        let message = Data("rsa-sha2-512".utf8)
        let signature = try privateKey.signature(for: message)

        XCTAssertTrue(
            privateKey.publicKey.isValidSignature(signature, forMessage: message, algorithm: .sha512)
        )
        // 把算法换成 sha256 必须验签失败（防止算法标识与签名内容不一致被放过）。
        XCTAssertFalse(
            privateKey.publicKey.isValidSignature(signature, forMessage: message, algorithm: .sha256)
        )
    }

    func testRSAPublicKeyMatchesOpenSSHPublicKeyLine() throws {
        for fixture in ["rsa2048_none", "rsa3072_none"] {
            let privateKey = try makePrivateKey(fixture: fixture)
            let publicKey = NIOSSHPrivateKey(rsaKey: privateKey).publicKey
            XCTAssertEqual(
                String(openSSHPublicKey: publicKey),
                try SSHFixture.publicKeyLine(fixture),
                "\(fixture) 的公钥线必须与 ssh-keygen 写出的 .pub 一致"
            )
        }
    }

    func testRSAPublicKeyRoundTripsThroughNIOSSHOpenSSHString() throws {
        let line = try SSHFixture.publicKeyLine("rsa3072_none")
        let publicKey = try NIOSSHPublicKey(openSSHPublicKey: line)
        XCTAssertEqual(String(openSSHPublicKey: publicKey), line)
    }

    func testRSAKeySizeIsReportedFromModulus() throws {
        XCTAssertEqual(try makePrivateKey(fixture: "rsa2048_none").publicKey.keySize, 2048)
        XCTAssertEqual(try makePrivateKey(fixture: "rsa3072_none").publicKey.keySize, 3072)
    }

    func testInvalidPrimeAndOversizedDERLengthAreRejected() throws {
        let fields = try RSAFields(openSSHPrivateKey: SSHFixture.text("rsa2048_none.key"))
        for invalid in [Data(), Data([0]), Data([1])] {
            XCTAssertThrowsError(try NIOSSHRSAPrivateKey(
                openSSHModulus: fields.modulus, publicExponent: fields.publicExponent,
                privateExponent: fields.privateExponent, coefficient: fields.coefficient,
                prime1: invalid, prime2: fields.prime2
            ))
            XCTAssertThrowsError(try NIOSSHRSAPrivateKey(
                openSSHModulus: fields.modulus, publicExponent: fields.publicExponent,
                privateExponent: fields.privateExponent, coefficient: fields.coefficient,
                prime1: fields.prime1, prime2: invalid
            ))
        }
        let badLength = Data([0x30, 0x01, 0x02, 0x88] + Array(repeating: 0xff, count: 8))
        XCTAssertThrowsError(try NIOSSHRSAPrivateKey(pkcs1DER: badLength))
    }

    /// 主机密钥路径：握手拿到的 RSA 公钥 blob 能解析、且 SHA256 指纹口径与 `ssh-keygen -lf` 一致。
    func testRSAHostKeyBlobParsesAndFingerprintMatchesSSHKeyGen() throws {
        let line = try SSHFixture.publicKeyLine("rsa2048_none")
        let hostKey = try SSHHostKey(openSSHPublicKey: line)
        // `ssh-keygen -lf rsa2048_none.key.pub` 的输出。
        XCTAssertEqual(hostKey.fingerprint, "SHA256:0ZmiwQo4Yhj6eq1DD4D0HWcrzYl1usSZ4Q4l6hVqOhc")
        XCTAssertEqual(hostKey.algorithm, "ssh-rsa")

        // 解析后重新序列化必须逐字节还原（握手时用同一份 blob 生成指纹与比较固定记录）。
        let reparsed = try NIOSSHPublicKey(openSSHPublicKey: line)
        XCTAssertEqual(String(openSSHPublicKey: reparsed), line)
    }

    // MARK: 辅助

    /// 用 fixture 的 RSA 字段构造 `NIOSSHRSAPrivateKey`（与生产解析器走同一个 init）。
    private func makePrivateKey(
        fixture: String,
        algorithm: NIOSSHRSASignatureAlgorithm = .sha256
    ) throws -> NIOSSHRSAPrivateKey {
        let fields = try RSAFields(openSSHPrivateKey: try SSHFixture.text("\(fixture).key"))
        return try NIOSSHRSAPrivateKey(
            openSSHModulus: fields.modulus,
            publicExponent: fields.publicExponent,
            privateExponent: fields.privateExponent,
            coefficient: fields.coefficient,
            prime1: fields.prime1,
            prime2: fields.prime2,
            signatureAlgorithm: algorithm
        )
    }
}

/// 从**未加密**的 `openssh-key-v1` 文本里取出 RSA 的 6 个整数字段。
/// 顺序按 OpenSSH 的 `ssh-rsa` 布局：n, e, d, iqmp, p, q。
struct RSAFields {
    var modulus: Data
    var publicExponent: Data
    var privateExponent: Data
    var coefficient: Data
    var prime1: Data
    var prime2: Data

    init(openSSHPrivateKey text: String) throws {
        let base64 = text
            .split(separator: "\n")
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard let data = Data(base64Encoded: base64) else { throw Failure.badFixture }
        var reader = SSHBinaryReaderForTests(data)
        guard reader.readBytes(15) == Data("openssh-key-v1\u{0}".utf8) else { throw Failure.badFixture }
        _ = reader.readString()  // cipher
        _ = reader.readString()  // kdf
        _ = reader.readString()  // kdf options
        guard reader.readUInt32() == 1 else { throw Failure.badFixture }
        _ = reader.readString()  // public key blob
        guard let privateSection = reader.readString() else { throw Failure.badFixture }

        var priv = SSHBinaryReaderForTests(privateSection)
        _ = priv.readUInt32()  // checkint 1
        _ = priv.readUInt32()  // checkint 2
        guard priv.readString() == Data("ssh-rsa".utf8) else { throw Failure.notRSA }
        guard let modulus = priv.readString(),
              let publicExponent = priv.readString(),
              let privateExponent = priv.readString(),
              let coefficient = priv.readString(),
              let prime1 = priv.readString(),
              let prime2 = priv.readString()
        else { throw Failure.badFixture }
        self.modulus = modulus
        self.publicExponent = publicExponent
        self.privateExponent = privateExponent
        self.coefficient = coefficient
        self.prime1 = prime1
        self.prime2 = prime2
    }

    enum Failure: Error { case badFixture, notRSA }
}

/// 与生产 `SSHBinaryReader` 独立的一份读取器（避免测试与实现同源导致断言失真）。
struct SSHBinaryReaderForTests {
    private let data: Data
    private var offset = 0

    init(_ data: Data) { self.data = data }

    mutating func readBytes(_ count: Int) -> Data? {
        guard offset + count <= data.count else { return nil }
        defer { offset += count }
        return Data(data[offset..<(offset + count)])
    }

    mutating func readUInt32() -> UInt32? {
        guard let bytes = readBytes(4) else { return nil }
        return bytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }

    mutating func readString() -> Data? {
        guard let length = readUInt32() else { return nil }
        return readBytes(Int(length))
    }
}
