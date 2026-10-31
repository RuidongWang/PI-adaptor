import Foundation

/// A directory returned by `project/browse`.
///
/// Upstream's wire shape is `{name, path}` and the operation only returns
/// directories. `isDirectory` is kept because older prototypes also supplied a
/// `type` field; a missing value therefore means "directory", not "file".
public struct ProjectDirectoryEntry: Identifiable, Equatable, Sendable {
    public var name: String
    public var path: String
    public var isDirectory: Bool

    public var id: String { path }

    public init(name: String, path: String, isDirectory: Bool = true) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
    }
}

public enum ProjectDirectoryRules {
    /// Parse the intentionally open `entries[]` shape without inventing fields.
    /// Invalid or path-escaping entries are ignored.
    public static func entries(
        from raw: [JSONValue],
        currentPath: String
    ) -> [ProjectDirectoryEntry] {
        let current = normalizedPath(currentPath)
        guard isValidAbsolutePath(current) else { return [] }

        return raw.compactMap { value in
            guard let rawName = value.value(at: ["name"])?.stringValue,
                  isValidName(rawName)
            else { return nil }

            let path = value.value(at: ["path"])?.stringValue
                ?? childPath(parent: current, name: rawName)
            guard path == childPath(parent: current, name: rawName),
                  isValidAbsolutePath(path)
            else { return nil }

            let isDirectory: Bool
            if let explicit = value.value(at: ["isDirectory"])?.boolValue {
                isDirectory = explicit
            } else if let type = value.value(at: ["type"])?.stringValue {
                isDirectory = type.lowercased() == "directory"
            } else {
                isDirectory = true
            }
            return ProjectDirectoryEntry(name: rawName, path: path, isDirectory: isDirectory)
        }
    }

    public static func parent(of path: String) -> String? {
        let normalized = normalizedPath(path)
        guard normalized != "/" else { return nil }
        guard let slash = normalized.lastIndex(of: "/") else { return nil }
        if slash == normalized.startIndex { return "/" }
        return String(normalized[..<slash])
    }

    public static func defaultProjectName(for path: String) -> String {
        let normalized = normalizedPath(path)
        guard normalized != "/" else { return "root" }
        return normalized.split(separator: "/").last.map(String.init) ?? "root"
    }

    public static func childPath(parent: String, name: String) -> String {
        let normalized = normalizedPath(parent)
        return normalized == "/" ? "/\(name)" : "\(normalized)/\(name)"
    }

    public static func normalizedPath(_ value: String) -> String {
        guard value.count > 1 else { return value }
        var result = value
        while result.count > 1 && result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }

    public static func isValidAbsolutePath(_ value: String) -> Bool {
        value.hasPrefix("/")
            && value.utf8.count <= 4_096
            && !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
    }

    private static func isValidName(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && value.utf8.count <= 4_096
            && !value.contains("/")
            && !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
    }
}

public struct ProjectRegistrationTarget: Equatable, Sendable {
    public var projectId: String
    public var displayName: String
    public var path: String?

    public init(projectId: String, displayName: String, path: String? = nil) {
        self.projectId = projectId
        self.displayName = displayName
        self.path = path
    }
}

/// Tracks whether the project name is still an automatic directory suggestion.
///
/// Navigating the directory browser updates an untouched suggestion, but must
/// never overwrite text the user has edited (including an intentionally empty
/// value that should trigger the required-name validation).
public struct ProjectNameDraft: Equatable, Sendable {
    public private(set) var text: String
    public private(set) var suggestedPath: String?
    public private(set) var isUserEdited: Bool

    public init() {
        text = ""
        suggestedPath = nil
        isUserEdited = false
    }

    public mutating func edit(_ value: String) {
        text = value
        isUserEdited = true
    }

    public mutating func suggestIfNeeded(for path: String) {
        let normalized = ProjectDirectoryRules.normalizedPath(path)
        guard suggestedPath != normalized else { return }
        suggestedPath = normalized
        guard !isUserEdited else { return }
        text = ProjectDirectoryRules.defaultProjectName(for: normalized)
    }
}

public enum ProjectRegistrationIssue: Error, Equatable, Sendable {
    case missingHost
    case notPaired
    case offline
    case missingPath
    case invalidPath
    case emptyName
    case duplicateName
    case catalogUnavailable

    public var message: String {
        switch self {
        case .missingHost:
            return "请先添加一台服务器"
        case .notPaired:
            return "该服务器尚未配对，配对后才能注册项目"
        case .offline:
            return "服务器离线，恢复连接后才能注册项目"
        case .missingPath:
            return "请先选择一个服务器目录"
        case .invalidPath:
            return "目录路径无效，请重新选择"
        case .emptyName:
            return "项目名称不能为空"
        case .duplicateName:
            return "已有同名项目，请换一个名称"
        case .catalogUnavailable:
            return "项目列表尚未加载完成，请返回后重试"
        }
    }
}

public enum ProjectRegistrationRules {
    public static func normalizedName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A known path may be registered again and keeps its existing name target;
    /// two different paths may not share a display name on the same host.
    public static func validate(
        name: String,
        path: String,
        existing: [ProjectRegistrationTarget],
        allowUnresolvedNameConflicts: Bool = false
    ) -> ProjectRegistrationIssue? {
        guard !path.isEmpty else { return .missingPath }
        guard ProjectDirectoryRules.isValidAbsolutePath(path) else { return .invalidPath }
        let requestedName = normalizedName(name)
        guard !requestedName.isEmpty else { return .emptyName }

        let currentPath = ProjectDirectoryRules.normalizedPath(path)
        for target in existing {
            let targetPath = target.path.map(ProjectDirectoryRules.normalizedPath)
            if targetPath == currentPath { continue }
            if normalizedName(target.displayName) == requestedName {
                if allowUnresolvedNameConflicts, target.path == nil { continue }
                return .duplicateName
            }
        }
        return nil
    }

    public static func hasUnresolvedNameConflict(
        name: String,
        existing: [ProjectRegistrationTarget]
    ) -> Bool {
        let requestedName = normalizedName(name)
        guard !requestedName.isEmpty else { return false }
        return existing.contains { target in
            guard target.path == nil else { return false }
            return normalizedName(target.displayName) == requestedName
        }
    }

    /// Keeps local project names unique when an idempotent registration returns
    /// a different project than the caller's unverified name suggested.
    public static func uniqueName(
        base: String,
        existing: [ProjectRegistrationTarget]
    ) -> String {
        let root = normalizedName(base)
        guard !root.isEmpty else { return root }
        let names = Set(existing.map { normalizedName($0.displayName) })
        guard names.contains(root) else { return root }
        var suffix = 2
        var candidate = "\(root) (\(suffix))"
        while names.contains(candidate) {
            suffix += 1
            candidate = "\(root) (\(suffix))"
        }
        return candidate
    }
}
