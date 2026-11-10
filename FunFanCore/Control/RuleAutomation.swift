import Foundation

/// 把「规则评估」翻译成「是否需要真的发一次 XPC」。
///
/// 死区 / 重断言 / 解除只发一次这三件事已抽到 `ControlCommandGate`，
/// 与曲线自动化共用同一套判定，避免两条策略在抖动行为上悄悄分叉。
///
/// 本类型只负责：把 `SensorSnapshot` + 规则集喂给引擎，再把引擎给出的目标交给闸门。
/// 纯逻辑、时间由外部注入 → 可完整单测，不依赖真实时钟。
public struct RuleAutomation {

    /// 命令类型与曲线自动化共用。
    public typealias Command = ControlCommandGate.Command

    public struct Config: Equatable, Sendable {
        /// 目标变化死区（RPM）。
        public var deadbandRpm: Double
        /// 同目标重断言周期（秒）。
        public var refreshInterval: TimeInterval

        public init(deadbandRpm: Double = 40, refreshInterval: TimeInterval = 10) {
            self.deadbandRpm = deadbandRpm
            self.refreshInterval = refreshInterval
        }
    }

    public let config: Config

    /// 最近一次已下发的目标（nil = 当前不接管）。
    public var lastCommandedRpm: Double? { gate.lastCommandedRpm }
    /// 本次处于触发状态的规则（供 UI 高亮）。
    public private(set) var triggeredRuleIDs: [UUID] = []
    /// 用于安全下限的芯片温度。
    public private(set) var dieCelsius: Double?

    private var engine = RuleEngine()
    private var gate: ControlCommandGate

    public init(config: Config = Config()) {
        self.config = config
        self.gate = ControlCommandGate(
            config: ControlCommandGate.Config(
                deadbandRpm: config.deadbandRpm,
                refreshInterval: config.refreshInterval
            )
        )
    }

    public var isActive: Bool { gate.isActive }

    /// 清空状态（切换策略、唤醒、用户手动接管后调用）。
    public mutating func reset() {
        engine.reset()
        gate.reset()
        triggeredRuleIDs = []
        dieCelsius = nil
    }

    /// 评估一轮，返回**需要下发的命令**（nil 表示本轮什么都不用做）。
    ///
    /// - Parameter aggregation: 安全下限用哪个温度口径（最高温 / 均温），由用户在设置里选。
    public mutating func update(
        snapshot: SensorSnapshot,
        rules: [FanRule],
        limits: FanLimits,
        now: Date,
        aggregation: TemperatureAggregation = .peak,
        profile: SafetyProfile = .default
    ) -> Command? {
        let evaluation = engine.evaluate(
            snapshot: snapshot, rules: rules, limits: limits,
            aggregation: aggregation, profile: profile
        )

        triggeredRuleIDs = evaluation.triggeredRuleIDs
        dieCelsius = evaluation.dieCelsius

        return gate.update(target: evaluation.commandedRpm, now: now)
    }

    /// 外部（如 helper 租约过期）通知「已经不再接管」时同步内部状态。
    public mutating func noteExternallyReleased() {
        gate.noteExternallyReleased()
    }
}
