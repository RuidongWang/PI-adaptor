import Foundation
import PIiOSNet

extension String {
    /// 去掉首尾空白与换行：所有表单字段在校验与保存前统一处理。
    var piTrimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// 服务器表单的编辑态数据。`secret`（密码或私钥）只存在于内存，不参与落盘。
struct HostDraft: Equatable {
    var name: String = ""
    var host: String = ""
    var port: String = "22"
    var username: String = ""
    var authKind: AuthKind = .password
    var secret: String = ""
    /// 私钥口令（仅 `authKind == .privateKey` 时有意义；空表示私钥未加密）。
    /// 与私钥一样只进 Keychain，不进 `state-v1.json`（spec AC-G4）。
    var passphrase: String = ""
    /// PI-adaptor 的 RACP 端口（可留空：留空时只测试 SSH，不建 RACP 隧道）。
    var hostPort: String = ""
    /// 用户选择的私钥文件名（只用于回显；内容在 `secret` 里，随凭证进 Keychain）。
    var keyFileName: String?

    init() {}

    init(record: HostRecord) {
        name = record.name
        host = record.host
        port = String(record.port)
        username = record.username
        authKind = record.authKind
        secret = ""
        passphrase = ""
        hostPort = record.hostPort.map(String.init) ?? ""
        keyFileName = record.keyFileName
    }
}

struct HostDraftErrors: Equatable {
    var name: String?
    var host: String?
    var port: String?
    var username: String?
    var secret: String?
    /// 私钥口令缺失（私钥带口令但没填）。
    var passphrase: String?
    var hostPort: String?

    static let none = HostDraftErrors()

    var isValid: Bool {
        name == nil && host == nil && port == nil && username == nil && secret == nil
            && passphrase == nil && hostPort == nil
    }
}

/// 表单内联校验（screens.md S-04「表单增加内联错误行」）。
/// 错误只作为 danger 文本展示，不给输入框加红框（design-system.md §3 `FormField`）。
enum HostValidator {
    /// - Parameter requiresSecret: 未接 Keychain 前，编辑已存在的服务器不要求重新输入凭证
    ///   （密码/私钥不落盘，重新输入也保存不下来），新增时必须填。
    static func validate(_ draft: HostDraft, requiresSecret: Bool = true) -> HostDraftErrors {
        HostDraftErrors(
            name: nameError(draft.name),
            host: hostError(draft.host),
            port: portError(draft.port),
            username: usernameError(draft.username),
            secret: secretError(
                draft.secret,
                kind: draft.authKind,
                passphrase: draft.passphrase,
                requiresSecret: requiresSecret
            ),
            passphrase: passphraseError(draft),
            hostPort: hostPortError(draft.hostPort)
        )
    }

    /// 私钥口令校验：私钥带口令（`openssh-key-v1` 的 cipher 不是 `none`）时必须填。
    /// 未加密私钥填了口令也不报错——用户可能只是不确定，解密时用不到它。
    static func passphraseError(_ draft: HostDraft) -> String? {
        guard draft.authKind == .privateKey else { return nil }
        let keyText = draft.secret.piTrimmed
        guard !keyText.isEmpty else { return nil }
        guard let info = try? SSHPrivateKeyParser.info(openSSHPrivateKey: keyText) else { return nil }
        if info.isEncrypted, draft.passphrase.isEmpty {
            return "这把私钥带口令保护（\(info.cipherName)），请填写私钥口令"
        }
        return nil
    }

    /// PI-adaptor 端口可留空；填了就必须是 1–65535。
    static func hostPortError(_ raw: String) -> String? {
        let text = raw.piTrimmed
        if text.isEmpty { return nil }
        guard text.allSatisfy({ $0.isNumber }), let value = Int(text), (1...65535).contains(value) else {
            return "端口需为 1–65535 之间的整数（留空表示只测 SSH）"
        }
        return nil
    }

    /// 名称可留空：留空时以地址作为显示名。
    static func nameError(_ raw: String) -> String? {
        raw.piTrimmed.count > 40 ? "名称不能超过 40 个字符" : nil
    }

    static func hostError(_ raw: String) -> String? {
        let text = raw.piTrimmed
        if text.isEmpty { return "请填写服务器地址" }
        if text.contains("://") { return "只填主机名或 IP，不要包含协议前缀" }
        if text.contains("@") { return "地址不要包含 @，用户名请填在「用户名」字段" }
        if text.contains(":") { return "地址不要带端口，端口请填在「端口」字段" }
        if text.contains("/") { return "地址只填主机名或 IP，不要带路径" }
        if text.contains(where: { $0.isWhitespace }) { return "地址不能包含空格" }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._")
        if text.rangeOfCharacter(from: allowed.inverted) != nil {
            return "地址只能包含字母、数字以及 - . _"
        }
        let labels = text.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if labels.contains(where: { $0.isEmpty }) {
            return "地址格式不合法：出现空的段落（例如连续的点）"
        }
        if text.count > 253 { return "地址过长（超过 253 个字符）" }
        if labels.contains(where: { $0.count > 63 }) { return "地址中每段不超过 63 个字符" }
        if labels.contains(where: { $0.hasPrefix("-") || $0.hasSuffix("-") }) {
            return "地址中的段落不能以 - 开头或结尾"
        }
        if labels.count == 4, labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) {
            if let bad = labels.first(where: { label in
                guard let value = Int(label) else { return true }
                return value > 255
            }) {
                return "IPv4 每段需在 0–255 之间（当前有一段是 \(bad)）"
            }
        }
        return nil
    }

    static func portError(_ raw: String) -> String? {
        let text = raw.piTrimmed
        if text.isEmpty { return "请填写端口" }
        if !text.allSatisfy({ $0.isNumber }) { return "端口只能是数字" }
        guard let value = Int(text) else { return "端口需为 1–65535 之间的整数" }
        if !(1...65535).contains(value) { return "端口需为 1–65535 之间的整数" }
        return nil
    }

    static func usernameError(_ raw: String) -> String? {
        let text = raw.piTrimmed
        if text.isEmpty { return "请填写用户名" }
        if text.contains(where: { $0.isWhitespace }) { return "用户名不能包含空格" }
        if text.contains("@") { return "用户名不要包含 @，只填 @ 前面的部分" }
        if text.count > 32 { return "用户名不能超过 32 个字符" }
        return nil
    }

    /// 凭证校验。
    /// - Parameters:
    ///   - passphrase: 私钥口令；只有私钥带口令时才参与解密尝试。
    ///   - requiresSecret: `false` 时允许留空（编辑态、未接 Keychain）；留空时不校验格式。
    static func secretError(
        _ raw: String,
        kind: AuthKind,
        passphrase: String = "",
        requiresSecret: Bool = true
    ) -> String? {
        let text = raw.piTrimmed
        if text.isEmpty {
            guard requiresSecret else { return nil }
            return kind == .password ? "请填写服务器密码" : "请粘贴私钥内容"
        }
        guard kind == .privateKey else { return nil }
        if text.contains("PuTTY-User-Key-File") {
            return "不支持 PPK 私钥，请先用 puttygen 导出 OpenSSH 私钥"
        }
        // 格式/类型/口令的正确性交给真正的解析器判定——错误文案与连接时完全一致。
        do {
            _ = try SSHPrivateKeyParser.parse(
                openSSHPrivateKey: text,
                passphrase: passphrase.isEmpty ? nil : passphrase
            )
            return nil
        } catch let error as SSHPrivateKeyError {
            // 口令缺失由 `passphraseError` 单独报，避免同一处出现两条重复提示。
            if case .passphraseRequired = error { return nil }
            return error.description
        } catch {
            return "私钥无法使用：\(error)"
        }
    }
}
