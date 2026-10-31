import Foundation

// MARK: - 思考档位（AC-07.4 / AC-07.6 / AC-07.7）

/// 一个模型声明的档位信息。
///
/// 上游把档位挂在**模型**上而不是服务上（spec AC-07.4），因此这里的输入永远来自
/// 「当前选中的那个模型」，而不是它所属的 provider。
public struct ThinkingLevelSupport: Equatable, Sendable {
    /// 该模型声明支持的档位；空数组表示「未声明任何档位」。
    public let declared: [RACPThinkingLevel]
    /// 该模型自己声明的默认档位；可以不在 `declared` 里（上游允许），本类型不做静默修正。
    public let defaultLevel: RACPThinkingLevel?

    public init(declared: [RACPThinkingLevel], defaultLevel: RACPThinkingLevel? = nil) {
        self.declared = declared
        self.defaultLevel = defaultLevel
    }
}

/// 档位解析结果。
public struct ThinkingLevelResolution: Equatable, Sendable {
    /// 实际应写进 `session/configure` 的档位；`nil` 表示**不下发**该字段（AC-07.7）。
    public let level: RACPThinkingLevel?
    /// 原档位不被新模型声明，已改用别的档位（界面必须说明，AC-07.6）。
    public let didFallback: Bool
    /// 回落目标来自模型默认档位还是声明列表首项；`nil` 表示没有回落。
    public let fallbackSource: FallbackSource?

    public enum FallbackSource: String, Equatable, Sendable {
        case modelDefault = "model_default"
        case firstDeclared = "first_declared"
    }

    public init(
        level: RACPThinkingLevel?,
        didFallback: Bool,
        fallbackSource: FallbackSource?
    ) {
        self.level = level
        self.didFallback = didFallback
        self.fallbackSource = fallbackSource
    }
}

public enum ThinkingLevelPolicy {
    /// 是否显示档位控件：模型未声明任何档位时不显示（AC-07.7）。
    public static func showsPicker(_ support: ThinkingLevelSupport) -> Bool {
        !support.declared.isEmpty
    }

    /// 解析切换模型后实际生效的档位。
    ///
    /// - 模型未声明任何档位 → `level = nil`，`didFallback = false`（不是回落，是「没有这个字段」）；
    /// - 当前档位仍被声明 → 原样保留；
    /// - 否则：模型默认档位（若被声明）→ 声明列表首项，并标记 `didFallback`。
    ///
    /// 注意「默认档位不在声明列表里」的处理：上游允许这种不一致，但把它下发会得到服务器拒绝，
    /// 因此这里只在默认档位确实被声明时采用，否则退到声明首项。
    public static func resolve(
        current: RACPThinkingLevel?,
        support: ThinkingLevelSupport
    ) -> ThinkingLevelResolution {
        guard !support.declared.isEmpty else {
            return ThinkingLevelResolution(level: nil, didFallback: false, fallbackSource: nil)
        }
        if let current, support.declared.contains(current) {
            return ThinkingLevelResolution(level: current, didFallback: false, fallbackSource: nil)
        }
        if let fallback = support.defaultLevel, support.declared.contains(fallback) {
            return ThinkingLevelResolution(level: fallback, didFallback: true, fallbackSource: .modelDefault)
        }
        return ThinkingLevelResolution(level: support.declared[0], didFallback: true, fallbackSource: .firstDeclared)
    }

    /// 回落的用户可读说明（AC-07.6 要求显式说明原档位不可用及实际生效档位）。
    public static func fallbackExplanation(
        from: RACPThinkingLevel?,
        to: RACPThinkingLevel?,
        fallbackSource: ThinkingLevelResolution.FallbackSource? = nil
    ) -> String? {
        guard let to else { return nil }
        guard let from else {
            switch fallbackSource {
            case .modelDefault:
                return "会话原本没有档位，已采用模型默认档位「\(to.rawValue)」。"
            case .firstDeclared:
                return "模型没有可用默认档位，已采用声明列表首项「\(to.rawValue)」。"
            case nil:
                return "已采用「\(to.rawValue)」。"
            }
        }
        return "原档位「\(from.rawValue)」不被新模型声明，已改用「\(to.rawValue)」。"
    }
}
