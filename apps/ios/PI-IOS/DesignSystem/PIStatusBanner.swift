import SwiftUI

/// 常驻顶部状态条（design-system.md §3 `StatusBanner` / §4 关键状态）。
/// 用 `.safeAreaInset(edge: .top)` 或页面内容顶部放置，不随滚动隐藏。
enum PIStatusKind {
    case info
    case warning
    case danger
    case success

    var tint: Color {
        switch self {
        case .info: return PIColor.accent
        case .warning: return PIColor.warning
        case .danger: return PIColor.danger
        case .success: return PIColor.success
        }
    }

    var icon: String {
        switch self {
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .danger: return "exclamationmark.octagon.fill"
        case .success: return "checkmark.circle.fill"
        }
    }
}

struct PIStatusBanner: View {
    let kind: PIStatusKind
    let text: String
    var detail: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: PISpacing.s8) {
            Image(systemName: kind.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(kind.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: PISpacing.s4) {
                Text(text)
                    .font(PIFont.captionStrong)
                    .foregroundStyle(kind.tint)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(PIFont.caption)
                        .foregroundStyle(PIColor.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .font(PIFont.captionStrong)
                        .foregroundStyle(kind.tint)
                        .frame(minHeight: PIMetrics.minHitTarget, alignment: .leading)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(PISpacing.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(kind.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: PIRadius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PIRadius.control, style: .continuous)
                .strokeBorder(kind.tint.opacity(0.28), lineWidth: PIMetrics.hairline)
        )
        .accessibilityElement(children: .combine)
    }
}

/// 空态（design-system.md §3 `EmptyState`）：一句解释 + 一个主操作，不放插画。
struct PIEmptyState: View {
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: PISpacing.s12) {
            Text(title)
                .font(PIFont.listTitle)
                .foregroundStyle(PIColor.text)
            Text(message)
                .font(PIFont.caption)
                .foregroundStyle(PIColor.text2)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(PIFont.button)
                        .foregroundStyle(PIColor.onAccent)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: PIMetrics.minHitTarget)
                        .background(PIColor.accent, in: RoundedRectangle(cornerRadius: PIRadius.control, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(PIMetrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PIColor.surface, in: RoundedRectangle(cornerRadius: PIRadius.group, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PIRadius.group, style: .continuous)
                .strokeBorder(PIColor.separator, lineWidth: PIMetrics.hairline)
        )
    }
}
