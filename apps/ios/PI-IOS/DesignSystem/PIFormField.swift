import SwiftUI
import PIiOSCore

/// 表单字段（design-system.md §3 `FormField`）：label 在上，错误在下方用 danger 文本，不用红色边框。
struct PIFormField<Field: View>: View {
    let label: String
    var hint: String? = nil
    var error: String? = nil
    var isPill: Bool = true
    @ViewBuilder let field: () -> Field

    var body: some View {
        VStack(alignment: .leading, spacing: PISpacing.s8) {
            Text(label)
                .font(PIFont.captionStrong)
                .foregroundStyle(PIColor.text2)
            if isPill {
                field()
                    .font(PIFont.body)
                    .foregroundStyle(PIColor.text)
                    .padding(.horizontal, PISpacing.s12)
                    .padding(.vertical, PISpacing.s8)
                    .frame(minHeight: PIMetrics.minHitTarget)
                    .background(PIColor.surface2, in: RoundedRectangle(cornerRadius: PIRadius.control, style: .continuous))
            } else {
                field()
            }
            if let error {
                Text(error)
                    .font(PIFont.caption)
                    .foregroundStyle(PIColor.danger)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let hint {
                Text(hint)
                    .font(PIFont.caption)
                    .foregroundStyle(PIColor.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// 会话权限徽标（design-system.md §3 `PermissionBadge`）。
///
/// 枚举来自 `PIiOSCore.RACPPermissionMode`（契约 §3.1 的 `permissionMode` 三值），
/// App 内不再保留第二份定义；title/tint 的展示映射在 `App/CoreAdapters.swift`。
struct PIPermissionBadge: View {
    let mode: RACPPermissionMode

    var body: some View {
        HStack(spacing: PISpacing.s4) {
            Circle()
                .fill(mode.tint)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(mode.title)
                .font(PIFont.metaSmall)
                .foregroundStyle(mode.tint)
        }
        .padding(.horizontal, PISpacing.s8)
        .padding(.vertical, PISpacing.s4)
        .background(mode.tint.opacity(0.12), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("权限模式：\(mode.title)")
    }
}
