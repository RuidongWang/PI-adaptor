import SwiftUI

/// 列表行（design-system.md §3 `ListRow`）：标题 + 可选第二行说明 + 右侧值与 chevron。
/// 双行时行高不小于 62pt；右侧 chevron 表示可进入。
struct PIListRow<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    var value: String? = nil
    var isEnabled: Bool = true
    var showsChevron: Bool = false
    var showsDivider: Bool = true
    var action: (() -> Void)? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        VStack(spacing: 0) {
            if let action, isEnabled {
                Button(action: action) { content }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
            } else {
                content
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isStaticText)
            }
            if showsDivider {
                PIRowDivider()
            }
        }
    }

    private var content: some View {
        HStack(alignment: .center, spacing: PISpacing.s12) {
            VStack(alignment: .leading, spacing: PISpacing.s4) {
                Text(title)
                    .font(PIFont.listTitle)
                    .foregroundStyle(isEnabled ? PIColor.text : PIColor.text3)
                    .multilineTextAlignment(.leading)
                if let subtitle {
                    Text(subtitle)
                        .font(PIFont.caption)
                        .foregroundStyle(PIColor.text2)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
            }
            Spacer(minLength: PISpacing.s8)
            if let value {
                Text(value)
                    .font(PIFont.caption)
                    .foregroundStyle(isEnabled ? PIColor.text2 : PIColor.text3)
            }
            trailing()
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isEnabled ? PIColor.text3 : PIColor.text3.opacity(0.6))
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, PISpacing.s16)
        .padding(.vertical, PISpacing.s12)
        .frame(minHeight: PIMetrics.listRowMinHeight)
        .contentShape(Rectangle())
    }
}

extension PIListRow where Trailing == EmptyView {
    init(
        title: String,
        subtitle: String? = nil,
        value: String? = nil,
        isEnabled: Bool = true,
        showsChevron: Bool = false,
        showsDivider: Bool = true,
        action: (() -> Void)? = nil
    ) {
        self.init(
            title: title,
            subtitle: subtitle,
            value: value,
            isEnabled: isEnabled,
            showsChevron: showsChevron,
            showsDivider: showsDivider,
            action: action,
            trailing: { EmptyView() }
        )
    }
}

/// 危险操作行（design-system.md §3 `DangerRow`）：文字用 danger，点击后走二次确认。
/// 禁用时给出原因，不做「可点击但无作用」的按钮。
struct PIDangerRow: View {
    let title: String
    var isEnabled: Bool = true
    var disabledReason: String? = nil
    var showsDivider: Bool = false
    let action: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(role: .destructive, action: action) {
                VStack(alignment: .leading, spacing: PISpacing.s4) {
                    Text(title)
                        .font(PIFont.listTitle)
                        .foregroundStyle(isEnabled ? PIColor.danger : PIColor.text3)
                    if let disabledReason, !isEnabled {
                        Text(disabledReason)
                            .font(PIFont.caption)
                            .foregroundStyle(PIColor.text3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, PISpacing.s16)
                .padding(.vertical, PISpacing.s12)
                .frame(minHeight: PIMetrics.minHitTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
            .accessibilityElement(children: .combine)
            if showsDivider {
                PIRowDivider()
            }
        }
    }
}

/// 成功提示（design-system.md §6 `.toast` → overlay + 自动消失，仅成功提示）。
struct PIToast: Identifiable, Equatable {
    let id = UUID()
    let text: String
}

struct PIToastView: View {
    let toast: PIToast

    var body: some View {
        HStack(spacing: PISpacing.s8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(PIColor.success)
                .accessibilityHidden(true)
            Text(toast.text)
                .font(PIFont.caption)
                .foregroundStyle(PIColor.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, PISpacing.s16)
        .padding(.vertical, PISpacing.s12)
        .background(PIColor.surface, in: RoundedRectangle(cornerRadius: PIRadius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PIRadius.control, style: .continuous)
                .strokeBorder(PIColor.separator, lineWidth: PIMetrics.hairline)
        )
        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
        .padding(.horizontal, PIMetrics.pageMargin)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }
}
