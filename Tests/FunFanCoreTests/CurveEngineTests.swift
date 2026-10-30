import XCTest
@testable import FunFanCore

/// T8：曲线引擎——插值 + 迟滞 + 斜率限制。
final class CurveEngineTests: XCTestCase {

    /// (40℃→1000)、(70℃→3000)、(95℃→4900)
    private var curve: FanCurve {
        FanCurve(points: [
            CurvePoint(celsius: 40, rpm: 1000),
            CurvePoint(celsius: 70, rpm: 3000),
            CurvePoint(celsius: 95, rpm: 4900),
        ])
    }

    // MARK: - 插值（FanCurve 纯函数）

    func testExactPoints() {
        XCTAssertEqual(curve.rpm(at: 40)!, 1000, accuracy: 1e-9)
        XCTAssertEqual(curve.rpm(at: 70)!, 3000, accuracy: 1e-9)
        XCTAssertEqual(curve.rpm(at: 95)!, 4900, accuracy: 1e-9)
    }

    func testLinearInterpolationBetweenPoints() {
        XCTAssertEqual(curve.rpm(at: 55)!, 2000, accuracy: 1e-9)      // 中点
        XCTAssertEqual(curve.rpm(at: 82.5)!, 3950, accuracy: 1e-9)    // 70–95 中点
        XCTAssertEqual(curve.rpm(at: 43)!, 1200, accuracy: 1e-9)      // 40–70 的 3/30
    }

    func testClampsOutsideRange() {
        XCTAssertEqual(curve.rpm(at: -10)!, 1000, accuracy: 1e-9)
        XCTAssertEqual(curve.rpm(at: 150)!, 4900, accuracy: 1e-9)
    }

    func testEmptyCurveReturnsNil() {
        XCTAssertNil(FanCurve(points: []).rpm(at: 60))
    }

    func testUnsortedPointsAreSorted() {
        let messy = FanCurve(points: [
            CurvePoint(celsius: 95, rpm: 4900),
            CurvePoint(celsius: 40, rpm: 1000),
            CurvePoint(celsius: 70, rpm: 3000),
        ])
        XCTAssertEqual(messy.points.map(\.celsius), [40, 70, 95])
        XCTAssertEqual(messy.rpm(at: 55)!, 2000, accuracy: 1e-9)
    }

    func testSinglePointCurveIsConstant() {
        let flat = FanCurve(points: [CurvePoint(celsius: 60, rpm: 2500)])
        XCTAssertEqual(flat.rpm(at: 20)!, 2500, accuracy: 1e-9)
        XCTAssertEqual(flat.rpm(at: 99)!, 2500, accuracy: 1e-9)
    }

    // MARK: - 斜率限制

    func testFirstUpdateJumpsDirectlyToTarget() {
        var engine = CurveEngine(curve: curve, slewRateRpmPerSecond: 400, hysteresisCelsius: 2)
        // 首次不应从 0 缓慢爬升，否则开机后要等十几秒才到位
        XCTAssertEqual(engine.update(celsius: 95, secondsElapsed: 1)!, 4900, accuracy: 1e-9)
    }

    func testSlewRateLimitsRise() {
        var engine = CurveEngine(curve: curve, slewRateRpmPerSecond: 400, hysteresisCelsius: 2)
        _ = engine.update(celsius: 40, secondsElapsed: 1)          // 1000

        let next = engine.update(celsius: 95, secondsElapsed: 1)!   // 目标 4900，但 1s 只允许 +400
        XCTAssertEqual(next, 1400, accuracy: 1e-9)

        let next2 = engine.update(celsius: 95, secondsElapsed: 1)!
        XCTAssertEqual(next2, 1800, accuracy: 1e-9)
    }

    func testSlewRateScalesWithElapsedTime() {
        var engine = CurveEngine(curve: curve, slewRateRpmPerSecond: 400, hysteresisCelsius: 2)
        _ = engine.update(celsius: 40, secondsElapsed: 1)

        let next = engine.update(celsius: 95, secondsElapsed: 2.5)!
        XCTAssertEqual(next, 2000, accuracy: 1e-9)   // 400 × 2.5 = 1000
    }

    // MARK: - 迟滞

    func testSmallCoolingWithinDeadbandHoldsOutput() {
        var engine = CurveEngine(curve: curve, slewRateRpmPerSecond: 4000, hysteresisCelsius: 2)
        XCTAssertEqual(engine.update(celsius: 70, secondsElapsed: 1)!, 3000, accuracy: 1e-9)

        // 69℃：曲线目标 2933，但跌幅未超过 2℃ 死区 → 保持 3000，避免阈值边缘抖动
        XCTAssertEqual(engine.update(celsius: 69, secondsElapsed: 1)!, 3000, accuracy: 1e-9)
    }

    func testCoolingBeyondDeadbandFollowsCurve() {
        var engine = CurveEngine(curve: curve, slewRateRpmPerSecond: 4000, hysteresisCelsius: 2)
        _ = engine.update(celsius: 70, secondsElapsed: 1)          // 3000

        let cooled = engine.update(celsius: 67, secondsElapsed: 1)!
        XCTAssertEqual(cooled, 2800, accuracy: 1e-9)               // 曲线(67)
    }

    func testHeatingIsNotDelayedByHysteresis() {
        var engine = CurveEngine(curve: curve, slewRateRpmPerSecond: 4000, hysteresisCelsius: 2)
        _ = engine.update(celsius: 70, secondsElapsed: 1)

        let heated = engine.update(celsius: 71, secondsElapsed: 1)!
        // 70→95 段斜率 1900/25 = 76 RPM/℃，故 71℃ 目标 3076
        XCTAssertEqual(heated, 3076, accuracy: 0.01)               // 立即跟随，安全优先
    }

    func testEmptyCurveYieldsNil() {
        var engine = CurveEngine(curve: FanCurve(points: []))
        XCTAssertNil(engine.update(celsius: 70, secondsElapsed: 1))
    }

    /// 同输入同状态 → 同输出（可重放，Spec §5 确定性要求）。
    func testDeterministicReplay() {
        var a = CurveEngine(curve: curve, slewRateRpmPerSecond: 400, hysteresisCelsius: 2)
        var b = CurveEngine(curve: curve, slewRateRpmPerSecond: 400, hysteresisCelsius: 2)

        for celsius in [40.0, 60.0, 80.0, 95.0, 70.0, 65.0] {
            XCTAssertEqual(
                a.update(celsius: celsius, secondsElapsed: 0.5),
                b.update(celsius: celsius, secondsElapsed: 0.5)
            )
        }
    }
}
