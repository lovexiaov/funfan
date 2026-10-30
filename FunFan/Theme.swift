import SwiftUI

/// 设计令牌（对应 docs/ui-design-handoff.md 的 tokens）。
///
/// 单一来源：UI 里不出现裸色值，一律从这里取，
/// 便于后续做浅色主题与统一调整。
enum Theme {

    // 主色：蓝青，取「风扇 / 凉爽」意象
    static let accent = Color(red: 0.275, green: 0.784, blue: 1.000)

    // 温度三态（固定阈值 60 / 75 ℃，已确认决策 H3）
    static let cool = Color(red: 0.298, green: 0.851, blue: 0.533)
    static let warm = Color(red: 1.000, green: 0.741, blue: 0.294)
    static let hot  = Color(red: 1.000, green: 0.373, blue: 0.373)

    static let warnThreshold: Double = 60
    static let hotThreshold: Double = 75

    /// 按温度取状态色。
    static func color(forCelsius value: Double?) -> Color {
        guard let value else { return .secondary }
        if value >= hotThreshold { return hot }
        if value >= warnThreshold { return warm }
        return cool
    }

    // 排版
    static let titleFont = Font.system(size: 13, weight: .semibold)
    static let labelFont = Font.system(size: 11)
    static let valueFont = Font.system(size: 20, weight: .medium).monospacedDigit()
    static let smallValueFont = Font.system(size: 13, weight: .medium).monospacedDigit()
}
