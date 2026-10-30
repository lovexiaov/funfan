import Foundation

/// 曲线控制点：温度（℃）→ 转速（RPM）。
public struct CurvePoint: Codable, Equatable, Sendable {
    public var celsius: Double
    public var rpm: Double

    public init(celsius: Double, rpm: Double) {
        self.celsius = celsius
        self.rpm = rpm
    }
}

/// 温度→转速曲线（连续映射）。
public struct FanCurve: Codable, Equatable, Sendable {
    /// 已按温度升序排列。
    public private(set) var points: [CurvePoint]

    public init(points: [CurvePoint]) {
        self.points = points.sorted { $0.celsius < $1.celsius }
    }

    /// 线性插值取目标转速；空曲线返回 nil，区间外取端点值。
    public func rpm(at celsius: Double) -> Double? {
        guard let first = points.first, let last = points.last else { return nil }
        guard points.count > 1 else { return first.rpm }

        if celsius <= first.celsius { return first.rpm }
        if celsius >= last.celsius { return last.rpm }

        for index in 1..<points.count {
            let lower = points[index - 1]
            let upper = points[index]
            guard celsius <= upper.celsius else { continue }

            let span = upper.celsius - lower.celsius
            guard span > 0 else { return upper.rpm }
            let ratio = (celsius - lower.celsius) / span
            return lower.rpm + (upper.rpm - lower.rpm) * ratio
        }
        return last.rpm
    }
}

/// 曲线引擎：在插值之上叠加**迟滞**与**斜率限制**。
///
/// - 迟滞：降温方向需越过 `hysteresisCelsius` 死区才跟随，避免阈值边缘抖动（风扇忽快忽慢的噪音）；
/// - 斜率：输出变化受 `slewRateRpmPerSecond` 限制，避免转速突变产生可听见的「加速哨音」；
/// - 升温不受迟滞延迟（安全优先），但同样受斜率约束。
public struct CurveEngine {

    public var curve: FanCurve
    public var slewRateRpmPerSecond: Double
    public var hysteresisCelsius: Double

    private var lastOutput: Double?
    /// 上次输出**发生变化**时的温度，作为死区基准。
    private var referenceCelsius: Double?

    public init(
        curve: FanCurve,
        slewRateRpmPerSecond: Double = 400,
        hysteresisCelsius: Double = 2
    ) {
        self.curve = curve
        self.slewRateRpmPerSecond = slewRateRpmPerSecond
        self.hysteresisCelsius = hysteresisCelsius
    }

    /// 清空历史输出（切换策略 / 唤醒 / 用户手动接管后调用）。
    ///
    /// 必须清：否则重新接管时会把「上次的转速」当成起点，从旧值缓慢爬向新目标，
    /// 用户会看到「切到曲线模式后风扇过了十几秒才动」。
    public mutating func reset() {
        lastOutput = nil
        referenceCelsius = nil
    }

    /// 推进一个周期，返回本周期目标转速（未经 `SafetyPolicy` clamp）。
    ///
    /// - Parameters:
    ///   - celsius: 当前核心温度（通常取 max(CPU, GPU)）。
    ///   - secondsElapsed: 距上次调用的秒数，用于计算允许的转速变化量。
    public mutating func update(celsius: Double, secondsElapsed: TimeInterval) -> Double? {
        guard let target = curve.rpm(at: celsius) else { return nil }

        // 首帧直接到位：否则开机后要从 0 缓慢爬升，延迟十几秒才生效。
        guard let last = lastOutput, let reference = referenceCelsius else {
            lastOutput = target
            referenceCelsius = celsius
            return target
        }

        var desired = target
        if target < last, celsius > reference - hysteresisCelsius {
            desired = last   // 跌幅未越过死区 → 保持当前转速
        }

        let allowedDelta = max(0, slewRateRpmPerSecond) * max(0, secondsElapsed)
        let limited = min(max(desired, last - allowedDelta), last + allowedDelta)

        if abs(limited - last) > 1e-9 {
            referenceCelsius = celsius
        }
        lastOutput = limited
        return limited
    }
}
