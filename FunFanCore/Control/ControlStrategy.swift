import Foundation

/// 风扇控制策略。
///
/// 为什么放在 Core 而不是 GUI 里：它是控制层的领域词汇，UI 与持久化（`ControlPreferences`）
/// 必须共用同一份 `rawValue`。字符串一旦写进 UserDefaults 就变成兼容性契约——
/// 改名字等于让所有老用户的选择在升级后悄悄回落到「自动」。
public enum ControlStrategy: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case fixed
    case curve
    case rules

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .automatic: return "自动"
        case .fixed: return "固定"
        case .curve: return "曲线"
        case .rules: return "规则"
        }
    }

    /// 是否由本应用持续计算目标（需要更快的采样与规则/曲线引擎）。
    public var isAutomated: Bool {
        self == .curve || self == .rules
    }
}
