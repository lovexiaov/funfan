import XCTest
import FunFanCore

/// 租约恢复的重试节奏。
///
/// 为什么值得单独测：这是「策略被悄悄改成自动」那次事故的修复核心。
/// 以前租约一失败就直接把 `strategy` 写成 `.automatic` 并落盘，用户的选择被
/// 一个**运行时故障**永久覆盖。现在失败只允许改运行时状态 + 重试，重试节奏
/// 必须是有界、可重置的——否则要么疯狂刷 XPC，要么永远不再尝试。
final class ControlRecoveryPolicyTests: XCTestCase {

    func testDelaysGrowThenExhaust() {
        var policy = ControlRecoveryPolicy()
        XCTAssertEqual(policy.nextDelay(), 2)
        XCTAssertEqual(policy.nextDelay(), 4)
        XCTAssertEqual(policy.nextDelay(), 8)
        XCTAssertEqual(policy.nextDelay(), 16)
        XCTAssertEqual(policy.nextDelay(), 30)
        XCTAssertNil(policy.nextDelay(), "用完就必须停下，不能无限重试")
    }

    func testAttemptsAreCounted() {
        var policy = ControlRecoveryPolicy()
        XCTAssertEqual(policy.attemptsMade, 0)
        _ = policy.nextDelay()
        _ = policy.nextDelay()
        XCTAssertEqual(policy.attemptsMade, 2)
    }

    func testIsExhaustedOnlyAfterLastDelayIsHandedOut() {
        var policy = ControlRecoveryPolicy(delays: [1, 2])
        XCTAssertFalse(policy.isExhausted)
        _ = policy.nextDelay()
        XCTAssertFalse(policy.isExhausted, "刚拿到第一次延迟时还没耗尽")
        _ = policy.nextDelay()
        XCTAssertTrue(policy.isExhausted)
    }

    func testResetReturnsToFirstDelay() {
        var policy = ControlRecoveryPolicy(delays: [1, 2])
        _ = policy.nextDelay()
        _ = policy.nextDelay()
        XCTAssertTrue(policy.isExhausted)

        policy.reset()
        XCTAssertFalse(policy.isExhausted)
        XCTAssertEqual(policy.attemptsMade, 0)
        XCTAssertEqual(policy.nextDelay(), 1, "恢复成功后再断一次，必须从头开始退避")
    }

    func testEmptyDelaysExhaustsImmediately() {
        var policy = ControlRecoveryPolicy(delays: [])
        XCTAssertTrue(policy.isExhausted)
        XCTAssertNil(policy.nextDelay())
    }
}
