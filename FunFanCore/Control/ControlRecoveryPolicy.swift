import Foundation

/// 租约断开后的重试节奏（有界退避）。
///
/// 背景：helper 侧租约 TTL 10 s，GUI 每 2 s 续租。续租失败可能是**瞬时**的
/// （XPC 超时、helper 重启、机器忙着编译、刚被系统睡眠叫醒），也可能确实
/// 再也不通（helper 被卸载）。这两种情况都不该动用户的策略——策略是意图，
/// 不是运行状态。
///
/// 所以失败后只做两件事：把风扇交还系统（安全），然后按这里的节奏重连。
/// 次数有界、成功后 `reset()` 归零，避免「一次抖动 = 永久自动」，
/// 也避免 helper 没了还每 2 s 刷一次 XPC。
public struct ControlRecoveryPolicy: Equatable, Sendable {

    /// 2 → 4 → 8 → 16 → 30 秒，约 1 分钟覆盖常见瞬时故障。
    public static let defaultDelays: [TimeInterval] = [2, 4, 8, 16, 30]

    public let delays: [TimeInterval]
    public private(set) var attemptsMade = 0

    public init(delays: [TimeInterval] = ControlRecoveryPolicy.defaultDelays) {
        self.delays = delays
    }

    /// 已经放弃（不再自动重试，需要用户手动「重新检测」）。
    public var isExhausted: Bool {
        attemptsMade >= delays.count
    }

    /// 下一次重试前该等多久；`nil` 表示不再重试。
    public mutating func nextDelay() -> TimeInterval? {
        guard attemptsMade < delays.count else { return nil }
        defer { attemptsMade += 1 }
        return delays[attemptsMade]
    }

    /// 恢复成功后调用：下一次断开重新从最短间隔开始。
    public mutating func reset() {
        attemptsMade = 0
    }
}
