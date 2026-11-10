import XCTest
@testable import FunFanCore

/// 调速依据温度：最高温 vs 平均温。
///
/// 这两个口径的差别不是「显示哪个数字」，而是**风扇按哪个温度动**：
/// 曲线插值和 `SafetyPolicy` 安全下限都吃同一个值，取错了就是转速整体偏一档。
/// 所以这里把口径本身钉住：最高温覆盖全部传感器（安全方向），
/// 均温只看 CPU/GPU 核心簇（调速方向，SSD/电池/环境不参与平均）。
final class TemperatureAggregationTests: XCTestCase {

    private let limits = FanLimits(minRpm: 1000, maxRpm: 4900)

    private func snapshot(_ pairs: [(String, Double)]) -> SensorSnapshot {
        let readings: [SensorReading] = pairs.compactMap { key, celsius in
            guard let descriptor = SensorCatalog.descriptor(for: key) else { return nil }
            return SensorReading(descriptor: descriptor, celsius: celsius)
        }
        return SensorSnapshot(readings: readings, timestamp: Date())
    }

    // MARK: - 口径

    func testPeakTakesHottestSensorOfAnyCategory() {
        let snap = snapshot([("Tp01", 62), ("Tg0G", 70), ("Ts0P", 88)])
        XCTAssertEqual(snap.controlCelsius(.peak), 88)
    }

    /// SSD / 环境这类非热源传感器不参与均温：它们键数不少、温度偏低，
    /// 混进平均会把「芯片均温」稀释掉，风扇该提速时不提速。
    func testAverageUsesCoreSensorsOnly() {
        let snap = snapshot([("Tp01", 62), ("Tg0G", 70), ("Ts0P", 88), ("TA0P", 20)])
        XCTAssertEqual(snap.controlCelsius(.average)!, 66, accuracy: 1e-9)
    }

    /// 没有 CPU/GPU 读数的机型（或刚唤醒那一帧）退到全量均温，而不是返回 nil
    /// 让风扇直接返还系统——那会在负载中突然掉转速。
    func testAverageFallsBackToAllReadingsWithoutCoreSensors() {
        let snap = snapshot([("Ts0P", 40), ("TA0P", 20)])
        XCTAssertEqual(snap.controlCelsius(.average)!, 30, accuracy: 1e-9)
    }

    func testEmptySnapshotHasNoControlTemperature() {
        let snap = SensorSnapshot(readings: [], timestamp: Date())
        XCTAssertNil(snap.controlCelsius(.peak))
        XCTAssertNil(snap.controlCelsius(.average))
    }

    /// rawValue 会落进用户 plist，改名等于让老用户的选择悄悄回落到最高温。
    func testRawValuesAreStable() {
        XCTAssertEqual(TemperatureAggregation.peak.rawValue, "peak")
        XCTAssertEqual(TemperatureAggregation.average.rawValue, "average")
        XCTAssertEqual(TemperatureAggregation.allCases, [.peak, .average])
    }

    // MARK: - 与安全下限联动

    /// 引擎的安全下限必须跟着用户选的口径走，否则「平均温度」形同虚设：
    /// 峰值 95℃ 把下限顶到 4900，平均口径画的曲线永远够不着。
    func testRuleEngineFloorFollowsChosenAggregation() {
        // CPU 95 + GPU 70：最高 95，核心均温 82.5
        let snap = snapshot([("Tp01", 95), ("Tg0G", 70)])
        let rule = FanRule(
            name: "CPU 高温",
            subject: .category(.cpu),
            metric: .peak,
            comparator: .greaterThanOrEqual,
            thresholdCelsius: 90,
            action: .setRpm(1100),
            hysteresisCelsius: 2
        )

        var peakEngine = RuleEngine()
        let peak = peakEngine.evaluate(
            snapshot: snap, rules: [rule], limits: limits, aggregation: .peak
        )
        XCTAssertEqual(peak.dieCelsius, 95)
        XCTAssertEqual(peak.commandedRpm!, SafetyPolicy.floorRpm(dieCelsius: 95, limits: limits), accuracy: 1e-9)

        var avgEngine = RuleEngine()
        let avg = avgEngine.evaluate(
            snapshot: snap, rules: [rule], limits: limits, aggregation: .average
        )
        XCTAssertEqual(avg.dieCelsius!, 82.5, accuracy: 1e-9)
        XCTAssertEqual(avg.commandedRpm!, SafetyPolicy.floorRpm(dieCelsius: 82.5, limits: limits), accuracy: 1e-9)
        XCTAssertLessThan(avg.commandedRpm!, peak.commandedRpm!, "同一条规则，均温口径必须更安静")
    }

    func testRuleAutomationForwardsAggregation() {
        let snap = snapshot([("Tp01", 95), ("Tg0G", 70)])
        var automation = RuleAutomation()
        _ = automation.update(
            snapshot: snap,
            rules: [],
            limits: limits,
            now: Date(),
            aggregation: .average
        )
        XCTAssertEqual(automation.dieCelsius!, 82.5, accuracy: 1e-9)

        automation.reset()
        _ = automation.update(
            snapshot: snap,
            rules: [],
            limits: limits,
            now: Date(),
            aggregation: .peak
        )
        XCTAssertEqual(automation.dieCelsius!, 95, accuracy: 1e-9)
    }
}
