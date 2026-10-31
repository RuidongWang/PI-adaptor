// swift-tools-version:6.1
//===----------------------------------------------------------------------===//
//
// 这是 apple/swift-nio-ssh 0.15.1 的**本地 vendored 分支**（Apache-2.0，见 LICENSE.txt）。
//
// 为什么 vendored：上游 0.15.1 完全没有 RSA 支持（源码里没有 "ssh-rsa" / "rsa-sha2-*" 任何字样），
// `NIOSSHPrivateKey` 只有 ed25519 / ECDSA 四个 init，且没有任何对外扩展点可以注入新的密钥或签名
// 类型——`NIOSSHPublicKey.BackingKey`、`NIOSSHSignature.BackingSignature` 全是 internal 枚举。
// 因此"在库外补齐 RSA userauth"在 API 层面不可行，只能 fork（见 PATCHES.md）。
//
// 补丁范围见 PATCHES.md，只加 RSA（主机密钥 rsa-sha2-256/512 + 用户密钥 rsa-sha2-256/512），
// 不改动 ed25519 / ECDSA 的任何行为。上游其余 target（示例可执行文件、测试）未 vendor。
//
//===----------------------------------------------------------------------===//

import PackageDescription

var swiftSettings: [SwiftSetting] = []

let package = Package(
    name: "swift-nio-ssh",
    platforms: [
        .macOS(.v10_15),
        .iOS(.v13),
        .watchOS(.v6),
        .tvOS(.v13),
    ],
    products: [
        .library(name: "NIOSSH", targets: ["NIOSSH"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "1.0.0"..<"6.0.0"),
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.0.2"),
    ],
    targets: [
        .target(
            name: "NIOSSH",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Atomics", package: "swift-atomics"),
            ],
            swiftSettings: swiftSettings
        )
    ]
)

// ---    STANDARD CROSS-REPO SETTINGS DO NOT EDIT   --- //
for target in package.targets {
    switch target.type {
    case .regular, .test, .executable:
        var settings = target.swiftSettings ?? []
        // https://github.com/swiftlang/swift-evolution/blob/main/proposals/0444-member-import-visibility.md
        settings.append(.enableUpcomingFeature("MemberImportVisibility"))
        target.swiftSettings = settings
    case .macro, .plugin, .system, .binary:
        ()  // not applicable
    @unknown default:
        ()  // we don't know what to do here, do nothing
    }
}
// --- END: STANDARD CROSS-REPO SETTINGS DO NOT EDIT --- //
