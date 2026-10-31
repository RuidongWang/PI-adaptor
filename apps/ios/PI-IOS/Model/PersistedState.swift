import Foundation

/// 认证方式：密码或 OpenSSH 私钥（spec E6）。
enum AuthKind: String, Codable, CaseIterable, Identifiable {
    case password
    case privateKey = "private_key"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .password: return "密码"
        case .privateKey: return "私钥"
        }
    }
}

/// Non-secret marker for the last successful bootstrap. The authoritative
/// download/install receipt remains on the server; this local copy only avoids
/// presenting an unknown state after relaunch.
struct HostInstallReceipt: Codable, Equatable, Hashable {
    var version: String
    var hostPort: Int
    var attemptId: String
    var completedAt: Date
}

/// 一台服务器的**本机记录**。
///
/// 凭证（密码 / 私钥）不在此结构中，也不写入 `state-v1.json`：
/// 本增量未接入 Keychain，因此不持久化凭证（见 spec §6 安全与 AC-18.4）。
struct HostRecord: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var host: String
    var port: Int
    var username: String
    var authKind: AuthKind
    var createdAt: Date
    var isCurrent: Bool
    /// 本机与 Host 完成 RACP 配对的时间；设备令牌本身只存 Keychain。
    var pairedAt: Date?
    /// 上一次隧道建立成功的时间；`nil` 表示本机没成功连过。
    var tunnelUpAt: Date?
    /// Host 在服务器回环上的 RACP 端口（`direct-tcpip` 目标端口）。
    /// 属于客户端本地配置：契约只冻结 `127.0.0.1:<port>` 与路径，没有固定端口值。
    var hostPort: Int?
    /// 上次选择的私钥**文件名**（仅用于界面回显；私钥内容只在 Keychain，不进本文件）。
    var keyFileName: String?
    /// 最近一次 bootstrap 成功回执（不含配对令牌或设备令牌）。
    var installReceipt: HostInstallReceipt? = nil

    var address: String { "\(username)@\(host):\(port)" }

    /// 配对状态由本机记录中的 `pairedAt` 派生。
    var pairingText: String { pairedAt == nil ? "未配对" : "已配对" }

    /// 连接状态由 `ConnectionModel` 实时给出，这里不缓存「在线」，避免离线时看起来是连着的。
    var statusText: String { pairingText }
}

/// 单个会话的阅读位置。条目用 RACP item id 记录，避免消息数变化后落到错误位置。
struct ConversationReadingPosition: Codable, Equatable {
    var lastVisibleItemID: String?
    var isNearBottom: Bool
}

/// 落盘的本机状态（`Application Support/PIiOS/state-v1.json`）。
struct PersistedState: Codable, Equatable {
    /// 单会话离线缓存上限的默认值（AC-15.1 / spec §9.1）。
    static let defaultOfflineCacheLimit = 200
    /// 允许选择的上限（spec §9.1「设置中可调」）。
    static let offlineCacheLimitOptions = [100, 200, 500, 1000]
    /// 单设备最多缓存的会话数（spec §9.1）。
    static let maxCachedConversations = 20

    var version: Int
    var hosts: [HostRecord]
    var offlineCacheLimit: Int
    /// Non-secret local records used to build the model picker. API keys remain
    /// on the pi-host after import.
    var modelProviders: [StoredModelProvider]
    /// 上次打开的会话与项目：切换 host 或重启后用来恢复上下文（AC-18.6）。
    var lastSessionId: String?
    var lastProjectId: String?
    /// Local names and selected paths keyed by a project id.
    var projectBindings: [StoredProjectBinding]
    var sessionBindings: [StoredSessionBinding]
    /// Per-host navigation context. Keys are host UUID strings.
    var lastSessionByHost: [String: String]
    var lastProjectByHost: [String: String]
    var collapsedProjectGroups: [String]
    /// Last browsed directory per host, keyed by the host UUID string.
    var projectBrowserPaths: [String: String]
    /// 会话阅读位置：第一层是 host UUID，第二层是 session id。
    var readingPositionsByHost: [String: [String: ConversationReadingPosition]]

    static let empty = PersistedState()

    init(
        version: Int = 1,
        hosts: [HostRecord] = [],
        offlineCacheLimit: Int = PersistedState.defaultOfflineCacheLimit,
        modelProviders: [StoredModelProvider] = [],
        lastSessionId: String? = nil,
        lastProjectId: String? = nil,
        projectBindings: [StoredProjectBinding] = [],
        sessionBindings: [StoredSessionBinding] = [],
        lastSessionByHost: [String: String] = [:],
        lastProjectByHost: [String: String] = [:],
        collapsedProjectGroups: [String] = [],
        projectBrowserPaths: [String: String] = [:],
        readingPositionsByHost: [String: [String: ConversationReadingPosition]] = [:]
    ) {
        self.version = version
        self.hosts = hosts
        self.offlineCacheLimit = PersistedState.clampOfflineCacheLimit(offlineCacheLimit)
        self.modelProviders = modelProviders
        self.lastSessionId = lastSessionId
        self.lastProjectId = lastProjectId
        self.projectBindings = projectBindings
        self.sessionBindings = sessionBindings
        self.lastSessionByHost = lastSessionByHost
        self.lastProjectByHost = lastProjectByHost
        self.collapsedProjectGroups = collapsedProjectGroups
        self.projectBrowserPaths = projectBrowserPaths
        self.readingPositionsByHost = readingPositionsByHost
    }

    enum CodingKeys: String, CodingKey {
        case version
        case hosts
        case offlineCacheLimit
        case modelProviders
        case lastSessionId
        case lastProjectId
        case projectBindings
        case sessionBindings
        case lastSessionByHost
        case lastProjectByHost
        case collapsedProjectGroups
        case projectBrowserPaths
        case readingPositionsByHost
    }

    /// 容错解码：缺字段时使用默认值，避免旧文件或手改文件导致整体读取失败。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        hosts = try container.decodeIfPresent([HostRecord].self, forKey: .hosts) ?? []
        let limit = try container.decodeIfPresent(Int.self, forKey: .offlineCacheLimit)
            ?? PersistedState.defaultOfflineCacheLimit
        offlineCacheLimit = PersistedState.clampOfflineCacheLimit(limit)
        modelProviders = try container.decodeIfPresent([StoredModelProvider].self, forKey: .modelProviders) ?? []
        lastSessionId = try container.decodeIfPresent(String.self, forKey: .lastSessionId)
        lastProjectId = try container.decodeIfPresent(String.self, forKey: .lastProjectId)
        projectBindings = try container.decodeIfPresent(
            [StoredProjectBinding].self,
            forKey: .projectBindings
        ) ?? []
        sessionBindings = try container.decodeIfPresent(
            [StoredSessionBinding].self,
            forKey: .sessionBindings
        ) ?? []
        lastSessionByHost = try container.decodeIfPresent(
            [String: String].self,
            forKey: .lastSessionByHost
        ) ?? [:]
        lastProjectByHost = try container.decodeIfPresent(
            [String: String].self,
            forKey: .lastProjectByHost
        ) ?? [:]
        collapsedProjectGroups = try container.decodeIfPresent(
            [String].self,
            forKey: .collapsedProjectGroups
        ) ?? []
        projectBrowserPaths = try container.decodeIfPresent(
            [String: String].self,
            forKey: .projectBrowserPaths
        ) ?? [:]
        readingPositionsByHost = try container.decodeIfPresent(
            [String: [String: ConversationReadingPosition]].self,
            forKey: .readingPositionsByHost
        ) ?? [:]
    }

    static func clampOfflineCacheLimit(_ value: Int) -> Int {
        let lower = 20
        let upper = 5000
        return min(max(value, lower), upper)
    }
}
