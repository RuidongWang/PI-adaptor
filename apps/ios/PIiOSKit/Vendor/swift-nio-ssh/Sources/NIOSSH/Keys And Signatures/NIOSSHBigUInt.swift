//===----------------------------------------------------------------------===//
//
// 本文件是 PI-IOS 对 apple/swift-nio-ssh 的本地补丁（Apache-2.0）。
//
// 只为一件小事：OpenSSH 的 `ssh-rsa` 私钥不保存 `d mod (p-1)` / `d mod (q-1)`，
// 而 Security 框架的 `SecKeyCreateWithData` 需要完整的 PKCS#1 `RSAPrivateKey`。
// 所以这里提供一个够用的最小大整数（比较、减一、二进制长除法取模）。
// 参数规模是 RSA 2048/3072/4096 位，只在导入私钥时算一次，性能不是问题。
//
//===----------------------------------------------------------------------===//

import Foundation

struct NIOSSHBigUInt: Sendable, Hashable {
    /// 小端 32 位 limb（`limbs[0]` 是最低 32 位）。
    private var limbs: [UInt32]

    init(_ bytes: Data) {
        var limbs: [UInt32] = []
        var accumulator: UInt32 = 0
        var shift = 0
        for byte in bytes.reversed() {
            accumulator |= UInt32(byte) << UInt32(shift)
            shift += 8
            if shift == 32 {
                limbs.append(accumulator)
                accumulator = 0
                shift = 0
            }
        }
        if shift > 0 {
            limbs.append(accumulator)
        }
        self.limbs = NIOSSHBigUInt.trim(limbs)
    }

    private init(limbs: [UInt32]) {
        self.limbs = NIOSSHBigUInt.trim(limbs)
    }

    var isZero: Bool { self.limbs.isEmpty }

    /// 大端字节（最少字节数，不含多余前导零；零返回一个 0 字节）。
    var bigEndianBytes: Data {
        guard !self.isZero else { return Data([0]) }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(self.limbs.count * 4)
        for limb in self.limbs.reversed() {
            bytes.append(UInt8(truncatingIfNeeded: limb >> 24))
            bytes.append(UInt8(truncatingIfNeeded: limb >> 16))
            bytes.append(UInt8(truncatingIfNeeded: limb >> 8))
            bytes.append(UInt8(truncatingIfNeeded: limb))
        }
        while bytes.count > 1, bytes[0] == 0 { bytes.removeFirst() }
        return Data(bytes)
    }

    func subtractingOne() -> NIOSSHBigUInt {
        var limbs = self.limbs
        var index = 0
        while index < limbs.count {
            if limbs[index] > 0 {
                limbs[index] -= 1
                break
            }
            limbs[index] = UInt32.max
            index += 1
        }
        return NIOSSHBigUInt(limbs: limbs)
    }

    /// - Returns: -1 / 0 / 1
    func compare(to other: NIOSSHBigUInt) -> Int {
        if self.limbs.count != other.limbs.count {
            return self.limbs.count < other.limbs.count ? -1 : 1
        }
        var index = self.limbs.count - 1
        while index >= 0 {
            if self.limbs[index] != other.limbs[index] {
                return self.limbs[index] < other.limbs[index] ? -1 : 1
            }
            index -= 1
        }
        return 0
    }

    /// 二进制长除法取模：逐位把被除数移进余数，余数够大就减一次模数。
    static func modulus(_ dividend: NIOSSHBigUInt, _ divisor: NIOSSHBigUInt) -> NIOSSHBigUInt {
        precondition(!divisor.isZero, "模数不能为零")
        var remainder = NIOSSHBigUInt(limbs: [])
        let bitCount = dividend.limbs.count * 32
        var bit = bitCount - 1
        while bit >= 0 {
            remainder = remainder.shiftedLeftOneInserting(
                UInt32((dividend.limbs[bit / 32] >> UInt32(bit % 32)) & 1)
            )
            if remainder.compare(to: divisor) >= 0 {
                remainder = remainder.subtracting(divisor)
            }
            bit -= 1
        }
        return remainder
    }

    private func shiftedLeftOneInserting(_ lowBit: UInt32) -> NIOSSHBigUInt {
        var limbs = self.limbs
        var carry = lowBit
        var index = 0
        while index < limbs.count {
            let nextCarry = limbs[index] >> 31
            limbs[index] = (limbs[index] << 1) | carry
            carry = nextCarry
            index += 1
        }
        if carry != 0 { limbs.append(carry) }
        return NIOSSHBigUInt(limbs: limbs)
    }

    private func subtracting(_ other: NIOSSHBigUInt) -> NIOSSHBigUInt {
        // 调用方保证 self >= other。
        var limbs = self.limbs
        var borrow: Int64 = 0
        for index in 0..<limbs.count {
            let subtrahend = index < other.limbs.count ? Int64(other.limbs[index]) : 0
            var value = Int64(limbs[index]) - subtrahend - borrow
            if value < 0 {
                value += 1 << 32
                borrow = 1
            } else {
                borrow = 0
            }
            limbs[index] = UInt32(truncatingIfNeeded: value)
        }
        return NIOSSHBigUInt(limbs: limbs)
    }

    private static func trim(_ limbs: [UInt32]) -> [UInt32] {
        var limbs = limbs
        while let last = limbs.last, last == 0 { limbs.removeLast() }
        return limbs
    }
}
