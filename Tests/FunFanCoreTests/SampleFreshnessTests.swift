import XCTest
@testable import FunFanCore

/// 面板头部「x 秒」的含义判定：把「慢」和「停了」分开。
///
/// 那个数字只是「上次采样距今多久」，本身没有对错；有对错的是它**涨到多大**。
/// 采样周期是 2 s（面板打开）/ 1 s（自动化接管），所以「超过一个周期再多几秒」
/// 就不再是「恰好卡在两次采样之间」，而是采样真的没在发生。
final class SampleFreshnessTests: XCTestCase {

    // MARK: - 判定是否停住

    func testFreshWithinCycleIsNotStale() {
        // 面板打开 2 s 一帧：刚采完 0.3 s、以及恰好撑满一个周期的 2.0 s 都算正常。
        XCTAssertFalse(SampleFreshness.isStale(age: 0.3, interval: 2.0))
        XCTAssertFalse(SampleFreshness.isStale(age: 2.0, interval: 2.0))
    }

    func testStaleOnlyAfterGraceBeyondCycle() {
        // 宽限期不是「任意大于周期」：抖动 + 定时器 leeway 200 ms 都在正常范围内，
        // 只有明显超出（>周期+3 s）才提示，避免面板刚开就闪一条「采样停止」吓人。
        XCTAssertFalse(SampleFreshness.isStale(age: 4.5, interval: 2.0))
        XCTAssertTrue(SampleFreshness.isStale(age: 5.5, interval: 2.0))
    }

    func testAutomationCycleKeepsOneSecondTolerance() {
        // 自动化档 1 s：同样是「周期 + 宽限」，不因为周期短就更早报警。
        XCTAssertFalse(SampleFreshness.isStale(age: 3.5, interval: 1.0))
        XCTAssertTrue(SampleFreshness.isStale(age: 4.5, interval: 1.0))
    }

    func testNegativeAgeFromClockRollbackIsNotStale() {
        // 睡眠唤醒等场景 now < last，age 可能为负；不能因此判成「停住」。
        XCTAssertFalse(SampleFreshness.isStale(age: -12, interval: 2.0))
    }

    // MARK: - 时长文案

    func testDurationTextUsesSecondsUnderAMinute() {
        XCTAssertEqual(SampleFreshness.durationText(0), "0 秒")
        XCTAssertEqual(SampleFreshness.durationText(0.4), "0 秒")
        XCTAssertEqual(SampleFreshness.durationText(1.4), "1 秒")
        XCTAssertEqual(SampleFreshness.durationText(2), "2 秒")
    }

    func testDurationTextSwitchesToMinutesWithoutPrinting60Seconds() {
        // 59.6 s 四舍五入成 60——不能显示「60 秒」，要进位成「1 分钟」。
        XCTAssertEqual(SampleFreshness.durationText(59.6), "1 分钟")
        XCTAssertEqual(SampleFreshness.durationText(90), "2 分钟")
        // 采样停住后时间会一直涨，187 s 要能自己换算，而不是让人看到「187 秒」。
        XCTAssertEqual(SampleFreshness.durationText(187), "3 分钟")
    }

    func testDurationTextClampsNegativeToZero() {
        XCTAssertEqual(SampleFreshness.durationText(-3), "0 秒")
    }
}
