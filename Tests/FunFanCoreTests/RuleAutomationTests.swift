import XCTest
@testable import FunFanCore

/// T15：自动化的「何时真正下发」策略。
///
/// 规则每 0.5 s 评估一次，但**不能每次都发 XPC**——否则等于给 helper 刷屏。
/// 契约：仅当目标变化超过死区、或到了重断言周期，才产生一次命令。
final class RuleAutomationTests: XCTestCase {

    private let limits = FanLimits(minRpm: 1000, maxRpm: 4900)
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func snapshot(cpu: Double, gpu: Double = 50) -> SensorSnapshot {
        var readings: [SensorReading] = []
        if let d = SensorCatalog.descriptor(for: "Tp01") {
            readings.append(SensorReading(descriptor: d, celsius: cpu))
        }
        if let d = SensorCatalog.descriptor(for: "Tg0G") {
            readings.append(SensorReading(descriptor: d, celsius: gpu))
        }
        return SensorSnapshot(readings: readings, timestamp: start)
    }

    private func cpuRule(threshold: Double = 70, percent: Double = 80) -> FanRule {
        FanRule(
            name: "CPU 高温",
            subject: .category(.cpu),
            comparator: .greaterThanOrEqual,
            thresholdCelsius: threshold,
            action: .setPercent(percent),
            hysteresisCelsius: 3
        )
    }

    // MARK: - 基本触发

    func testNoTriggerProducesNoCommand() {
        var automation = RuleAutomation()
        let command = automation.update(
            snapshot: snapshot(cpu: 50), rules: [cpuRule()], limits: limits, now: start
        )

        XCTAssertNil(command)
        XCTAssertNil(automation.lastCommandedRpm)
        XCTAssertFalse(automation.isActive)
    }

    func testFirstTriggerCommandsClampedRpm() {
        var automation = RuleAutomation()
        let command = automation.update(
            snapshot: snapshot(cpu: 72), rules: [cpuRule(percent: 80)], limits: limits, now: start
        )

        guard case .setRpm(let rpm)? = command else {
            return XCTFail("首次触发必须下发，实际：\(String(describing: command))")
        }
        XCTAssertEqual(rpm, 3920, accuracy: 1, "80% × 4900")
        XCTAssertEqual(automation.lastCommandedRpm, 3920)
        XCTAssertTrue(automation.isActive)
    }

    func testTriggerBelowSafetyFloorIsRaisedNotLowered() {
        var automation = RuleAutomation()
        let command = automation.update(
            snapshot: snapshot(cpu: 95), rules: [cpuRule(percent: 5)], limits: limits, now: start
        )

        guard case .setRpm(let rpm)? = command else { return XCTFail("应下发") }
        XCTAssertGreaterThan(rpm, 4900 * 0.05, "安全下限必须抬升规则值")
        XCTAssertLessThanOrEqual(rpm, 4900)
    }

    // MARK: - 节流

    func testRepeatedSameTargetWithinDeadbandIsSuppressed() {
        var automation = RuleAutomation()
        _ = automation.update(snapshot: snapshot(cpu: 72), rules: [cpuRule()], limits: limits, now: start)

        let second = automation.update(
            snapshot: snapshot(cpu: 73), rules: [cpuRule()], limits: limits,
            now: start.addingTimeInterval(0.5)
        )

        XCTAssertNil(second, "目标不变时不得反复下发")
    }

    func testTargetChangeBeyondDeadbandIsSent() {
        var automation = RuleAutomation(config: .init(deadbandRpm: 40, refreshInterval: 10))
        _ = automation.update(snapshot: snapshot(cpu: 72), rules: [cpuRule(percent: 80)], limits: limits, now: start)

        let second = automation.update(
            snapshot: snapshot(cpu: 80), rules: [cpuRule(percent: 95)], limits: limits,
            now: start.addingTimeInterval(1)
        )

        guard case .setRpm(let rpm)? = second else { return XCTFail("目标变化需下发") }
        XCTAssertEqual(rpm, 4655, accuracy: 1)
    }

    func testSameTargetIsReassertedAfterRefreshInterval() {
        var automation = RuleAutomation(config: .init(deadbandRpm: 40, refreshInterval: 10))
        _ = automation.update(snapshot: snapshot(cpu: 72), rules: [cpuRule()], limits: limits, now: start)

        let second = automation.update(
            snapshot: snapshot(cpu: 72), rules: [cpuRule()], limits: limits,
            now: start.addingTimeInterval(11)
        )

        guard case .setRpm(let rpm)? = second else {
            return XCTFail("超过重断言周期必须再发一次，防止 thermalmonitord 回收后无人重设")
        }
        XCTAssertEqual(rpm, 3920, accuracy: 1)
    }

    // MARK: - 解除

    func testReleaseWhenTemperatureDropsBelowDeadband() {
        var automation = RuleAutomation()
        _ = automation.update(snapshot: snapshot(cpu: 72), rules: [cpuRule()], limits: limits, now: start)

        let release = automation.update(
            snapshot: snapshot(cpu: 60), rules: [cpuRule()], limits: limits,
            now: start.addingTimeInterval(2)
        )

        XCTAssertEqual(release, .release, "跌破阈值 − 迟滞后必须返还系统自动")
        XCTAssertFalse(automation.isActive)

        let after = automation.update(
            snapshot: snapshot(cpu: 60), rules: [cpuRule()], limits: limits,
            now: start.addingTimeInterval(4)
        )
        XCTAssertNil(after, "解除只发一次")
    }

    func testHysteresisKeepsHoldingBetweenThresholds() {
        var automation = RuleAutomation()
        // 同一条规则（同一 UUID）——迟滞状态是按 ID 记的，换 ID 就是换规则。
        let rule = cpuRule()
        _ = automation.update(snapshot: snapshot(cpu: 72), rules: [rule], limits: limits, now: start)

        let hold = automation.update(
            snapshot: snapshot(cpu: 68), rules: [rule], limits: limits,
            now: start.addingTimeInterval(2)
        )

        XCTAssertNil(hold, "70 − 3 = 67，68℃ 仍应保持触发")
        XCTAssertTrue(automation.isActive)
    }

    func testDisablingRulesReleasesControl() {
        var automation = RuleAutomation()
        _ = automation.update(snapshot: snapshot(cpu: 72), rules: [cpuRule()], limits: limits, now: start)

        var disabled = cpuRule()
        disabled.enabled = false

        let release = automation.update(
            snapshot: snapshot(cpu: 72), rules: [disabled], limits: limits,
            now: start.addingTimeInterval(2)
        )

        XCTAssertEqual(release, .release)
        XCTAssertNil(automation.lastCommandedRpm)
    }

    func testEmptyRuleListReleasesControl() {
        var automation = RuleAutomation()
        _ = automation.update(snapshot: snapshot(cpu: 72), rules: [cpuRule()], limits: limits, now: start)

        let release = automation.update(
            snapshot: snapshot(cpu: 72), rules: [], limits: limits, now: start.addingTimeInterval(1)
        )

        XCTAssertEqual(release, .release)
    }

    // MARK: - 复位

    func testResetForgetsCommandedTarget() {
        var automation = RuleAutomation()
        _ = automation.update(snapshot: snapshot(cpu: 72), rules: [cpuRule()], limits: limits, now: start)

        automation.reset()

        XCTAssertNil(automation.lastCommandedRpm)
        XCTAssertFalse(automation.isActive)

        let again = automation.update(
            snapshot: snapshot(cpu: 72), rules: [cpuRule()], limits: limits,
            now: start.addingTimeInterval(1)
        )
        guard case .setRpm? = again else { return XCTFail("复位后应重新下发") }
    }

    // MARK: - 可观测性（UI 需要显示「哪条规则在生效」）

    func testExposesTriggeredRuleIDsAndDieTemperature() {
        var automation = RuleAutomation()
        let rule = cpuRule()
        _ = automation.update(snapshot: snapshot(cpu: 72), rules: [rule], limits: limits, now: start)

        XCTAssertEqual(automation.triggeredRuleIDs, [rule.id])
        XCTAssertEqual(automation.dieCelsius, 72)
    }
}
