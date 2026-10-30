import Foundation

/// 曲线预设：三档「性格」，全部按**占比**定义，自动适配机型的风扇区间。
///
/// 为什么用占比而不是写死 RPM：同一份预设要在 1000–4900（Mac mini）和
/// 1200–6800（MacBook Pro）上都合理，写死 3500 会在小风扇机型上等于满转。
public enum CurvePreset: String, CaseIterable, Identifiable, Codable, Sendable {

    /// 尽量不响：低于 75℃ 基本不介入。
    case quiet
    /// 默认：60℃ 起明显提速，90℃ 全速。
    case balanced
    /// 压得住温度优先：35℃ 就开始给基础转速。
    case performance

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .quiet: return "静音"
        case .balanced: return "均衡"
        case .performance: return "性能"
        }
    }

    public var detail: String {
        switch self {
        case .quiet: return "75℃ 以下几乎不介入，温度换噪音"
        case .balanced: return "60℃ 起提速，90℃ 全速"
        case .performance: return "35℃ 起就给基础转速，优先压温"
        }
    }

    /// 控制点形状：温度（℃）→ 占区间比例（0 = `F0Mn`，1 = `F0Mx`）。
    public var shape: [(celsius: Double, fraction: Double)] {
        switch self {
        case .quiet:
            return [(45, 0), (65, 0.15), (80, 0.40), (92, 0.65)]
        case .balanced:
            return [(40, 0), (60, 0.25), (75, 0.55), (90, 1.0)]
        case .performance:
            return [(35, 0.30), (50, 0.50), (70, 0.80), (88, 1.0)]
        }
    }

    /// 按机型区间展开成真实曲线。
    public func curve(limits: FanLimits) -> FanCurve {
        let low = limits.minRpm
        let span = max(0, limits.normalizedMax - low)

        let points = shape.map { item -> CurvePoint in
            let rpm = low + span * min(max(item.fraction, 0), 1)
            // 取整到 10 RPM：SMC 侧本来也读不出比这更细的差别，避免界面出现 2947 这种数
            return CurvePoint(celsius: item.celsius, rpm: (rpm / 10).rounded() * 10)
        }
        return FanCurve(points: points)
    }

    /// 判定某条曲线是否就是本预设（容差用于吸收取整误差）。
    public static func matching(_ curve: FanCurve, limits: FanLimits, tolerance: Double = 15) -> CurvePreset? {
        allCases.first { preset in
            let target = preset.curve(limits: limits)
            guard target.points.count == curve.points.count else { return false }
            return zip(target.points, curve.points).allSatisfy { expected, actual in
                abs(expected.celsius - actual.celsius) < 0.01 && abs(expected.rpm - actual.rpm) <= tolerance
            }
        }
    }
}
