import Foundation

/// 曲线策略的自动化：曲线插值 → 安全下限收敛 → 命令闸门。
///
/// 与 `RuleAutomation` 的分工完全一致，只是「目标从哪来」不同：
/// - 规则是离散阈值，命中才提速；没命中就返还系统；
/// - 曲线是连续映射，只要温度在合理范围就**一直**给目标（这也是用户选它的原因）。
///
/// 关键不变量：曲线输出一律过 `SafetyPolicy.clamp`。用户可以画一条很保守的曲线，
/// 但芯片 90℃ 时它仍会被安全下限抬上去——「只提速不压低」这条规则对曲线同样成立。
public struct CurveAutomation {

    public typealias Command = ControlCommandGate.Command

    /// 芯片温度（口径由调用方决定：最高温 / 均温，见 `TemperatureAggregation`）。
    public private(set) var dieCelsius: Double?
    /// 曲线原始输出（未过安全下限），供 UI 展示「你画的曲线给了多少」。
    public private(set) var rawCurveRpm: Double?

    public var lastCommandedRpm: Double? { gate.lastCommandedRpm }
    public var isActive: Bool { gate.isActive }

    private var engine: CurveEngine
    private var gate: ControlCommandGate

    public init(
        curve: FanCurve,
        slewRateRpmPerSecond: Double = 400,
        hysteresisCelsius: Double = 2,
        config: ControlCommandGate.Config = ControlCommandGate.Config()
    ) {
        self.engine = CurveEngine(
            curve: curve,
            slewRateRpmPerSecond: slewRateRpmPerSecond,
            hysteresisCelsius: hysteresisCelsius
        )
        self.gate = ControlCommandGate(config: config)
    }

    /// 清空状态（切换策略、唤醒、合盖恢复后调用）。
    public mutating func reset() {
        engine.reset()
        gate.reset()
        dieCelsius = nil
        rawCurveRpm = nil
    }

    /// 推进一轮。
    ///
    /// - Parameters:
    ///   - curve: 当前曲线（每次传入，用户在编辑器里拖动后立刻生效）。
    ///   - dieCelsius: 芯片温度（已按用户选择的最高温 / 均温口径聚合）；
    ///     nil（尚无采样）时返还系统，而不是猜一个转速。
    ///   - secondsElapsed: 距上轮秒数，用于斜率限制。
    public mutating func update(
        curve: FanCurve,
        dieCelsius: Double?,
        limits: FanLimits,
        secondsElapsed: TimeInterval,
        now: Date,
        profile: SafetyProfile = .default
    ) -> Command? {
        engine.curve = curve
        self.dieCelsius = dieCelsius

        guard let die = dieCelsius, let raw = engine.update(celsius: die, secondsElapsed: secondsElapsed) else {
            // 空曲线或没有温度：不进曲线，返还系统自动
            rawCurveRpm = nil
            return gate.update(target: nil, now: now)
        }

        rawCurveRpm = raw
        let clamped = SafetyPolicy.clamp(raw, dieCelsius: die, limits: limits, profile: profile)
        return gate.update(target: clamped, now: now)
    }

    /// 外部通知「已经不再接管」（helper 租约过期等）。
    public mutating func noteExternallyReleased() {
        gate.noteExternallyReleased()
    }
}
