import XCTest
@testable import FunFanCore

/// 自适应采样频率：菜单栏常驻时无需 2 Hz。
///
/// 实测代价（M4 Pro，107 个传感器）：单帧 ≈ 19.5 ms、107 次 IPC。
/// 恒定 2 Hz 会长期占用约 4% 单核——对常驻工具不可接受。
final class SamplingPolicyTests: XCTestCase {

    func testIntervalsAreOrderedByVisibility() {
        let open = SamplingPolicy.interval(for: .popoverOpen)
        let menu = SamplingPolicy.interval(for: .menuBarOnly)
        let idle = SamplingPolicy.interval(for: .idle)

        XCTAssertEqual(open, 0.5, accuracy: 1e-9)
        XCTAssertEqual(menu, 2.0, accuracy: 1e-9)
        XCTAssertEqual(idle, 5.0, accuracy: 1e-9)
        XCTAssertLessThan(open, menu)
        XCTAssertLessThan(menu, idle)
    }

    func testShouldSampleRespectsInterval() {
        let last = Date(timeIntervalSince1970: 1_000)

        // Popover 打开：0.5 s 到期
        XCTAssertFalse(SamplingPolicy.shouldSample(last: last, now: last.addingTimeInterval(0.4), visibility: .popoverOpen))
        XCTAssertTrue(SamplingPolicy.shouldSample(last: last, now: last.addingTimeInterval(0.5), visibility: .popoverOpen))

        // 仅菜单栏：2 s 到期
        XCTAssertFalse(SamplingPolicy.shouldSample(last: last, now: last.addingTimeInterval(1.9), visibility: .menuBarOnly))
        XCTAssertTrue(SamplingPolicy.shouldSample(last: last, now: last.addingTimeInterval(2.0), visibility: .menuBarOnly))

        // 空闲：5 s 到期
        XCTAssertFalse(SamplingPolicy.shouldSample(last: last, now: last.addingTimeInterval(4.9), visibility: .idle))
        XCTAssertTrue(SamplingPolicy.shouldSample(last: last, now: last.addingTimeInterval(5.0), visibility: .idle))
    }

    /// 规则接管时：需要比「仅菜单栏」快，但不能像面板打开那样费电。
    func testAutomationIntervalSitsBetweenPopoverAndMenuBar() {
        let automation = SamplingPolicy.interval(for: .automation)

        XCTAssertEqual(automation, 1.0, accuracy: 1e-9)
        XCTAssertGreaterThan(automation, SamplingPolicy.interval(for: .popoverOpen))
        XCTAssertLessThan(automation, SamplingPolicy.interval(for: .menuBarOnly))

        // 1 Hz × 19.5 ms ≈ 2% 单核，规则接管时的可接受开销
        let percent = 19.5 / (automation * 1000) * 100
        XCTAssertLessThan(percent, 2.5, "规则接管时应低于 2.5% 单核")
    }

    /// 睡眠唤醒后时间跳变（now < last）必须立即采样，不能等到下一周期。
    func testClockGoingBackwardsTriggersSample() {
        let last = Date(timeIntervalSince1970: 2_000)
        let earlier = Date(timeIntervalSince1970: 1_000)

        XCTAssertTrue(SamplingPolicy.shouldSample(last: last, now: earlier, visibility: .idle))
    }

    /// 长时间挂起后恢复（now 远大于 last）也应立即采样。
    func testLongSuspensionTriggersSample() {
        let last = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(SamplingPolicy.shouldSample(last: last, now: last.addingTimeInterval(600), visibility: .idle))
    }

    /// 每个会话的稳态 CPU 预算：单帧 19.5 ms × 频率，必须远低于 2%（空闲态）。
    func testIdleBudgetIsNegligible() {
        let frameMs = 19.5
        let idlePercent = frameMs / (SamplingPolicy.interval(for: .idle) * 1000) * 100
        XCTAssertLessThan(idlePercent, 0.5, "空闲态应低于 0.5% 单核")

        let menuPercent = frameMs / (SamplingPolicy.interval(for: .menuBarOnly) * 1000) * 100
        XCTAssertLessThan(menuPercent, 1.5, "仅菜单栏显示时应低于 1.5% 单核")
    }
}
