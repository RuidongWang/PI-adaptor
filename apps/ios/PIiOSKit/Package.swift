// swift-tools-version: 5.9
// 测试计数说明（别被汇总行骗了）：本包有两个测试 target，`swift test` 会各起一个 xctest 进程。
// 末尾那行 `Test Suite 'All tests' ... Executed N tests` 只统计**最后一个 bundle**（SwiftPM 的已知
// 汇总行为，不是用例没被发现）。真实总数 = 两个 `PIiOSNetTests.xctest` / `PIiOSCoreTests.xctest`
// 各自 `Executed` 行之和：
//   swift test 2>&1 | grep -E "Test Suite 'PIiOS(Net|Core)Tests.xctest' passed" -A1
// 需要单跑某一侧时用 `swift test --filter PIiOSNetTests`（或 `--filter PIiOSCoreTests`）。
//
import PackageDescription

// PIiOSCore 是不含 UI 与网络的纯领域层：RACP 报文、端点策略、provider-import 载荷、
// 模型分组派生视图、会话视图归约、bootstrap 状态机、离线缓存保留策略。
// 依据：docs/api/ios-client.md（FROZEN）与 docs/specs/ios-client.md。
// 放在 SPM 包里是为了能在 macOS 上用 `swift test` 直接跑契约级单测，不必启动模拟器。
//
// PIiOSNet 是传输层：SSH（NIOSSH）+ WebSocket over direct-tcpip + RACP 客户端
// （请求-响应关联、事件分发、退避重连）。放在同一包里、单独 target，
// 是为了让「不依赖系统 ssh」的约束可检查（见 docs/api/ios-client.md §2.1），
// 同时保持 PIiOSCore 的纯领域约束不被网络代码污染。
//
// SSH 底座改用本地 vendored 的 swift-nio-ssh 分支（`Vendor/swift-nio-ssh`，Apache-2.0）：
// 上游 0.15.1 没有任何 RSA 支持，也没有可注入新密钥/签名类型的扩展点，
// 因此按「fork 上游 + 只加 RSA」的方式补齐 E6 的密钥矩阵。补丁清单见该目录下的 PATCHES.md。
let package = Package(
    name: "PIiOSKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "PIiOSCore", targets: ["PIiOSCore"]),
        .library(name: "PIiOSNet", targets: ["PIiOSNet"]),
    ],
    dependencies: [
        // 本地 vendored 的 swift-nio-ssh 分支：上游 0.15.1 + RSA（RSA 用户密钥 / rsa-sha2-* 主机密钥）。
        .package(path: "Vendor/swift-nio-ssh"),
        // NIOSSH 的运行期依赖；直接引用是为了拿 NIOCore / NIOPosix / NIOHTTP1 / NIOWebSocket。
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
    ],
    targets: [
        .target(
            name: "PIiOSCore",
            resources: [.process("Resources")],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "PIiOSNet",
            dependencies: [
                "PIiOSCore",
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
            ]
        ),
        .testTarget(
            name: "PIiOSCoreTests",
            dependencies: ["PIiOSCore"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // 私钥 fixture 由 ssh-keygen 临时生成后放入 Fixtures/（不是真实密钥），见该目录 README。
        .testTarget(
            name: "PIiOSNetTests",
            dependencies: ["PIiOSNet"],
            resources: [.process("Fixtures")]
        ),
    ]
)
