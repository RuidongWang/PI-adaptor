import Foundation

/// 本机状态文件的读写。
///
/// 位置：`Application Support/PIiOS/state-v1.json`
/// 保护等级：写入使用 `.completeFileProtection`（锁屏后不可读）。
/// 不含凭证：密码 / 私钥 / API Key 都不写入本文件。
enum StateFile {
    static let directoryName = "PIiOS"
    static let fileName = "state-v1.json"

    struct LoadOutcome {
        var state: PersistedState
        /// 读取异常时给界面显示的原因（成功或文件不存在时为 nil）。
        var warning: String?
        /// 原文件未能安全备份时，禁止以空状态覆盖它。
        var canSave: Bool = true
    }

    enum StateFileError: LocalizedError {
        case applicationSupportUnavailable

        var errorDescription: String? {
            switch self {
            case .applicationSupportUnavailable:
                return "无法定位 Application Support 目录"
            }
        }
    }

    static func directoryURL() throws -> URL {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw StateFileError.applicationSupportUnavailable
        }
        return base.appendingPathComponent(directoryName, isDirectory: true)
    }

    static func fileURL() throws -> URL {
        try directoryURL().appendingPathComponent(fileName, isDirectory: false)
    }

    static func load() -> LoadOutcome {
        let url: URL
        do {
            url = try fileURL()
        } catch {
            return LoadOutcome(state: .empty, warning: "读取本机设置失败：\(error.localizedDescription)", canSave: false)
        }
        return load(from: url)
    }

    static func load(from url: URL) -> LoadOutcome {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain,
               nsError.code == NSFileReadNoSuchFileError {
                return LoadOutcome(state: .empty, warning: nil)
            }
            return LoadOutcome(state: .empty, warning: "读取本机设置失败：\(error.localizedDescription)。原文件已保留，请重启应用重试。", canSave: false)
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let state = try decoder.decode(PersistedState.self, from: data)
            return LoadOutcome(state: state, warning: nil)
        } catch {
            // 解析失败不直接覆盖：先把原文件改名备份，再以空数据启动，并如实告知备份文件名。
            let backupName = renameToCorruptBackup(url: url)
            let backupText = backupName.map { "已备份为 \($0)" } ?? "备份失败，原文件保留在原处"
            let warning = "本机状态文件无法解析（\(error.localizedDescription)）。\(backupText)，当前以空数据启动。"
            return LoadOutcome(state: .empty, warning: warning, canSave: backupName != nil)
        }
    }

    static func save(_ state: PersistedState) throws {
        let directory = try directoryURL()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete]
            )
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: try fileURL(), options: [.atomic, .completeFileProtection])
    }

    private static func renameToCorruptBackup(url: URL) -> String? {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backup = url.deletingLastPathComponent()
            .appendingPathComponent("state-v1.corrupt-\(stamp).json", isDirectory: false)
        do {
            try FileManager.default.moveItem(at: url, to: backup)
            return backup.lastPathComponent
        } catch {
            return nil
        }
    }
}
