import XCTest
@testable import FunFanCore

/// 控制租约（TTL 看门狗）测试。
///
/// 目的：GUI 崩溃/被杀时，helper 不能把风扇永久留在手动模式。
/// helper 只在租约有效期内维持手动；GUI 需周期性 `renew`。
final class ControlLeaseTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_000_000)

    func testLeaseIsValidImmediately() {
        let lease = ControlLease(ttl: 10, now: base)
        XCTAssertFalse(lease.isExpired(now: base))
    }

    func testLeaseExpiresAtDeadline() {
        let lease = ControlLease(ttl: 10, now: base)
        XCTAssertFalse(lease.isExpired(now: base.addingTimeInterval(9.9)))
        XCTAssertTrue(lease.isExpired(now: base.addingTimeInterval(10)), "到达截止点即视为过期")
        XCTAssertTrue(lease.isExpired(now: base.addingTimeInterval(60)))
    }

    func testRenewExtendsDeadline() {
        var lease = ControlLease(ttl: 10, now: base)
        lease.renew(now: base.addingTimeInterval(8))

        XCTAssertFalse(lease.isExpired(now: base.addingTimeInterval(17)))
        XCTAssertTrue(lease.isExpired(now: base.addingTimeInterval(18.1)))
    }

    func testRemainingTimeIsClampedAtZero() {
        let lease = ControlLease(ttl: 5, now: base)
        XCTAssertEqual(lease.remaining(now: base.addingTimeInterval(2)), 3, accuracy: 0.001)
        XCTAssertEqual(lease.remaining(now: base.addingTimeInterval(99)), 0, accuracy: 0.001)
    }

    /// 租约过期意味着必须返还系统自动——这是安全不变量，不能靠调用方自觉。
    func testExpiredLeaseRequiresRestore() {
        let lease = ControlLease(ttl: 10, now: base)
        XCTAssertTrue(lease.requiresRestore(now: base.addingTimeInterval(11)))
        XCTAssertFalse(lease.requiresRestore(now: base.addingTimeInterval(1)))
    }
}
