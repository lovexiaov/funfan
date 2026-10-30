import XCTest
@testable import FunFanCore

/// T9：规则引擎——阈值触发 + 迟滞 + 冲突取最大 + 安全下限联动。
///
/// 规则引擎必须「纯函数式可重放」：相同输入 + 相同内部状态 → 相同输出（Spec §5）。
final class RuleEngineTests: XCTestCase {

    private let limits = FanLimits(minRpm: 1000, maxRpm: 4900)

    // MARK: - 采样快照构造

    private func snapshot(cpu: Double, gpu: Double? = nil, key: String = "Tp01") -> SensorSnapshot {
        var readings: [SensorReading] = []
        if let descriptor = SensorCatalog.descriptor(for: key) {
            readings.append(SensorReading(descriptor: descriptor, celsius: cpu))
        }
        if let gpu, let descriptor = SensorCatalog.descriptor(for: "Tg0G") {
            readings.append(SensorReading(descriptor: descriptor, celsius: gpu))
        }
        return SensorSnapshot(readings: readings, timestamp: Date())
    }

    private func cpuRule(
        threshold: Double = 70,
        rpm: Double = 3000,
        hysteresis: Double = 2,
        comparator: RuleComparator = .greaterThanOrEqual,
        metric: Metric = .instant,
        enabled: Bool = true
    ) -> FanRule {
        FanRule(
            name: "CPU 高温",
            enabled: enabled,
            subject: .category(.cpu),
            metric: metric,
            comparator: comparator,
            thresholdCelsius: threshold,
            action: .setRpm(rpm),
            hysteresisCelsius: hysteresis
        )
    }

    // MARK: - 触发判定

    func testTriggersAtThresholdInclusive() {
        var engine = RuleEngine()
        let rule = cpuRule(threshold: 70, rpm: 3000)

        let result = engine.evaluate(snapshot: snapshot(cpu: 70), rules: [rule], limits: limits)

        XCTAssertEqual(result.commandedRpm!, 3000, accuracy: 1e-9)
        XCTAssertEqual(result.triggeredRuleIDs, [rule.id])
    }

    func testDoesNotTriggerBelowThreshold() {
        var engine = RuleEngine()
        let rule = cpuRule(threshold: 70, rpm: 3000)

        let result = engine.evaluate(snapshot: snapshot(cpu: 69.9), rules: [rule], limits: limits)

        XCTAssertNil(result.commandedRpm)
        XCTAssertTrue(result.triggeredRuleIDs.isEmpty)
    }

    func testGreaterThanIsStrict() {
        var engine = RuleEngine()
        let rule = cpuRule(threshold: 70, rpm: 3000, comparator: .greaterThan)

        XCTAssertNil(engine.evaluate(snapshot: snapshot(cpu: 70), rules: [rule], limits: limits).commandedRpm)
    }

    // MARK: - 迟滞

    func testHysteresisHoldsTriggerUntilDeadbandCleared() {
        var engine = RuleEngine()
        let rule = cpuRule(threshold: 70, rpm: 3000, hysteresis: 2)

        _ = engine.evaluate(snapshot: snapshot(cpu: 75), rules: [rule], limits: limits)   // 触发

        // 回落到 69：仍高于 70-2=68 → 保持触发，避免阈值边缘反复启停
        let held = engine.evaluate(snapshot: snapshot(cpu: 69), rules: [rule], limits: limits)
        XCTAssertEqual(held.commandedRpm!, 3000, accuracy: 1e-9)

        // 回落到 67.9：越过死区 → 解除
        let released = engine.evaluate(snapshot: snapshot(cpu: 67.9), rules: [rule], limits: limits)
        XCTAssertNil(released.commandedRpm)
        XCTAssertFalse(engine.isTriggered(rule.id))
    }

    func testLessThanRuleComparatorReleasesByHysteresisOnHighSide() {
        var engine = RuleEngine()
        let rule = FanRule(
            name: "低温",
            enabled: true,
            subject: .category(.gpu),
            metric: .instant,
            comparator: .lessThanOrEqual,
            thresholdCelsius: 45,
            action: .setRpm(1200),
            hysteresisCelsius: 2
        )

        XCTAssertEqual(
            engine.evaluate(snapshot: snapshot(cpu: 40, gpu: 45), rules: [rule], limits: limits).commandedRpm!,
            1200, accuracy: 1e-9
        )

        // 46：在死区（45+2=47）内 → 保持触发
        XCTAssertEqual(
            engine.evaluate(snapshot: snapshot(cpu: 40, gpu: 46), rules: [rule], limits: limits).commandedRpm!,
            1200, accuracy: 1e-9
        )

        // 47.1：越过死区 → 解除
        XCTAssertNil(engine.evaluate(snapshot: snapshot(cpu: 40, gpu: 47.1), rules: [rule], limits: limits).commandedRpm)
    }

    // MARK: - 冲突解析（安全优先：取最大 RPM）

    func testConflictingRulesTakeMaximumRpm() {
        var engine = RuleEngine()
        let mild = FanRule(
            name: "温和", enabled: true, subject: .category(.cpu), metric: .instant,
            comparator: .greaterThanOrEqual, thresholdCelsius: 60,
            action: .setRpm(2000), hysteresisCelsius: 2
        )
        let aggressive = FanRule(
            name: "激进", enabled: true, subject: .category(.cpu), metric: .instant,
            comparator: .greaterThanOrEqual, thresholdCelsius: 70,
            action: .setRpm(4000), hysteresisCelsius: 2
        )

        let result = engine.evaluate(snapshot: snapshot(cpu: 80), rules: [mild, aggressive], limits: limits)

        XCTAssertEqual(result.commandedRpm!, 4000, accuracy: 1e-9)
        XCTAssertEqual(Set(result.triggeredRuleIDs), Set([mild.id, aggressive.id]))
    }

    func testPercentActionResolvesAgainstMaxRpm() {
        var engine = RuleEngine()
        let rule = FanRule(
            name: "半速", enabled: true, subject: .category(.cpu), metric: .instant,
            comparator: .greaterThanOrEqual, thresholdCelsius: 70,
            action: .setPercent(50), hysteresisCelsius: 2
        )

        let result = engine.evaluate(snapshot: snapshot(cpu: 70), rules: [rule], limits: limits)

        XCTAssertEqual(result.commandedRpm!, 2450, accuracy: 1e-9)
    }

    // MARK: - 与 SafetyPolicy 联动

    func testLowRuleRpmIsRaisedToSafetyFloor() {
        var engine = RuleEngine()
        let rule = cpuRule(threshold: 50, rpm: 500)   // 低于系统最小 1000

        // 55℃ 时动态下限仍为系统最小 1000，规则值 500 必须被抬到 1000
        let result = engine.evaluate(snapshot: snapshot(cpu: 55), rules: [rule], limits: limits)

        XCTAssertEqual(result.commandedRpm!, 1000, accuracy: 1e-9, "规则不得把风扇压到系统下限以下")
    }

    /// 规则值低于「温度驱动的动态下限」时，也必须被抬升到下限。
    func testRuleRpmIsRaisedToDynamicFloor() {
        var engine = RuleEngine()
        let rule = cpuRule(threshold: 50, rpm: 1500)

        let result = engine.evaluate(snapshot: snapshot(cpu: 80), rules: [rule], limits: limits)
        let floor = SafetyPolicy.floorRpm(dieCelsius: 80, limits: limits)

        XCTAssertEqual(result.commandedRpm!, floor, accuracy: 1e-9)
        XCTAssertGreaterThan(result.commandedRpm!, 1500)
    }

    func testHighDieTempRaisesEvenCompliantRpm() {
        var engine = RuleEngine()
        let rule = cpuRule(threshold: 60, rpm: 2000)

        let result = engine.evaluate(snapshot: snapshot(cpu: 92), rules: [rule], limits: limits)

        XCTAssertGreaterThan(result.commandedRpm!, 4000, "92℃ 的安全下限应远高于规则值")
    }

    // MARK: - 边界

    func testNoRulesYieldsNil() {
        var engine = RuleEngine()
        XCTAssertNil(engine.evaluate(snapshot: snapshot(cpu: 90), rules: [], limits: limits).commandedRpm)
    }

    func testDisabledRuleIsIgnoredAndCleared() {
        var engine = RuleEngine()
        let rule = cpuRule(threshold: 70, rpm: 3000)

        _ = engine.evaluate(snapshot: snapshot(cpu: 80), rules: [rule], limits: limits)
        XCTAssertTrue(engine.isTriggered(rule.id))

        let disabled = cpuRule(threshold: 70, rpm: 3000, enabled: false)
        let result = engine.evaluate(snapshot: snapshot(cpu: 80), rules: [disabled], limits: limits)

        XCTAssertNil(result.commandedRpm)
        XCTAssertFalse(engine.isTriggered(rule.id))
    }

    func testMissingSensorDoesNotTriggerAndClearsState() {
        var engine = RuleEngine()
        let rule = cpuRule(threshold: 70, rpm: 3000)

        _ = engine.evaluate(snapshot: snapshot(cpu: 80), rules: [rule], limits: limits)
        XCTAssertTrue(engine.isTriggered(rule.id))

        // 空快照（SMC 读取失败）
        let empty = SensorSnapshot(readings: [], timestamp: Date())
        let result = engine.evaluate(snapshot: empty, rules: [rule], limits: limits)

        XCTAssertNil(result.commandedRpm)
        XCTAssertFalse(engine.isTriggered(rule.id))
    }

    func testSingleKeySubject() {
        var engine = RuleEngine()
        let rule = FanRule(
            name: "单键", enabled: true, subject: .key("Tp01"), metric: .instant,
            comparator: .greaterThanOrEqual, thresholdCelsius: 65,
            action: .setRpm(2500), hysteresisCelsius: 2
        )

        XCTAssertEqual(
            engine.evaluate(snapshot: snapshot(cpu: 66), rules: [rule], limits: limits).commandedRpm!,
            2500, accuracy: 1e-9
        )
        XCTAssertNil(engine.evaluate(snapshot: snapshot(cpu: 60, key: "Te05"), rules: [rule], limits: limits).commandedRpm)
    }

    func testPeakMetricUsesHottestSensor() {
        var engine = RuleEngine()
        let rule = cpuRule(threshold: 70, rpm: 3000, metric: .peak)

        let readings = [
            SensorCatalog.descriptor(for: "Tp01").map { SensorReading(descriptor: $0, celsius: 55) },
            SensorCatalog.descriptor(for: "Te05").map { SensorReading(descriptor: $0, celsius: 71) },
        ].compactMap { $0 }

        let result = engine.evaluate(
            snapshot: SensorSnapshot(readings: readings, timestamp: Date()),
            rules: [rule], limits: limits
        )

        // 均温 63 不会触发 70 阈值；peak 取最热的 71 才会触发
        XCTAssertEqual(result.commandedRpm!, 3000, accuracy: 1e-9, "peak 指标应取最热的核")
    }

    // MARK: - 确定性与持久化

    func testDeterministicReplay() {
        var a = RuleEngine()
        var b = RuleEngine()
        let rule = cpuRule()

        for celsius in [70.0, 75.0, 69.0, 68.0, 71.0] {
            let snap = snapshot(cpu: celsius)
            XCTAssertEqual(
                a.evaluate(snapshot: snap, rules: [rule], limits: limits),
                b.evaluate(snapshot: snap, rules: [rule], limits: limits)
            )
        }
    }

    func testRuleCodableRoundTrip() throws {
        let rule = cpuRule()
        let data = try JSONEncoder().encode(rule)
        let decoded = try JSONDecoder().decode(FanRule.self, from: data)

        XCTAssertEqual(decoded, rule)
    }

    func testRulesCollectionCodableRoundTrip() throws {
        let rules = [
            cpuRule(),
            FanRule(
                name: "半速", enabled: false, subject: .key("Tg0G"), metric: .peak,
                comparator: .lessThan, thresholdCelsius: 40,
                action: .setPercent(30), hysteresisCelsius: 1
            ),
        ]

        let data = try JSONEncoder().encode(rules)
        let decoded = try JSONDecoder().decode([FanRule].self, from: data)

        XCTAssertEqual(decoded, rules)
    }
}
