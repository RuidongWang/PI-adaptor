import SwiftUI
import UIKit

/// 颜色 token。取值来源：`apps/ios/design/design-system.md` §2.1（浅色 / 深色两套精确 hex）。
/// 语义色只用于表达状态，不做装饰。
enum PIColor {
    /// --bg 页面背景
    static let bg = dynamic(light: 0xF8F9FB, dark: 0x11151B)
    /// --surface 列表、卡片、浮层
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x1C222B)
    /// --surface-2 次级按钮、配置 chip
    static let surface2 = dynamic(light: 0xEFF2F6, dark: 0x282F3A)
    /// --separator 弱分隔线
    static let separator = dynamic(light: 0xE5E9EF, dark: 0x303947)
    /// --text 主文本
    static let text = dynamic(light: 0x202936, dark: 0xEDF1F7)
    /// --text-2 次要文本
    static let text2 = dynamic(light: 0x647183, dark: 0xA6B2C3)
    /// --text-3 占位与辅助图标
    static let text3 = dynamic(light: 0x8C98A7, dark: 0x8290A4)
    /// --accent 主操作、选中
    static let accent = dynamic(light: 0x2369D8, dark: 0x89B5FF)
    /// --danger 删除、拒绝
    static let danger = dynamic(light: 0xD74746, dark: 0xFF9691)
    /// --warning auto、停滞、只读
    static let warning = dynamic(light: 0x98651B, dark: 0xE6BF79)
    /// --success 在线、完成
    static let success = dynamic(light: 0x278269, dark: 0x8BCDB5)
    /// --accent-soft 选中行、用户气泡
    static let accentSoft = dynamic(light: 0xEAF1FD, dark: 0x233751)
    /// 实心强调色按钮上的文字：浅色模式白字，深色模式深色字
    /// （design-system.md §2.5「深色模式…实心主按钮用深色文字，避免亮蓝底白字对比不足」）。
    static let onAccent = dynamic(light: 0xFFFFFF, dark: 0x11151B)
    /// 遮罩（侧边栏 / 浮层背后的压暗层）：浅色与深色同用半透明黑。
    static let scrim = Color.black.opacity(0.34)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(rgb: dark) : UIColor(rgb: light)
        })
    }
}

private extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// 字号层级 token（design-system.md §2.2）。行高以 paragraph line height 表达。
enum PIFont {
    /// 根页标题 28 / 34 · 700
    static let rootTitle = Font.system(size: 28, weight: .bold)
    /// 导航与详情标题 19–20 / 26–27 · 650（System 无 650，取 semibold）
    static let navTitle = Font.system(size: 20, weight: .semibold)
    /// 列表主文本 15 / 21 · 600
    static let listTitle = Font.system(size: 15, weight: .semibold)
    /// 正文 15 / 25 · Regular
    static let body = Font.system(size: 15, weight: .regular)
    /// 主操作按钮文字 15 · 600（整宽 44pt 高的实心/次级按钮使用）。
    /// 注：design-system.md §2.2 把「按钮与说明」标为 13pt，指小按钮与说明文字；
    /// 全宽主操作按钮用 15pt 以保证可读性，二者为不同档位，文档口径见 §2.2 备注。
    static let button = Font.system(size: 15, weight: .semibold)
    static let caption = Font.system(size: 13, weight: .regular)
    static let captionStrong = Font.system(size: 13, weight: .semibold)
    /// 元信息 10–12 / 16–18 · Regular
    static let meta = Font.system(size: 12, weight: .regular)
    static let metaSmall = Font.system(size: 11, weight: .regular)
    /// 分组标题：正常大小写中文，不用大写（§3 SectionHeader）
    static let section = Font.system(size: 13, weight: .semibold)
}

/// 间距阶梯 token（design-system.md §2.3）：4 / 8 / 12 / 16 / 24 / 32。
enum PISpacing {
    static let s4: CGFloat = 4
    static let s8: CGFloat = 8
    static let s12: CGFloat = 12
    static let s16: CGFloat = 16
    static let s24: CGFloat = 24
    static let s32: CGFloat = 32
}

/// 圆角 token（design-system.md §2.3）：控件 12、分组列表 16、详情卡 20、底部浮层 26。
enum PIRadius {
    static let control: CGFloat = 12
    static let group: CGFloat = 16
    static let card: CGFloat = 20
    static let sheet: CGFloat = 26
}

/// 尺寸与安全区 token。
enum PIMetrics {
    /// --safe-bottom：浮层吸底动作区为 home indicator 预留的底部留白
    static let safeBottom: CGFloat = 22
    /// 页面边距 18–22pt
    static let pageMargin: CGFloat = 18
    /// 卡片内边距 18pt
    static let cardPadding: CGFloat = 18
    /// 触达目标不小于 44×44
    static let minHitTarget: CGFloat = 44
    /// 列表双行至少 62pt
    static let listRowMinHeight: CGFloat = 62
    /// 侧边栏会话行至少 56pt
    static let sidebarRowMinHeight: CGFloat = 56
    /// 侧边栏宽度（iPhone 16 Pro 402pt 画布下留出遮罩区）
    static let sidebarWidth: CGFloat = 320
    /// 输入条/正文使用的轻阴影
    static let hairline: CGFloat = 1
}

// MARK: - 页面容器

/// 页面背景：--bg 铺满，内容自绘卡片，不依赖 List 系统默认底色。
struct PIPageBackground: ViewModifier {
    func body(content: Content) -> some View {
        content.background(PIColor.bg.ignoresSafeArea())
    }
}

extension View {
    func piPageBackground() -> some View { modifier(PIPageBackground()) }
}
