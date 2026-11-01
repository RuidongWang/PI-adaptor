import Foundation

public enum BootstrapInstallCompletionDisposition: Equatable, Sendable {
    case succeeded
    case failed(reason: String)
}

/// Final local persistence is part of installation success. A verified remote
/// runtime whose Host record cannot be committed must never be presented as a
/// successful install.
public enum BootstrapInstallCompletionPolicy {
    public static func disposition(
        persisted: Bool,
        saveError: String?
    ) -> BootstrapInstallCompletionDisposition {
        guard persisted else {
            if let reason = saveError?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !reason.isEmpty {
                return .failed(reason: reason)
            }
            return .failed(reason: "无法保存本机服务器安装记录")
        }
        return .succeeded
    }
}
