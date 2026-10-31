import Foundation
import CryptoKit

/// Blowfish 的最小实现，只为 `bcrypt_pbkdf` 服务。
///
/// 依据：Blowfish 算法规范（Schneier）+ OpenBSD `bcrypt_pbkdf(3)`。
/// 这里只实现密钥调度与 8 字节分组加密——`bcrypt_pbkdf` 只用到这两件事。
/// 表值见 `BlowfishConstants.swift`（圆周率 π 的十六进制小数位，即算法规范常数）。
///
/// 注意：密钥调度里刻意用「读旧值 → 返回新表」而不是 `inout` 传自身的 S 盒，
/// 否则 `self.s0` 的写访问与 `encryptBlock` 对 `self.s0` 的读访问会撞上 Swift 的独占性检查。
struct Blowfish {
    private var p: [UInt32]
    private var s0: [UInt32]
    private var s1: [UInt32]
    private var s2: [UInt32]
    private var s3: [UInt32]

    init() {
        p = BlowfishConstants.p
        s0 = BlowfishConstants.s0
        s1 = BlowfishConstants.s1
        s2 = BlowfishConstants.s2
        s3 = BlowfishConstants.s3
    }

    /// 标准密钥调度（salt 为空）。`key` 长度任意，按环形方式取用。
    mutating func expandKey(_ key: [UInt8]) {
        var j = 0
        for i in 0..<18 {
            p[i] ^= Self.nextWord(key, &j)
        }
        var l: UInt32 = 0
        var r: UInt32 = 0
        for i in stride(from: 0, to: 18, by: 2) {
            (l, r) = encryptBlock(l: l, r: r)
            p[i] = l
            p[i + 1] = r
        }
        expandBox(0, &l, &r)
        expandBox(1, &l, &r)
        expandBox(2, &l, &r)
        expandBox(3, &l, &r)
    }

    /// 带 salt 的密钥调度（bcrypt 用）。
    mutating func expandKeyWithSalt(_ key: [UInt8], salt: [UInt8]) {
        var j = 0
        for i in 0..<18 {
            p[i] ^= Self.nextWord(key, &j)
        }
        j = 0
        var l: UInt32 = 0
        var r: UInt32 = 0
        for i in stride(from: 0, to: 18, by: 2) {
            l ^= Self.nextWord(salt, &j)
            r ^= Self.nextWord(salt, &j)
            (l, r) = encryptBlock(l: l, r: r)
            p[i] = l
            p[i + 1] = r
        }
        expandBoxWithSalt(0, &l, &r, salt, &j)
        expandBoxWithSalt(1, &l, &r, salt, &j)
        expandBoxWithSalt(2, &l, &r, salt, &j)
        expandBoxWithSalt(3, &l, &r, salt, &j)
    }

    /// 加密一个 8 字节分组（原地）。字节按大端解释，与 Blowfish 规范一致。
    func encrypt(_ block: inout [UInt8]) {
        precondition(block.count == 8)
        var l = UInt32(block[0]) << 24 | UInt32(block[1]) << 16 | UInt32(block[2]) << 8 | UInt32(block[3])
        var r = UInt32(block[4]) << 24 | UInt32(block[5]) << 16 | UInt32(block[6]) << 8 | UInt32(block[7])
        (l, r) = encryptBlock(l: l, r: r)
        block[0] = UInt8(truncatingIfNeeded: l >> 24)
        block[1] = UInt8(truncatingIfNeeded: l >> 16)
        block[2] = UInt8(truncatingIfNeeded: l >> 8)
        block[3] = UInt8(truncatingIfNeeded: l)
        block[4] = UInt8(truncatingIfNeeded: r >> 24)
        block[5] = UInt8(truncatingIfNeeded: r >> 16)
        block[6] = UInt8(truncatingIfNeeded: r >> 8)
        block[7] = UInt8(truncatingIfNeeded: r)
    }

    // MARK: 内部

    private func f(_ x: UInt32) -> UInt32 {
        let a = s0[Int((x >> 24) & 0xFF)]
        let b = s1[Int((x >> 16) & 0xFF)]
        let c = s2[Int((x >> 8) & 0xFF)]
        let d = s3[Int(x & 0xFF)]
        return ((a &+ b) ^ c) &+ d
    }

    private func encryptBlock(l: UInt32, r: UInt32) -> (UInt32, UInt32) {
        var xl = l
        var xr = r
        xl ^= p[0]
        for i in stride(from: 1, to: 16, by: 2) {
            xr ^= f(xl) ^ p[i]
            xl ^= f(xr) ^ p[i + 1]
        }
        xr ^= p[17]
        return (xr, xl)
    }

    /// 原地展开第 `index` 个 S 盒（与 OpenBSD/Go 实现一致：边算边写，
    /// 后续轮次读到的就是已经写进去的值）。
    private mutating func expandBox(_ index: Int, _ l: inout UInt32, _ r: inout UInt32) {
        for i in stride(from: 0, to: 256, by: 2) {
            (l, r) = encryptBlock(l: l, r: r)
            storeSBox(index, at: i, l)
            storeSBox(index, at: i + 1, r)
        }
    }

    private mutating func expandBoxWithSalt(
        _ index: Int,
        _ l: inout UInt32,
        _ r: inout UInt32,
        _ salt: [UInt8],
        _ j: inout Int
    ) {
        for i in stride(from: 0, to: 256, by: 2) {
            l ^= Self.nextWord(salt, &j)
            r ^= Self.nextWord(salt, &j)
            (l, r) = encryptBlock(l: l, r: r)
            storeSBox(index, at: i, l)
            storeSBox(index, at: i + 1, r)
        }
    }

    private mutating func storeSBox(_ index: Int, at offset: Int, _ value: UInt32) {
        switch index {
        case 0: s0[offset] = value
        case 1: s1[offset] = value
        case 2: s2[offset] = value
        default: s3[offset] = value
        }
    }

    /// 从 `bytes` 里按大端取 4 字节，游标环形推进（与 OpenBSD/Go 实现一致）。
    private static func nextWord(_ bytes: [UInt8], _ position: inout Int) -> UInt32 {
        var word: UInt32 = 0
        var index = position
        for _ in 0..<4 {
            word = word << 8 | UInt32(bytes[index])
            index += 1
            if index >= bytes.count { index = 0 }
        }
        position = index
        return word
    }
}

// MARK: - bcrypt_pbkdf

/// OpenBSD `bcrypt_pbkdf`：OpenSSH 私钥（`openssh-key-v1`）用它对口令派生解密密钥。
///
/// 与 OpenBSD 实现逐参数一致：`SHA512` 预处理口令、每块 32 字节、`bcrypt_hash` 内部
/// 用带 salt 的 Blowfish 调度并做 64 轮密钥重排。
enum BCryptPBKDF {
    enum Failure: Error, Equatable {
        case emptyPassphrase
        case emptySalt
        case invalidRounds
        case keyTooLong
    }

    static func derive(
        passphrase: String,
        salt: Data,
        rounds: Int,
        keyLength: Int
    ) throws -> Data {
        try derive(
            passphrase: Data(passphrase.utf8),
            salt: salt,
            rounds: rounds,
            keyLength: keyLength
        )
    }

    static func derive(
        passphrase: Data,
        salt: Data,
        rounds: Int,
        keyLength: Int
    ) throws -> Data {
        guard !passphrase.isEmpty else { throw Failure.emptyPassphrase }
        guard !salt.isEmpty, salt.count <= 1 << 20 else { throw Failure.emptySalt }
        guard rounds >= 1 else { throw Failure.invalidRounds }
        guard keyLength > 0, keyLength <= 1024 else { throw Failure.keyTooLong }

        let blockSize = 32
        let blockCount = (keyLength + blockSize - 1) / blockSize
        var key = [UInt8](repeating: 0, count: blockCount * blockSize)

        let shaPass = [UInt8](SHA512.hash(data: passphrase))
        var countBytes = [UInt8](repeating: 0, count: 4)

        for block in 1...blockCount {
            var sha = SHA512()
            sha.update(data: salt)
            countBytes[0] = UInt8(truncatingIfNeeded: block >> 24)
            countBytes[1] = UInt8(truncatingIfNeeded: block >> 16)
            countBytes[2] = UInt8(truncatingIfNeeded: block >> 8)
            countBytes[3] = UInt8(truncatingIfNeeded: block)
            sha.update(data: Data(countBytes))
            let shaSalt = [UInt8](sha.finalize())

            // 注意：每一轮参与哈希的是**上一轮的 bcrypt_hash 输出**，不是累积值——
            // 这是 OpenBSD 参考实现的行为（累积值只用于最后的 XOR 折叠）。
            var previous = bcryptHash(shaPass: shaPass, shaSalt: shaSalt)
            var mixed = previous
            if rounds > 1 {
                for _ in 2...rounds {
                    var round = SHA512()
                    round.update(data: Data(previous))
                    let roundSalt = [UInt8](round.finalize())
                    previous = bcryptHash(shaPass: shaPass, shaSalt: roundSalt)
                    for index in 0..<mixed.count {
                        mixed[index] ^= previous[index]
                    }
                }
            }

            // OpenBSD 的块交织：第 block 块的输出散列到 key[i * blockCount + (block-1)]。
            for (index, value) in mixed.enumerated() {
                key[index * blockCount + (block - 1)] = value
            }
        }

        return Data(key.prefix(keyLength))
    }

    private static func bcryptHash(shaPass: [UInt8], shaSalt: [UInt8]) -> [UInt8] {
        var cipher = Blowfish()
        cipher.expandKeyWithSalt(shaPass, salt: shaSalt)
        for _ in 0..<64 {
            cipher.expandKey(shaSalt)
            cipher.expandKey(shaPass)
        }
        var out = Array("OxychromaticBlowfishSwatDynamite".utf8)
        for offset in stride(from: 0, to: 32, by: 8) {
            var block = Array(out[offset..<(offset + 8)])
            for _ in 0..<64 {
                cipher.encrypt(&block)
            }
            out.replaceSubrange(offset..<(offset + 8), with: block)
        }
        // 与 OpenSSH 的实现对齐：把每个 4 字节组按小端翻转。
        for offset in stride(from: 0, to: 32, by: 4) {
            out.swapAt(offset, offset + 3)
            out.swapAt(offset + 1, offset + 2)
        }
        return out
    }
}

