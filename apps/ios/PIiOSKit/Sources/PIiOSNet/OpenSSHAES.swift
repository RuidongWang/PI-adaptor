import Foundation
import CommonCrypto

/// OpenSSH 私钥容器用到的对称解密（`openssh-key-v1` 的 encrypted 段）。
///
/// OpenSSH 用到的 cipher 都是 AES 的 CTR / CBC 模式：CTR 的密钥流按 16 字节分组、
/// 计数器是整个 128 位块的大端自增（与 OpenSSH `cipher.c` 一致），所以这里用
/// AES-ECB 自行拼 CTR，避免依赖 CommonCrypto 的 CTR 选项细节；CBC 直接用 CommonCrypto。
enum OpenSSHAES {
    enum Failure: Error, Equatable {
        case unsupportedKeyLength(Int)
        case cryptFailed(Int32)
        case invalidIV
    }

    /// AES-CTR 加/解密（对称，同一函数两个方向）。
    static func ctr(_ input: Data, key: Data, iv: Data) throws -> Data {
        guard key.count == 16 || key.count == 24 || key.count == 32 else {
            throw Failure.unsupportedKeyLength(key.count)
        }
        guard iv.count == 16 else { throw Failure.invalidIV }
        guard !input.isEmpty else { return Data() }

        var counter = [UInt8](iv)
        var output = Data(capacity: input.count)
        var offset = 0
        while offset < input.count {
            let keystream = try ecbBlock(key: key, block: Data(counter))
            let chunk = min(16, input.count - offset)
            var block = Data(capacity: chunk)
            for index in 0..<chunk {
                block.append(input[input.startIndex + offset + index] ^ keystream[keystream.startIndex + index])
            }
            output.append(block)
            offset += chunk

            // 128 位大端自增
            var carry = true
            var index = 15
            while carry && index >= 0 {
                counter[index] = counter[index] &+ 1
                carry = counter[index] == 0
                index -= 1
            }
        }
        return output
    }

    /// AES-CBC 解密（OpenSSH 的 `aes*-cbc`，无 padding——明文段自带校验位与对齐）。
    static func cbcDecrypt(_ input: Data, key: Data, iv: Data) throws -> Data {
        guard key.count == 16 || key.count == 24 || key.count == 32 else {
            throw Failure.unsupportedKeyLength(key.count)
        }
        guard iv.count == 16 else { throw Failure.invalidIV }
        guard !input.isEmpty else { return Data() }

        var output = Data(count: input.count + kCCBlockSizeAES128)
        var moved = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            input.withUnsafeBytes { inputBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(0),  // 无 padding
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            inputBytes.baseAddress,
                            input.count,
                            outputBytes.baseAddress,
                            outputBytes.count,
                            &moved
                        )
                    }
                }
            }
        }
        guard status == CCCryptorStatus(kCCSuccess) else { throw Failure.cryptFailed(status) }
        output.removeSubrange(moved..<output.count)
        return output
    }

    /// 用 AES-ECB 加密单个 16 字节分组（CTR 的密钥流来源）。
    private static func ecbBlock(key: Data, block: Data) throws -> Data {
        precondition(block.count == 16)
        var output = Data(count: 16 + kCCBlockSizeAES128)
        var moved = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            block.withUnsafeBytes { blockBytes in
                key.withUnsafeBytes { keyBytes in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode),
                        keyBytes.baseAddress,
                        key.count,
                        nil,
                        blockBytes.baseAddress,
                        16,
                        outputBytes.baseAddress,
                        outputBytes.count,
                        &moved
                    )
                }
            }
        }
        guard status == CCCryptorStatus(kCCSuccess), moved == 16 else {
            throw Failure.cryptFailed(status)
        }
        output.removeSubrange(16..<output.count)
        return output
    }
}
