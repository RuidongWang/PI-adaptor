import Foundation
import PIiOSCore

/// 离线缓存的 SQLite 落盘（契约 §6 C-4、AC-14.5、AC-15.1）。
///
/// 文件 `Application Support/PIiOS/session-cache.sqlite` 保存 sessions、items、cursors、
/// approvals 与 drafts。旧版 `session-cache-v1.json` 在首次读取时一次性迁移到 SQLite；
/// 迁移成功后才删除旧文件。保留策略仍统一使用 PIiOSCore 的 `CacheRetention`
///（每会话 200、最多 20 个 Host+会话）。
struct SessionCacheStore {
    /// 一条缓存条目（对应契约 §6 `items` 表的关键列子集）。
    typealias Entry = OfflineSessionCacheEntry
    typealias Snapshot = OfflineSessionCacheSnapshot
    typealias Cursor = OfflineSessionCursor
    typealias Approval = OfflineSessionApproval
    typealias Draft = OfflineSessionDraft
    typealias Session = OfflineSessionCacheSession
    typealias WriteLease = OfflineSessionCacheWriteLease

    private let fileURL: URL?
    /// 设置里的上限；每次写入都按它裁剪。
    private var offlineCacheLimit: Int
    private var memory: MemorySnapshot?

    private final class MemorySnapshot {
        var snapshot: Snapshot

        init(_ snapshot: Snapshot) { self.snapshot = snapshot }
    }

    init(offlineCacheLimit: Int, fileURL: URL? = SessionCacheStore.defaultURL()) {
        self.offlineCacheLimit = offlineCacheLimit
        self.fileURL = fileURL
    }

    /// UI fixtures use the same pruning and Host partitioning without touching disk.
    init(offlineCacheLimit: Int, inMemory snapshot: Snapshot) {
        self.offlineCacheLimit = offlineCacheLimit
        fileURL = nil
        memory = MemorySnapshot(snapshot)
    }

    func withOfflineCacheLimit(_ limit: Int) -> Self {
        var store = self
        store.offlineCacheLimit = limit
        return store
    }

    static func defaultURL() -> URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        let directory = base.appendingPathComponent("PIiOS", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("session-cache.sqlite")
    }

    static func legacyJSONURL(for fileURL: URL) -> URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("session-cache-v1.json")
    }

    /// Pending writes must survive history-cache eviction and snapshot rebuilds.
    static func defaultRequestKeyURL() -> URL? {
        defaultURL()?.deletingLastPathComponent().appendingPathComponent("request-keys-v1.json")
    }

    /// 载入完整 schema 并裁剪；旧版文件缺失的表自动按空数组补齐。
    func loadSnapshot() -> Snapshot {
        // Display may fall back to empty; save independently refuses to overwrite a bad file.
        (try? loadSnapshotChecked()) ?? Snapshot()
    }

    func loadSnapshotChecked() throws -> Snapshot {
        if let memory { return prune(memory.snapshot) }
        guard let fileURL else { throw CocoaError(.fileReadUnknown) }
        if fileURL.pathExtension.lowercased() == "json" {
            guard let document = try OfflineSessionCacheFile.load(from: fileURL) else { return Snapshot() }
            return prune(document.snapshot)
        }
        let legacyURL = Self.legacyJSONURL(for: fileURL)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            return prune(
                try OfflineSessionCacheSQLite.migrateLegacyJSON(
                    from: legacyURL,
                    to: fileURL
                )
            )
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return Snapshot() }
        return prune(try OfflineSessionCacheSQLite(url: fileURL).loadSnapshot())
    }

    /// 兼容现有只关心 items 的调用点。
    func load() -> [Entry] {
        loadSnapshot().entries
    }

    /// 兼容旧调用点：只裁剪 items。
    func prune(_ entries: [Entry]) -> [Entry] {
        OfflineSessionCachePolicy.prunedEntries(entries, offlineCacheLimit: offlineCacheLimit)
    }

    func prune(_ snapshot: Snapshot) -> Snapshot {
        OfflineSessionCachePolicy.prunedSnapshot(
            snapshot,
            offlineCacheLimit: offlineCacheLimit
        )
    }

    /// 写入完整快照并应用设置里的保留上限。
    ///
    /// 文件属性按 AC-15.3：`NSFileProtectionCompleteUnlessOpen`（或更强）+ 不参与 iCloud 备份。
    /// 缓存只放会话内容与幂等键，不含任何凭证（`CacheFieldPolicy` 兜名称级约束）。
    @discardableResult
    func save(_ snapshot: Snapshot) -> Result<Void, Error> {
        Result {
            if let memory {
                memory.snapshot = prune(snapshot)
                return
            }
            guard let fileURL else { throw CocoaError(.fileWriteUnknown) }
            let pruned = prune(snapshot)
            if fileURL.pathExtension.lowercased() == "json" {
                try OfflineSessionCacheFile.save(
                    OfflineSessionCacheDocument(snapshot: pruned),
                    to: fileURL
                )
                return
            }
            let database = try OfflineSessionCacheSQLite(url: fileURL)
            // A corrupt existing database must never be replaced silently.
            if FileManager.default.fileExists(atPath: fileURL.path) {
                _ = try database.loadSnapshot()
            }
            try database.save(pruned)
            try? FileManager.default.removeItem(at: Self.legacyJSONURL(for: fileURL))
        }
    }

    /// 只替换 items 的兼容写入口，其他表保持不变。
    func save(entries: [Entry]) {
        var snapshot = loadSnapshot()
        snapshot.entries = entries
        save(snapshot)
    }

    /// 当前生效的条数上限（设置值与契约默认值的归一结果）。
    var itemLimit: Int {
        CacheRetention.itemsPerSessionLimit(offlineCacheLimit: offlineCacheLimit)
    }

    func removeHost(_ hostID: UUID) {
        var snapshot = loadSnapshot()
        snapshot.removeHost(hostID)
        save(snapshot)
    }
}
