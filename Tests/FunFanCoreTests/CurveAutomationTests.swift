import XCTest
@testable import FunFanCore

/// 曲线自动化：插值 → 安全下限 → 命令闸门。
final class CurveAutomationTests: XCTestCase {

    private let limits = FanLimits(minRpm: 1000, maxRpm: 4900)
    private let t0 = Date(timeIntervalSince1970: 2_000_000)

    /// 线性曲线：(40℃,1000) → (60,2000) → (80,4000) → (95,4900)
    private var linearCurve: FanCurve {
        FanCurve(points: [
            CurvePoint(celsius: 40, rpm: 1000),
            CurvePoint(celsius: 60, rpm: 2000),
            CurvePoint(celsius: 80, rpm: 4000),
            CurvePoint(celsius: 95, rpm: 4900),
        ])
    }

    func testFirstFrameGoesStraightToTarget() {
        var automation = CurveAutomation(curve: linearCurve)
        // 70℃ → 2000 + (4000-2000) * (10/20) = 3000，安全下限 70℃ 时为 2114
        let command = automation.update(
            curve: linearCurve, dieCelsius: 70, limits: limits,
            secondsElapsed: 1, now: t0
        )
        XCTAssertEqual(command, .setRpm(3000))
        XCTAssertEqual(automation.rawCurveRpm, 3000)
        XCTAssertEqual(automation.lastCommandedRpm, 3000)
    }

    /// 用户画一条「全程最小转速」的保守曲线，芯片 90℃ 时必须被安全下限抬上去。
    func testSafetyFloorOverridesConservativeCurve() {
        let flat = FanCurve(points: [
            CurvePoint(celsius: 30, rpm: 1000),
            CurvePoint(celsius: 100, rpm: 1000),
        ])
        var automation = CurveAutomation(curve: flat)
        let command = automation.update(
            curve: flat, dieCelsius: 90, limits: limits,
            secondsElapsed: 1, now: t0
        )

        // floor(90) = 1000 + 3900 * (90-60)/(95-60) ≈ 4342.86
        let expected = SafetyPolicy.floorRpm(dieCelsius: 90, limits: limits)
        guard case .setRpm(let rpm) = command else {
            return XCTFail("应下发转速，实际为 \(String(describing: command))")
        }
        XCTAssertEqual(rpm, expected, accuracy: 0.001)
        // 曲线本身给的仍是 1000——UI 要能同时显示「曲线给的」和「实际下发的」
        XCTAssertEqual(automation.rawCurveRpm, 1000)
        XCTAssertGreaterThan(rpm, automation.rawCurveRpm ?? 0)
    }

    /// 没有温度（首帧还没采到 / 传感器全丢）时必须返还系统，而不是猜一个转速。
    func testMissingTemperatureReleasesInsteadOfGuessing() {
        var automation = CurveAutomation(curve: linearCurve)
        _ = automation.update(
            curve: linearCurve, dieCelsius: 70, limits: limits, secondsElapsed: 1, now: t0
        )
        let command = automation.update(
            curve: linearCurve, dieCelsius: nil, limits: limits,
            secondsElapsed: 1, now: t0.addingTimeInterval(1)
        )
        XCTAssertEqual(command, .release)
        XCTAssertNil(automation.rawCurveRpm)
    }

    func testEmptyCurveReleases() {
        var automation = CurveAutomation(curve: linearCurve)
        _ = automation.update(
            curve: linearCurve, dieCelsius: 70, limits: limits, secondsElapsed: 1, now: t0
        )
        let command = automation.update(
            curve: FanCurve(points: []), dieCelsius: 70, limits: limits,
            secondsElapsed: 1, now: t0.addingTimeInterval(1)
        )
        XCTAssertEqual(command, .release)
    }

    /// 首帧直达，之后受斜率限制：避免温度跳变时听到「加速哨音」。
    func testSlewRateLimitsAfterFirstFrame() {
        var automation = CurveAutomation(curve: linearCurve, slewRateRpmPerSecond: 400)
        _ = automation.update(
            curve: linearCurve, dieCelsius: 70, limits: limits, secondsElapsed: 1, now: t0
        )

        // 80℃：曲线给 4000，安全下限 3228 —— 下限没有压过斜率，斜率生效
        let command = automation.update(
            curve: linearCurve, dieCelsius: 80, limits: limits,
            secondsElapsed: 1, now: t0.addingTimeInterval(1)
        )
        guard case .setRpm(let rpm) = command else {
            return XCTFail("应下发转速")
        }
        // 允许的最大变化 = 400 RPM/s × 1 s
        XCTAssertLessThanOrEqual(rpm, 3000 + 400 + 1e-9)
        XCTAssertGreaterThan(rpm, 3000)
    }

    /// 安全下限优先于斜率限制：95℃ 时不允许「慢慢爬」，必须立刻满转。
    func testSafetyFloorBeatsSlewRate() {
        var automation = CurveAutomation(curve: linearCurve, slewRateRpmPerSecond: 400)
        _ = automation.update(
            curve: linearCurve, dieCelsius: 70, limits: limits, secondsElapsed: 1, now: t0
        )

        let command = automation.update(
            curve: linearCurve, dieCelsius: 95, limits: limits,
            secondsElapsed: 1, now: t0.addingTimeInterval(1)
        )
        XCTAssertEqual(command, .setRpm(4900), "95℃ 必须立刻满转，不能被斜率拖住")
    }

    /// 曲线变化立即生效：用户在编辑器里拖动后，下一帧就该按新曲线算。
    func testCurveEditTakesEffectOnNextFrame() {
        var automation = CurveAutomation(curve: linearCurve)
        _ = automation.update(
            curve: linearCurve, dieCelsius: 70, limits: limits, secondsElapsed: 1, now: t0
        )

        let steep = FanCurve(points: [
            CurvePoint(celsius: 40, rpm: 1000),
            CurvePoint(celsius: 95, rpm: 4900),
        ])
        let command = automation.update(
            curve: steep, dieCelsius: 70, limits: limits,
            secondsElapsed: 30, now: t0.addingTimeInterval(30)   // 30 s 足够爬到任何目标
        )
        // 70℃ 插值 = 1000 + 3900 * (30/55) ≈ 3127.27
        XCTAssertEqual(automation.rawCurveRpm ?? 0, 3127.27, accuracy: 0.01)
        guard case .setRpm(let rpm) = command else { return XCTFail("应下发转速") }
        XCTAssertEqual(rpm, automation.rawCurveRpm ?? 0, accuracy: 0.001)
    }

    func testResetMakesNextFrameDirect() {
        var automation = CurveAutomation(curve: linearCurve, slewRateRpmPerSecond: 100)
        _ = automation.update(
            curve: linearCurve, dieCelsius: 70, limits: limits, secondsElapsed: 1, now: t0
        )
        automation.reset()
        XCTAssertFalse(automation.isActive)

        let command = automation.update(
            curve: linearCurve, dieCelsius: 70, limits: limits,
            secondsElapsed: 1, now: t0.addingTimeInterval(1)
        )
        XCTAssertEqual(command, .setRpm(3000))   // 不再受上次输出约束
    }
}
