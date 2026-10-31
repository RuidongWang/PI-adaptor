# swift-nio-ssh 本地分支（PI-IOS 补丁说明）

## 来源与许可

- 上游：`https://github.com/apple/swift-nio-ssh`，版本 **0.15.1**
  （`Package.resolved` 里的 revision：`d1985926494b624e751b379009dc83f3395fd88a`）
- 许可证：**Apache-2.0**，见同目录 `LICENSE.txt`；上游版权声明与文件头原样保留。
- 本目录只 vendor 了 `Sources/NIOSSH` 这一个 target；上游的示例可执行文件（`NIOSSHClient` /
  `NIOSSHServer` / `NIOSSHPerformanceTester`）与测试未 vendor。
- 依赖仍走 SPM 远程拉取：`swift-nio`、`swift-crypto`、`swift-atomics`。

## 为什么 fork（而不是在库外补齐）

spec E6 要求用户私钥支持 **RSA**，且服务器主机密钥接受 **`rsa-sha2-256/512`**。上游 0.15.1：

- 整个源码树里没有 `ssh-rsa` / `rsa-sha2-*` 任何字样（`grep -ri rsa Sources/NIOSSH` 为空）；
- `NIOSSHPrivateKey` 只有 ed25519 / P-256 / P-384 / P-521 / SecureEnclave 五个 init，
  `NIOSSHPublicKey.BackingKey`、`NIOSSHSignature.BackingSignature` 都是 **internal** 枚举；
- `SSHKeyExchangeStateMachine.supportedServerHostKeyAlgorithms` 是写死的静态表，客户端无法注入；
- 没有任何 delegate / hook 能替换密钥或签名类型（`NIOSSHClientUserAuthenticationDelegate`
  只能选择「密码」或「`NIOSSHPrivateKey`」，而后者无法构造 RSA）。

因此「在库外补齐 RSA userauth」在 API 层面不可行，只能 fork。补丁刻意做得最小：
**只加 RSA**，ed25519 / ECDSA 路径一行未改。

## 补丁清单（相对上游 0.15.1）

| 文件 | 改动 |
|---|---|
| `Keys And Signatures/NIOSSHRSAPublicKey.swift` | **新增**。`NIOSSHRSAPublicKey`（n/e）、`NIOSSHRSAPrivateKey`（PKCS#1 DER）、`NIOSSHRSASignatureAlgorithm`（`rsa-sha2-256` / `rsa-sha2-512`）、最小 DER 编解码、签名/验签（委托 Security 框架 `SecKey`） |
| `Keys And Signatures/NIOSSHBigUInt.swift` | **新增**。只在导入 RSA 私钥时用：OpenSSH 不存 `d mod (p-1)` / `d mod (q-1)`，PKCS#1 需要，故现算（二进制长除法） |
| `Keys And Signatures/NIOSSHPublicKey.swift` | `BackingKey` 加 `.rsa`；`keyPrefix` / `knownAlgorithms` / `Equatable` / `Hashable` / 三处 `isValidSignature` / `writeSSHHostKey` / `writePublicKeyWithoutPrefix` / `readPublicKeyWithoutPrefixForIdentifier` 全部处理 RSA；新增 `userAuthAlgorithmName`（userauth 报文里写 `rsa-sha2-*`）与 `matchesHostKeyAlgorithm`（协商名 `rsa-sha2-*` 对应公钥 blob 前缀 `ssh-rsa`） |
| `Keys And Signatures/NIOSSHPrivateKey.swift` | `BackingKey` 加 `.rsa`；新增 `init(rsaKey:)`；`hostKeyAlgorithms` / `sign(digest:)` / `sign(payload:)` / `publicKey` 处理 RSA |
| `Keys And Signatures/NIOSSHSignature.swift` | `BackingSignature` 加 `.rsa(algorithm:signature:)`；`writeSSHSignature` / `readSSHSignature` / `Equatable` / `Hashable` 处理 RSA |
| `User Authentication/UserAuthSignablePayload.swift` | 签名载荷里的「公钥算法名」用 `userAuthAlgorithmName`（RFC 8332：RSA 在这里写 `rsa-sha2-*`） |
| `SSHMessages.swift` | `writeUserAuthRequestMessage` / `writeUserAuthPKOKMessage` 同样用 `userAuthAlgorithmName` |
| `Key Exchange/SSHKeyExchangeStateMachine.swift` | 客户端 host key 算法表追加 `rsa-sha2-512`、`rsa-sha2-256`（**不**宣告 `ssh-rsa`/SHA-1）；握手期用 `matchesHostKeyAlgorithm` 代替裸前缀比较 |
| `Keys And Signatures/NIOSSHCertifiedPublicKey.swift` | 证书层显式 `preconditionFailure`：本分支不支持 RSA 证书（`rsa-sha2-*-cert-v01@openssh.com`） |
| `NIOSSHError.swift` | 新增错误类型 `invalidRSAKey` |

## 已知限制

1. **不支持 RSA 证书**（`*-cert-v01@openssh.com`）：证书认证不在 E6 范围内，遇到会明确失败而不是猜。
2. **不宣告 `ssh-rsa`（SHA-1）主机密钥算法**：按安全策略拒绝；只支持 `ssh-rsa` 的老服务器会握手失败，
   由 `SSHTransport.mapHandshakeError` 翻译成带修复建议的错误（见 `PIiOSNet/SSHTransport.swift`）。
3. RSA 签名/验签依赖 **Security 框架**（`#if canImport(Security)`）；Apple 平台之外不可用。
   本项目只构建 iOS / macOS，未做其它平台适配。
4. 服务器角色（NIOSSH 的 `.server`）未针对 RSA 做过验证：本 App 只用客户端角色。

## 重新同步上游的做法

```bash
# 在临时目录取上游同版本源码，与本目录 Sources/NIOSSH 做 diff 即可看到全部补丁
git clone --depth 1 --branch 0.15.1 https://github.com/apple/swift-nio-ssh /tmp/nio-ssh
diff -ru /tmp/nio-ssh/Sources/NIOSSH \
  apps/ios/PIiOSKit/Vendor/swift-nio-ssh/Sources/NIOSSH
```

## 验证

- `swift test`（`apps/ios/PIiOSKit`）：`PIiOSNetTests.RSAKeyTests` 用 `ssh-keygen` 生成的
  RSA 2048/3072 私钥跑通「解析 → PKCS#1 → 签名 → 验签」「公钥线逐字节还原」「主机密钥指纹与
  `ssh-keygen -lf` 一致」。
- `xcodebuild -sdk iphonesimulator` 与 `-sdk iphoneos` 均构建通过。
