import Foundation

/// 控制租约（TTL 看门狗）。
///
/// 安全动机：GUI 可能崩溃、被强杀、或用户直接 `kill -9`。
/// 如果 helper 只凭「最后一次命令」维持手动模式，风扇会被永久锁在某个转速——
/// 这是最严重的失效模式（散热失控 + 噪音）。
///
/// 因此 helper 侧持有一个租约：只有租约有效期内才维持手动，
/// GUI 必须周期性 `renew`；一旦过期，helper 主动返还系统自动。
public struct ControlLease: Equatable, Sendable {

    /// 有效期（秒）。
    public let ttl: TimeInterval
    /// 截止时刻。
    public private(set) var expiresAt: Date

    public init(ttl: TimeInterval, now: Date = Date()) {
        self.ttl = ttl
        self.expiresAt = now.addingTimeInterval(ttl)
    }

    /// 续期（GUI 每次成功下发/心跳时调用）。
    public mutating func renew(now: Date = Date()) {
        expiresAt = now.addingTimeInterval(ttl)
    }

    /// 是否已过期（到达截止点即视为过期，宁可早返还）。
    public func isExpired(now: Date = Date()) -> Bool {
        now >= expiresAt
    }

    /// 剩余时间（过期后为 0，不返回负数）。
    public func remaining(now: Date = Date()) -> TimeInterval {
        max(0, expiresAt.timeIntervalSince(now))
    }

    /// 是否需要立即返还系统自动。
    public func requiresRestore(now: Date = Date()) -> Bool {
        isExpired(now: now)
    }
}
