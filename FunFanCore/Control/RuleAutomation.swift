import Foundation

/// 把「规则评估」翻译成「是否需要真的发一次 XPC」。
///
/// 为什么需要这一层：规则每 0.5 s 评估一次，但硬件写入不能每 0.5 s 发一次——
/// 既浪费 IPC，也会让 helper 的租约看门狗与日志被刷屏。这里做三件事：
/// 1. **死区**：目标变化小于 `deadbandRpm` 不发（避免 1 RPM 抖动）；
/// 2. **重断言**：即使目标不变，每 `refreshInterval` 秒也重发一次
///    （`thermalmonitord` 可能在后台把模式改回自动，需要周期性夺回）；
/// 3. **解除只发一次**：从「有目标」变「无目标」时发一次 `.release`，之后保持沉默。
///
/// 纯逻辑、时间由外部注入 → 可完整单测，不依赖真实时钟。
public struct RuleAutomation {

    public enum Command: Equatable, Sendable {
        case setRpm(Double)
        case release
    }

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
    public private(set) var lastCommandedRpm: Double?
    /// 本次处于触发状态的规则（供 UI 高亮）。
    public private(set) var triggeredRuleIDs: [UUID] = []
    /// 用于安全下限的芯片温度。
    public private(set) var dieCelsius: Double?

    private var engine = RuleEngine()
    private var lastSentAt: Date?

    public init(config: Config = Config()) {
        self.config = config
    }

    public var isActive: Bool { lastCommandedRpm != nil }

    /// 清空状态（切换策略、唤醒、用户手动接管后调用）。
    public mutating func reset() {
        engine.reset()
        lastCommandedRpm = nil
        lastSentAt = nil
        triggeredRuleIDs = []
        dieCelsius = nil
    }

    /// 评估一轮，返回**需要下发的命令**（nil 表示本轮什么都不用做）。
    public mutating func update(
        snapshot: SensorSnapshot,
        rules: [FanRule],
        limits: FanLimits,
        now: Date,
        profile: SafetyProfile = .default
    ) -> Command? {
        let evaluation = engine.evaluate(
            snapshot: snapshot, rules: rules, limits: limits, profile: profile
        )

        triggeredRuleIDs = evaluation.triggeredRuleIDs
        dieCelsius = evaluation.dieCelsius

        guard let target = evaluation.commandedRpm else {
            if lastCommandedRpm != nil {
                lastCommandedRpm = nil
                lastSentAt = nil
                return .release
            }
            return nil
        }

        let changed = lastCommandedRpm.map { abs($0 - target) > config.deadbandRpm } ?? true
        let expired = lastSentAt.map { now.timeIntervalSince($0) >= config.refreshInterval } ?? true

        guard changed || expired else { return nil }

        lastCommandedRpm = target
        lastSentAt = now
        return .setRpm(target)
    }

    /// 外部（如 helper 租约过期）通知「已经不再接管」时同步内部状态。
    public mutating func noteExternallyReleased() {
        lastCommandedRpm = nil
        lastSentAt = nil
    }
}
