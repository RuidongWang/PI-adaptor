import Foundation

// MARK: - 状态文件（契约 §5.1）

/// `.bootstrap/state.json` 的 `status` 取值（契约 §5.2）。
public enum BootstrapStatus: String, Codable, Equatable, Sendable {
    case running
    case ok
    case failed
}

/// 步骤枚举与严格顺序（契约 §5.2）。
///
/// `unknown` 保留上游出现但本契约未列出的步骤名，不静默丢弃。
public enum BootstrapStep: Equatable, Hashable, Sendable {
    case probe
    case resolve
    case download
    case verify
    case extract
    case activate
    case writeUnit
    case startPair
    case pair
    case stopManual
    case startUnit
    case verifyDevice
    case done
    case unknown(String)

    /// 严格顺序（契约 §5.2 原文顺序）。
    public static let ordered: [BootstrapStep] = [
        .probe, .resolve, .download, .verify, .extract, .activate, .writeUnit,
        .startPair, .pair, .stopManual, .startUnit, .verifyDevice, .done,
    ]

    /// 已安装同版本时可跳过的步骤（契约 §5.2 / §5.3 第 3 条）。
    public static let shortCircuitableSteps: [BootstrapStep] = [.download, .verify, .extract]

    public var rawValue: String {
        switch self {
        case .probe: return "probe"
        case .resolve: return "resolve"
        case .download: return "download"
        case .verify: return "verify"
        case .extract: return "extract"
        case .activate: return "activate"
        case .writeUnit: return "write-unit"
        case .startPair: return "start-pair"
        case .pair: return "pair"
        case .stopManual: return "stop-manual"
        case .startUnit: return "start-unit"
        case .verifyDevice: return "verify-device"
        case .done: return "done"
        case let .unknown(raw): return raw
        }
    }

    public init(raw: String) {
        switch raw {
        case "probe": self = .probe
        case "resolve": self = .resolve
        case "download": self = .download
        case "verify": self = .verify
        case "extract": self = .extract
        case "activate": self = .activate
        case "write-unit": self = .writeUnit
        case "start-pair": self = .startPair
        case "pair": self = .pair
        case "stop-manual": self = .stopManual
        case "start-unit": self = .startUnit
        case "verify-device": self = .verifyDevice
        case "done": self = .done
        default: self = .unknown(raw)
        }
    }

    /// 在严格顺序里的位置；`unknown` 没有位置。
    public var order: Int? {
        BootstrapStep.ordered.firstIndex(of: self)
    }

    public var isKnown: Bool { order != nil }

    public var displayName: String { rawValue }
}

extension BootstrapStep: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(raw: try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension BootstrapStep: CustomStringConvertible {
    public var description: String { rawValue }
}

/// `state.host`（契约 §5.1）。
public struct BootstrapHostInfo: Codable, Equatable, Sendable {
    public var platform: String?
    public var arch: String?

    public init(platform: String? = nil, arch: String? = nil) {
        self.platform = platform
        self.arch = arch
    }
}

/// `state.artifact`（契约 §5.1）。
public struct BootstrapArtifactInfo: Codable, Equatable, Sendable {
    public var name: String?
    public var sha256: String?
    public var bytes: Int?
    public var downloadedBytes: Int?

    public init(name: String? = nil, sha256: String? = nil, bytes: Int? = nil, downloadedBytes: Int? = nil) {
        self.name = name
        self.sha256 = sha256
        self.bytes = bytes
        self.downloadedBytes = downloadedBytes
    }
}

/// `state.service`（契约 §5.1 / §5.3 第 7 条）。
public struct BootstrapServiceInfo: Codable, Equatable, Sendable {
    public var unitPath: String?
    public var state: String?

    public init(unitPath: String? = nil, state: String? = nil) {
        self.unitPath = unitPath
        self.state = state
    }
}

/// `.bootstrap/state.json`（契约 §5.1）。`error` 的形状未冻结，整体保留原始 JSON。
public struct BootstrapStateFile: Equatable, Sendable {
    public var version: Int
    public var attemptId: String
    public var step: BootstrapStep
    public var status: BootstrapStatus
    public var host: BootstrapHostInfo?
    public var artifact: BootstrapArtifactInfo?
    public var service: BootstrapServiceInfo?
    public var error: JSONValue?
    public var updatedAt: String

    public init(
        version: Int = 1,
        attemptId: String,
        step: BootstrapStep,
        status: BootstrapStatus,
        host: BootstrapHostInfo? = nil,
        artifact: BootstrapArtifactInfo? = nil,
        service: BootstrapServiceInfo? = nil,
        error: JSONValue? = nil,
        updatedAt: String = ""
    ) {
        self.version = version
        self.attemptId = attemptId
        self.step = step
        self.status = status
        self.host = host
        self.artifact = artifact
        self.service = service
        self.error = error
        self.updatedAt = updatedAt
    }

    /// `error.code`（也接受 `error` 直接是字符串的形态）；读不到返回 `nil`。
    public var failureCodeRaw: String? {
        guard let error else { return nil }
        if let code = error.value(at: ["code"])?.stringValue { return code }
        if let text = error.stringValue, !text.isEmpty { return text }
        return nil
    }

    /// 失败码。未知取值原样保留在 `.unknown(raw)` 里，不会被吞掉（契约 §5.2）。
    public var failureCode: BootstrapFailureCode? {
        failureCodeRaw.map(BootstrapFailureCode.init(raw:))
    }

    /// Optional structured diagnostics added by the PI-adaptor installer.
    /// Unknown keys stay untouched in `error`; these fields are only a typed
    /// presentation layer.
    public var failureDetails: BootstrapFailureDetails? {
        guard let error else { return nil }
        return BootstrapFailureDetails(error: error)
    }

    /// 三方状态：运行中 / 成功 / 失败（失败必带码，含未知码）。
    public var outcome: BootstrapOutcome {
        switch status {
        case .running:
            return .running
        case .ok:
            return .succeeded
        case .failed:
            return .failed(BootstrapFailureCode(raw: failureCodeRaw ?? ""))
        }
    }

    /// 停滞判定用的进度样本（契约 §5.3 第 2 条只看 `step` 与 `downloadedBytes`）。
    public func progressSample(at date: Date) -> BootstrapProgressSample {
        BootstrapProgressSample(step: step, downloadedBytes: artifact?.downloadedBytes ?? 0, observedAt: date)
    }
}

public struct BootstrapFailureDetails: Equatable, Sendable {
    public struct LegacyUnit: Equatable, Sendable {
        public var unit: String
        public var originalActive: Bool?
        public var originalEnabled: Bool?
        public var portOccupied: Bool?

        public init(
            unit: String,
            originalActive: Bool? = nil,
            originalEnabled: Bool? = nil,
            portOccupied: Bool? = nil
        ) {
            self.unit = unit
            self.originalActive = originalActive
            self.originalEnabled = originalEnabled
            self.portOccupied = portOccupied
        }
    }

    public var reason: String?
    public var phase: String?
    public var expectedName: String?
    public var actualName: String?
    public var expectedVersion: String?
    public var actualVersion: String?
    public var installDirectory: String?
    public var unitName: String?
    public var port: Int?
    public var legacyUnits: [LegacyUnit]

    public init(error: JSONValue) {
        let details = error.value(at: ["details"])
        reason = details?.value(at: ["reason"])?.stringValue
        phase = details?.value(at: ["phase"])?.stringValue
        expectedName = details?.value(at: ["expectedName"])?.stringValue
        actualName = details?.value(at: ["actualName"])?.stringValue
        expectedVersion = details?.value(at: ["expectedVersion"])?.stringValue
        actualVersion = details?.value(at: ["actualVersion"])?.stringValue
        installDirectory = details?.value(at: ["installDirectory"])?.stringValue
        unitName = details?.value(at: ["unitName"])?.stringValue
        port = details?.value(at: ["port"])?.intValue
        legacyUnits = details?.value(at: ["legacyUnits"])?.arrayValue?.compactMap { value in
            guard let unit = value.value(at: ["unit"])?.stringValue,
                  !unit.isEmpty
            else { return nil }
            return LegacyUnit(
                unit: unit,
                originalActive: value.value(at: ["originalActive"])?.boolValue,
                originalEnabled: value.value(at: ["originalEnabled"])?.boolValue,
                portOccupied: value.value(at: ["portOccupied"])?.boolValue
            )
        } ?? []
    }

    public var displayText: String? {
        var lines: [String] = []
        if let phase { lines.append("失败阶段：\(phase)") }
        if let reason { lines.append("原因：\(reason)") }
        if let expectedName, let actualName {
            lines.append("运行名称：期望 \(expectedName)，实际 \(actualName)")
        }
        if let expectedVersion, let actualVersion {
            lines.append("运行版本：期望 \(expectedVersion)，实际 \(actualVersion)")
        }
        if let installDirectory { lines.append("激活目录：\(installDirectory)") }
        if let unitName { lines.append("服务：\(unitName)") }
        if let port { lines.append("端口：\(port)") }
        for legacy in legacyUnits {
            var state: [String] = []
            if let originalActive = legacy.originalActive {
                state.append("原 active=\(originalActive)")
            }
            if let originalEnabled = legacy.originalEnabled {
                state.append("原 enabled=\(originalEnabled)")
            }
            if let portOccupied = legacy.portOccupied {
                state.append("端口冲突=\(portOccupied)")
            }
            let suffix = state.isEmpty ? "" : "（\(state.joined(separator: "，"))）"
            lines.append("Legacy 服务：\(legacy.unit)\(suffix)")
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

extension BootstrapStateFile: Codable {
    private enum CodingKeys: String, CodingKey {
        case version, attemptId, step, status, host, artifact, service, error, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 0
        attemptId = try container.decode(String.self, forKey: .attemptId)
        step = try container.decode(BootstrapStep.self, forKey: .step)
        status = try container.decode(BootstrapStatus.self, forKey: .status)
        host = try container.decodeIfPresent(BootstrapHostInfo.self, forKey: .host)
        artifact = try container.decodeIfPresent(BootstrapArtifactInfo.self, forKey: .artifact)
        service = try container.decodeIfPresent(BootstrapServiceInfo.self, forKey: .service)
        error = try container.decodeIfPresent(JSONValue.self, forKey: .error)
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(attemptId, forKey: .attemptId)
        try container.encode(step, forKey: .step)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(host, forKey: .host)
        try container.encodeIfPresent(artifact, forKey: .artifact)
        try container.encodeIfPresent(service, forKey: .service)
        try container.encodeIfPresent(error, forKey: .error)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}

// MARK: - 终态

public enum BootstrapOutcome: Equatable, Sendable {
    case running
    case succeeded
    /// 失败。未知失败码以 `.unknown(raw)` 保留（契约 §5.2）。
    case failed(BootstrapFailureCode)

    public var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

// MARK: - 失败码（契约 §5.2）

/// 失败码：上游脚本 19 个真实 `die` 码 + 4 个客户端侧码 + 未知码。
public enum BootstrapFailureCode: Equatable, Hashable, Sendable {
    // 上游真实 die 码（19）
    case noHome
    case missingTar
    case missingSha256Tool
    case bootstrapPermissions
    case stageFailed
    case downloadFailed
    case checksumMismatch
    case extractFailed
    case unexpectedArchiveLayout
    case installFailed
    case installedVerificationFailed
    case missingNode
    case nodeTooOld
    case hostStopTimeout
    case hostStartFailed
    case hostExited
    case readyTimeout
    case receiptFailed
    case artifactPermissions
    // 本契约新增的客户端侧码（4）
    case platformUnsupported
    case pairFailed
    case unitFailed
    case verifyDeviceFailed
    // 未知码：原样保留
    case unknown(String)

    public static let upstreamCodes: [BootstrapFailureCode] = [
        .noHome, .missingTar, .missingSha256Tool, .bootstrapPermissions, .stageFailed,
        .downloadFailed, .checksumMismatch, .extractFailed, .unexpectedArchiveLayout,
        .installFailed, .installedVerificationFailed, .missingNode, .nodeTooOld,
        .hostStopTimeout, .hostStartFailed, .hostExited, .readyTimeout, .receiptFailed,
        .artifactPermissions,
    ]

    public static let clientSideCodes: [BootstrapFailureCode] = [
        .platformUnsupported, .pairFailed, .unitFailed, .verifyDeviceFailed,
    ]

    public var rawValue: String {
        switch self {
        case .noHome: return "no-home"
        case .missingTar: return "missing-tar"
        case .missingSha256Tool: return "missing-sha256-tool"
        case .bootstrapPermissions: return "bootstrap-permissions"
        case .stageFailed: return "stage-failed"
        case .downloadFailed: return "download-failed"
        case .checksumMismatch: return "checksum-mismatch"
        case .extractFailed: return "extract-failed"
        case .unexpectedArchiveLayout: return "unexpected-archive-layout"
        case .installFailed: return "install-failed"
        case .installedVerificationFailed: return "installed-verification-failed"
        case .missingNode: return "missing-node"
        case .nodeTooOld: return "node-too-old"
        case .hostStopTimeout: return "host-stop-timeout"
        case .hostStartFailed: return "host-start-failed"
        case .hostExited: return "host-exited"
        case .readyTimeout: return "ready-timeout"
        case .receiptFailed: return "receipt-failed"
        case .artifactPermissions: return "artifact-permissions"
        case .platformUnsupported: return "platform-unsupported"
        case .pairFailed: return "pair-failed"
        case .unitFailed: return "unit-failed"
        case .verifyDeviceFailed: return "verify-device-failed"
        case let .unknown(raw): return raw
        }
    }

    public init(raw: String) {
        switch raw {
        case "no-home": self = .noHome
        case "missing-tar": self = .missingTar
        case "missing-sha256-tool": self = .missingSha256Tool
        case "bootstrap-permissions": self = .bootstrapPermissions
        case "stage-failed": self = .stageFailed
        case "download-failed": self = .downloadFailed
        case "checksum-mismatch": self = .checksumMismatch
        case "extract-failed": self = .extractFailed
        case "unexpected-archive-layout": self = .unexpectedArchiveLayout
        case "install-failed": self = .installFailed
        case "installed-verification-failed": self = .installedVerificationFailed
        case "missing-node": self = .missingNode
        case "node-too-old": self = .nodeTooOld
        case "host-stop-timeout": self = .hostStopTimeout
        case "host-start-failed": self = .hostStartFailed
        case "host-exited": self = .hostExited
        case "ready-timeout": self = .readyTimeout
        case "receipt-failed": self = .receiptFailed
        case "artifact-permissions": self = .artifactPermissions
        case "platform-unsupported": self = .platformUnsupported
        case "pair-failed": self = .pairFailed
        case "unit-failed": self = .unitFailed
        case "verify-device-failed": self = .verifyDeviceFailed
        default: self = .unknown(raw)
        }
    }

    /// 契约 §5.2 新增的四个客户端侧失败码。
    public var isClientSide: Bool {
        BootstrapFailureCode.clientSideCodes.contains(self)
    }

    /// 未知码不能静默丢弃，但一律归类为 `failed`。
    public var isUnknown: Bool {
        if case .unknown = self { return true }
        return false
    }

    /// 中文说明，直接展示在失败页。措辞依据契约 §5.2 与 spec AC-01.2 / 01.3 / 01.9 / 01.10 / 01.11。
    public var displayMessage: String {
        switch self {
        case .noHome:
            return "找不到目标用户的主目录（$HOME），无法写入 .pi-adaptor"
        case .missingTar:
            return "缺少安装包 tarball"
        case .missingSha256Tool:
            return "服务器上没有可用的 sha256 校验工具（sha256sum / shasum）"
        case .bootstrapPermissions:
            return "bootstrap 目录或文件权限不正确（要求目录 0700、状态文件 0600）"
        case .stageFailed:
            return "创建暂存目录失败，未写入任何文件"
        case .downloadFailed:
            return "下载失败：未写入任何文件，current 未改动；已下载分片可校验复用，可重试下载（AC-01.10）"
        case .checksumMismatch:
            return "sha256 校验不匹配：不切换 current，磁盘上不留半安装状态（AC-01.2），可重试下载"
        case .extractFailed:
            return "解包失败"
        case .unexpectedArchiveLayout:
            return "压缩包目录结构与预期不符"
        case .installFailed:
            return "安装 PI-adaptor release 失败"
        case .installedVerificationFailed:
            return "安装后自检失败"
        case .missingNode:
            return "bundle 内缺少 Node 运行时"
        case .nodeTooOld:
            return "Node 版本过低（要求 22.19.0 及以上）"
        case .hostStopTimeout:
            return "停止旧 Host 或 PI-adaptor 服务超时"
        case .hostStartFailed:
            return "启动 PI-adaptor 失败"
        case .hostExited:
            return "PI-adaptor 进程已退出"
        case .readyTimeout:
            return "等待 Host 就绪超时"
        case .receiptFailed:
            return "写入安装回执失败"
        case .artifactPermissions:
            return "安装产物权限不正确"
        case .platformUnsupported:
            return "当前仅支持 Linux x86_64 / arm64，未下载任何文件（AC-01.3 / AC-01.6）"
        case .pairFailed:
            return "配对失败：配对令牌可能已过期，请重启 Host 取新令牌再配对，不复用旧令牌（AC-01.9）"
        case .unitFailed:
            return "pi-adaptor.service 启动失败或旧服务仍占用端口；安装器会回滚 current 与服务状态"
        case .verifyDeviceFailed:
            return "运行身份、完整版本或 ping 校验失败；不会把旧 Host 当作安装成功"
        case let .unknown(raw):
            return raw.isEmpty ? "Host 报告失败但没有给出失败码，请查看 Host 日志" : "未识别的失败码：\(raw)"
        }
    }
}

// MARK: - 状态推进校验

/// 状态推进中的问题。不阻断展示，用于发现脚本回退或重复尝试。
public enum BootstrapTransitionIssue: Equatable, Sendable {
    /// 步骤倒退（严格顺序被违反）。
    case stepRegression(from: BootstrapStep, to: BootstrapStep)
    /// 同一 `attemptId` 下重复推进到了之前的步骤（重新安装必须换 `attemptId`，契约 §5.2）。
    case attemptIdUnchanged(String)
    /// 上游出现了本契约未列出的步骤名（原样保留，但需要提示）。
    case unknownStep(String)

    public var message: String {
        switch self {
        case let .stepRegression(from, to):
            return "步骤从「\(from.rawValue)」回退到「\(to.rawValue)」，违反严格顺序"
        case let .attemptIdUnchanged(attemptId):
            return "重新安装时 attemptId 未变化：\(attemptId)"
        case let .unknownStep(raw):
            return "出现了未定义的步骤名「\(raw)」，已原样保留"
        }
    }
}

public enum BootstrapStateValidator {
    /// 比较前后两份 `state.json`。
    public static func issues(previous: BootstrapStateFile?, current: BootstrapStateFile) -> [BootstrapTransitionIssue] {
        var issues: [BootstrapTransitionIssue] = []
        if case let .unknown(raw) = current.step {
            issues.append(.unknownStep(raw))
        }
        guard let previous else { return issues }

        if let previousOrder = previous.step.order, let currentOrder = current.step.order,
           currentOrder < previousOrder {
            issues.append(.stepRegression(from: previous.step, to: current.step))
            if previous.attemptId == current.attemptId {
                issues.append(.attemptIdUnchanged(current.attemptId))
            }
        }
        return issues
    }
}

// MARK: - 停滞判定（契约 §5.3 第 2 条）

/// 一次进度采样。契约只允许用 `step` 与 `downloadedBytes` 判断进展。
public struct BootstrapProgressSample: Equatable, Sendable {
    public let step: BootstrapStep
    public let downloadedBytes: Int
    public let observedAt: Date

    public init(step: BootstrapStep, downloadedBytes: Int, observedAt: Date) {
        self.step = step
        self.downloadedBytes = downloadedBytes
        self.observedAt = observedAt
    }
}

public enum BootstrapStallStatus: Equatable, Sendable {
    case progressing
    /// 连续 `threshold` 秒 step 与 downloadedBytes 均无变化：提示「可恢复点」并允许重试。
    case stalled(unchangedSince: Date, message: String)
}

/// 停滞检测器：连续 5 分钟 `step` 与 `downloadedBytes` 都没变化即提示可恢复点。
public struct BootstrapStallDetector: Sendable {
    public static let defaultThreshold: TimeInterval = 5 * 60

    public let threshold: TimeInterval
    /// 最近一次「有进展」的采样。
    public private(set) var baseline: BootstrapProgressSample?

    public init(threshold: TimeInterval = BootstrapStallDetector.defaultThreshold) {
        self.threshold = threshold
    }

    @discardableResult
    public mutating func observe(_ sample: BootstrapProgressSample) -> BootstrapStallStatus {
        guard let baseline else {
            self.baseline = sample
            return .progressing
        }
        if sample.step != baseline.step || sample.downloadedBytes != baseline.downloadedBytes {
            self.baseline = sample
            return .progressing
        }
        guard sample.observedAt.timeIntervalSince(baseline.observedAt) >= threshold else {
            return .progressing
        }
        return .stalled(
            unchangedSince: baseline.observedAt,
            message: "连续 \(Int(threshold / 60)) 分钟没有任何进展（步骤与已下载字节数都没变），这是一个可恢复点：可以重试，已下载分片会复用"
        )
    }

    /// 纯函数版本：判断某个「最近一次进展时刻」是否已经停滞。
    public static func stallMessage(
        unchangedSince: Date,
        now: Date,
        threshold: TimeInterval = BootstrapStallDetector.defaultThreshold
    ) -> String? {
        guard now.timeIntervalSince(unchangedSince) >= threshold else { return nil }
        return "连续 \(Int(threshold / 60)) 分钟没有任何进展（步骤与已下载字节数都没变），这是一个可恢复点：可以重试，已下载分片会复用"
    }
}
