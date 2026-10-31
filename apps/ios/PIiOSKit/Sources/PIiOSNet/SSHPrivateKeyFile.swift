import UniformTypeIdentifiers
import Foundation

// MARK: - 私钥文件（按文件选择，而不是粘贴文本）

/// 从用户选择的文件里读出的私钥。
public struct SSHPrivateKeyFile: Equatable, Sendable {
    /// 仅用于界面显示的文件名，不含路径（文件名可能含用户名等信息，但不含密钥内容）。
    public let fileName: String
    /// 私钥文本；调用方只能放进 Keychain，不落普通文件、不写日志。
    public let text: String
    public let info: SSHPrivateKeyInfo

    public init(fileName: String, text: String, info: SSHPrivateKeyInfo) {
        self.fileName = fileName
        self.text = text
        self.info = info
    }
}

public enum SSHPrivateKeyFileError: Error, Equatable, CustomStringConvertible {
    /// 读不到（无权限、文件被删、iCloud 未下载、安全作用域失效）。
    case unreadable(String)
    case empty
    /// 选到了文件夹（`.key` 在系统里是 Keynote 的 package 类型，用户也可能选中目录）。
    case directory
    case tooLarge(bytes: Int)
    /// 不是受支持的私钥格式。
    case unsupported(String)

    public var description: String {
        switch self {
        case let .unreadable(detail):
            return "无法读取所选文件：\(detail)。请确认文件已下载到本机（iCloud 云盘里的文件需要先下载），或换一个位置再选一次。"
        case .empty:
            return "所选文件是空的：请选择包含私钥内容的文件（例如 id_ed25519）。"
        case .directory:
            return "所选的是一个文件夹或 App 包，不是私钥文件：请进入文件夹选择里面的私钥文件。"
        case let .tooLarge(bytes):
            return "所选文件 \(bytes) 字节，超过 \(SSHPrivateKeyFileLoader.maxBytes) 字节上限：私钥文件通常只有几 KB，"
                + "选错文件时请不要保存。"
        case let .unsupported(detail):
            return "不是受支持的私钥文件：\(detail)"
        }
    }
}

public enum SSHPrivateKeyFileLoader {
    /// 文件选择器允许的类型。
    ///
    /// **必须是 `public.item`**：它是类型树的根，任何文件（包括系统未声明扩展名的、
    /// 以及像 `.key` 这种被系统判定为 `com.apple.iwork.keynote.sffkey` 的 Keynote 包）都符合它。
    /// 只用 `.data` / `.plainText` 时，某些 system-declared 或 package 类型会被系统选择器置灰，
    /// 表现为「文件在列表里但点不动」——这正是 `.key` 私钥被挡住的原因。
    public static let allowedContentTypes: [UTType] = [.item, .data]

    /// 私钥文件上限：OpenSSH 私钥通常 0.4~6 KB，64 KB 足够容纳带注释的长密钥并挡住误选的大文件。
    public static let maxBytes = 64 * 1024

    /// 从 URL 读取并校验。调用方负责 security-scoped 访问（`startAccessingSecurityScopedResource`）。
    public static func load(contentsOf url: URL) throws -> SSHPrivateKeyFile {
        // 选到文件夹/包时先挡掉：`Data(contentsOf:)` 对目录会给出难懂的 Cocoa 错误。
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            throw SSHPrivateKeyFileError.directory
        }
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw SSHPrivateKeyFileError.unreadable(error.localizedDescription)
        }
        return try load(fileName: url.lastPathComponent, data: data)
    }

    /// 校验已读到的字节：大小、编码、格式、算法。全部失败原因都可直接展示给用户。
    public static func load(fileName: String, data: Data) throws -> SSHPrivateKeyFile {
        if data.isEmpty {
            throw SSHPrivateKeyFileError.empty
        }
        guard data.count <= maxBytes else {
            throw SSHPrivateKeyFileError.tooLarge(bytes: data.count)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw SSHPrivateKeyFileError.unsupported("文件不是 UTF-8 文本，可能选成了二进制文件或图片。")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SSHPrivateKeyFileError.empty
        }
        // PuTTY 私钥是二进制容器，必须显式拒绝并给出转换命令，不能让用户以为选了就能用。
        if trimmed.contains("PuTTY-User-Key-File") {
            throw SSHPrivateKeyFileError.unsupported(
                "这是 PuTTY 的 .ppk 格式，本机不直接支持。先用 ssh-keygen -p -N \"\" -f 你的密钥.ppk 转成 OpenSSH 格式再选。"
            )
        }
        guard trimmed.contains("PRIVATE KEY-----") else {
            throw SSHPrivateKeyFileError.unsupported(
                "文件里没有找到私钥块（`-----BEGIN ... PRIVATE KEY-----`）。注意别选到公钥（.pub）或 known_hosts。"
            )
        }
        do {
            let info = try SSHPrivateKeyParser.info(openSSHPrivateKey: trimmed)
            return SSHPrivateKeyFile(fileName: fileName, text: trimmed, info: info)
        } catch let error as SSHPrivateKeyError {
            throw SSHPrivateKeyFileError.unsupported(error.description)
        } catch {
            throw SSHPrivateKeyFileError.unsupported(error.localizedDescription)
        }
    }
}
