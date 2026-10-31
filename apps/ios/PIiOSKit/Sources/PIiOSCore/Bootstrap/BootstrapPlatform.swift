import Foundation

// MARK: - 架构与产物（契约 §5.2、spec AC-01.5 / AC-01.6 / AC-01.3）

/// 客户端按 `uname -m` 选择的发布产物（spec E1 / D-13）。
public enum BootstrapArtifactTarget: String, Equatable, Hashable, Sendable, CaseIterable {
    case linuxX64 = "linux-x64"
    case linuxArm64 = "linux-arm64"

    /// `uname -m` 的等价输出（AC-01.5）。
    public var unameMachineAliases: [String] {
        switch self {
        case .linuxX64: return ["x86_64", "amd64"]
        case .linuxArm64: return ["aarch64", "arm64"]
        }
    }

    public var architectureLabel: String {
        switch self {
        case .linuxX64: return "x86_64"
        case .linuxArm64: return "arm64"
        }
    }
}

/// 平台探测结论：支持则给出产物目标，不支持则给出可展示原因（**不下载任何 tarball**）。
public enum BootstrapPlatformDecision: Equatable, Sendable {
    case supported(BootstrapArtifactTarget)
    case unsupported(reason: BootstrapUnsupportedReason)

    public var target: BootstrapArtifactTarget? {
        if case let .supported(target) = self { return target }
        return nil
    }

    /// 只有受支持平台才允许下载（AC-01.3 / AC-01.6）。
    public var shouldDownload: Bool { target != nil }

    public var failureCode: BootstrapFailureCode? {
        if case let .unsupported(reason) = self { return reason.code }
        return nil
    }
}

/// 平台不受支持的原因。失败码固定是客户端侧的 `platform-unsupported`（契约 §5.2）。
public struct BootstrapUnsupportedReason: Equatable, Sendable {
    public let code: BootstrapFailureCode
    public let message: String

    public init(code: BootstrapFailureCode = .platformUnsupported, message: String) {
        self.code = code
        self.message = message
    }
}

public enum BootstrapPlatformProbe {
    /// 只支持 Linux（spec AC-01.3：macOS 明确提示「当前仅支持 Linux」）。
    public static let supportedPlatform = "linux"

    public static func decide(unameSystem: String, unameMachine: String) -> BootstrapPlatformDecision {
        let system = unameSystem.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !system.isEmpty else {
            return .unsupported(
                reason: BootstrapUnsupportedReason(message: "无法探测服务器平台（uname -s 为空），未下载任何文件")
            )
        }
        guard system == supportedPlatform else {
            let shown = unameSystem.trimmingCharacters(in: .whitespacesAndNewlines)
            return .unsupported(
                reason: BootstrapUnsupportedReason(
                    message: "当前仅支持 Linux，检测到的平台是「\(shown)」，不会下载或安装任何文件"
                )
            )
        }

        let machine = unameMachine.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let target = target(forUnameMachine: machine) else {
            let shown = unameMachine.trimmingCharacters(in: .whitespacesAndNewlines)
            return .unsupported(
                reason: BootstrapUnsupportedReason(
                    message: "当前仅支持 x86_64 / arm64，检测到的架构是「\(shown)」，不会下载任何 tarball"
                )
            )
        }
        return .supported(target)
    }

    /// `x86_64|amd64 → linux-x64`，`aarch64|arm64 → linux-arm64`，其余 `nil`（AC-01.5 / AC-01.6）。
    public static func target(forUnameMachine machine: String) -> BootstrapArtifactTarget? {
        let value = machine.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return BootstrapArtifactTarget.allCases.first { $0.unameMachineAliases.contains(value) }
    }

    /// 产物名：`pi-host-<ver>-linux-<arch>.tar.gz`（契约 §5.1 示例与 AC-01.5）。
    public static func artifactName(version: String, target: BootstrapArtifactTarget) -> String {
        "pi-host-\(version)-\(target.rawValue).tar.gz"
    }
}
