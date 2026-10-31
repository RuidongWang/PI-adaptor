import SwiftUI

/// 本机外观偏好（screens.md S-03「本机外观」）。默认跟随系统，存 `@AppStorage`，与服务器配置无关。
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let storageKey = "pi.appearance"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var detail: String {
        switch self {
        case .system: return "随系统的浅色 / 深色设置变化"
        case .light: return "始终使用浅色"
        case .dark: return "始终使用深色"
        }
    }

    /// 交给 `.preferredColorScheme`；跟随系统时为 nil。
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
