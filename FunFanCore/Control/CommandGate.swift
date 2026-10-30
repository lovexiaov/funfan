import Foundation

/// 把「算出来的目标转速」翻译成「这一轮到底要不要发 XPC、发什么」。
///
/// 为什么单独抽这一层：规则和曲线都是每秒评估一次，但硬件写入不能每秒发一次——
/// 既浪费 IPC，也会刷爆 helper 的日志与租约心跳。这里统一做三件事：
///
/// 1. **死区**：目标变化小于 `deadbandRpm` 不发（避免 1 RPM 抖动导致风扇嗡嗡变调）；
/// 2. **重断言**：目标不变时也每 `refreshInterval` 秒重发一次
///    （`thermalmonitord` 可能在后台把模式改回自动，需要周期性夺回）；
/// 3. **解除只发一次**：从「有目标」变「无目标」时发一次 `.release`，之后保持沉默。
///
/// 纯逻辑、时间由外部注入 → 可完整单测，不依赖真实时钟。
public struct ControlCommandGate {

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
    private var lastSentAt: Date?

    public init(config: Config = Config()) {
        self.config = config
    }

    public var isActive: Bool { lastCommandedRpm != nil }

    /// 清空状态（切换策略、睡眠唤醒、用户手动接管后调用）。
    public mutating func reset() {
        lastCommandedRpm = nil
        lastSentAt = nil
    }

    /// 评估一轮，返回需要下发的命令（nil = 本轮什么都不用做）。
    public mutating func update(target: Double?, now: Date) -> Command? {
        guard let target else {
            guard lastCommandedRpm != nil else { return nil }
            reset()
            return .release
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
        reset()
    }
}
