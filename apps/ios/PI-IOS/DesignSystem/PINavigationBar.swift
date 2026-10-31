import SwiftUI

/// 导航栏（design-system.md §3 `NavBar` / §6 `.nav` → `.navigationTitle` + `.toolbar`）。
/// 根页：标题 + 左上千斤顶（≡）+ 右侧最多 1 个操作；子页：标题 + 系统 `‹` 返回。
struct PIRootNavBarModifier<Trailing: View>: ViewModifier {
    let title: String
    let onMenu: () -> Void
    @ViewBuilder let trailing: () -> Trailing

    func body(content: Content) -> some View {
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onMenu) {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(PIColor.text)
                            .frame(width: PIMetrics.minHitTarget, height: PIMetrics.minHitTarget)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("打开侧边栏")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    trailing()
                }
            }
    }
}

struct PIDetailNavBarModifier: ViewModifier {
    let title: String

    func body(content: Content) -> some View {
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }
}

extension View {
    /// 根页导航栏：左上 ≡ 打开侧边栏，右侧最多一个操作。
    func piRootNavBar<Trailing: View>(
        _ title: String,
        onMenu: @escaping () -> Void,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) -> some View {
        modifier(PIRootNavBarModifier(title: title, onMenu: onMenu, trailing: trailing))
    }

    /// 根页导航栏（无右侧操作）。
    func piRootNavBar(_ title: String, onMenu: @escaping () -> Void) -> some View {
        piRootNavBar(title, onMenu: onMenu) { EmptyView() }
    }

    /// 子页 / 流程页导航栏：系统返回按钮回到来源。
    func piDetailNavBar(_ title: String) -> some View {
        modifier(PIDetailNavBarModifier(title: title))
    }
}

/// 主操作按钮：实心 --accent，深色模式使用深色文字（§2.5）。
struct PIPrimaryButton: View {
    let title: String
    var isEnabled: Bool = true
    var identifier: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(PIFont.button)
                .foregroundStyle(PIColor.onAccent)
                .frame(maxWidth: .infinity)
                .frame(minHeight: PIMetrics.minHitTarget)
                .background(
                    RoundedRectangle(cornerRadius: PIRadius.control, style: .continuous)
                        .fill(isEnabled ? PIColor.accent : PIColor.accent.opacity(0.4))
                )
        }
        .buttonStyle(.plain)
        .modifier(OptionalAccessibilityIdentifier(identifier: identifier))
        .disabled(!isEnabled)
    }
}

private struct OptionalAccessibilityIdentifier: ViewModifier {
    let identifier: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let identifier {
            content.accessibilityIdentifier(identifier)
        } else {
            content
        }
    }
}

/// 次级操作：--surface-2 底、主文本色。
struct PISecondaryButton: View {
    let title: String
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(PIFont.button)
                .foregroundStyle(isEnabled ? PIColor.text : PIColor.text3)
                .frame(maxWidth: .infinity)
                .frame(minHeight: PIMetrics.minHitTarget)
                .background(PIColor.surface2, in: RoundedRectangle(cornerRadius: PIRadius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

/// 审批卡主决策按钮：accent 实心、整宽、44pt 热区（design-system.md §3 / spec P1 AC-1/AC-3）。
struct PIApprovalPrimaryButton: View {
    let title: String
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(PIFont.captionStrong)
                .foregroundStyle(PIColor.onAccent)
                .frame(maxWidth: .infinity)
                .frame(minHeight: PIMetrics.minHitTarget)
                .background(isEnabled ? PIColor.accent : PIColor.accent.opacity(0.4), in: RoundedRectangle(cornerRadius: PIRadius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

/// 审批卡次级决策按钮：surface2 底、主文本色（spec P1 AC-1）。
struct PIApprovalSecondaryButton: View {
    let title: String
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(PIFont.captionStrong)
                .foregroundStyle(isEnabled ? PIColor.text : PIColor.text3)
                .frame(maxWidth: .infinity)
                .frame(minHeight: PIMetrics.minHitTarget)
                .background(PIColor.surface2, in: RoundedRectangle(cornerRadius: PIRadius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

/// 审批卡危险决策按钮：danger 描边 + danger 文字、透明底，与安全动作视觉不共位
/// （design-system.md §3 ApprovalCard「拒绝用 danger 描边而非填充」/ 原则 2 / spec P1 AC-1/AC-2）。
struct PIDangerOutlineButton: View {
    let title: String
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(PIFont.captionStrong)
                .foregroundStyle(isEnabled ? PIColor.danger : PIColor.text3)
                .frame(maxWidth: .infinity)
                .frame(minHeight: PIMetrics.minHitTarget)
                .overlay(
                    RoundedRectangle(cornerRadius: PIRadius.control, style: .continuous)
                        .strokeBorder(isEnabled ? PIColor.danger : PIColor.separator, lineWidth: PIMetrics.hairline)
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

/// 单选行（外观、离线缓存上限等浮层使用）：整行可点，选中态用强调色 + 勾选。
struct PIOptionRow: View {
    let title: String
    var subtitle: String? = nil
    let isSelected: Bool
    var showsDivider: Bool = true
    let action: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: action) {
                HStack(alignment: .center, spacing: PISpacing.s12) {
                    VStack(alignment: .leading, spacing: PISpacing.s4) {
                        Text(title)
                            .font(PIFont.listTitle)
                            .foregroundStyle(PIColor.text)
                        if let subtitle {
                            Text(subtitle)
                                .font(PIFont.caption)
                                .foregroundStyle(PIColor.text2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: PISpacing.s8)
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(PIColor.accent)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.horizontal, PISpacing.s16)
                .padding(.vertical, PISpacing.s12)
                .frame(minHeight: PIMetrics.minHitTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            if showsDivider {
                PIRowDivider()
            }
        }
    }
}
