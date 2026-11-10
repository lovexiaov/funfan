import XCTest
import FunFanCore

/// 控制策略与固定转速的持久化契约。
///
/// 为什么值得测：这两个值决定重启后风扇怎么跑。写错了不会崩，只会「看起来恢复了、
/// 其实回到自动」，而这正是最难被用户描述清楚的一类 bug。
final class ControlPreferencesTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "FunFanCoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        XCTAssertNotNil(defaults, "测试用 suite 必须能创建")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - 默认值

    func testEmptyStoreFallsBackToAutomaticAndDefaultRpm() {
        let prefs = ControlPreferences(defaults: defaults)
        XCTAssertEqual(prefs.strategy, .automatic)
        XCTAssertEqual(prefs.fixedRpm, ControlPreferences.defaultFixedRpm)
    }

    // MARK: - 往返

    func testStrategyAndRpmSurviveNewInstance() {
        let prefs = ControlPreferences(defaults: defaults)
        prefs.strategy = .fixed
        prefs.fixedRpm = 3200

        // 模拟重启：同一份 defaults 上重建对象
        let reloaded = ControlPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.strategy, .fixed)
        XCTAssertEqual(reloaded.fixedRpm, 3200)
    }

    func testEveryStrategyRoundTrips() {
        for strategy in ControlStrategy.allCases {
            let prefs = ControlPreferences(defaults: defaults)
            prefs.strategy = strategy
            XCTAssertEqual(ControlPreferences(defaults: defaults).strategy, strategy)
        }
    }

    // MARK: - 脏值

    func testUnknownStrategyFallsBackToAutomatic() {
        defaults.set("turbo", forKey: ControlPreferences.strategyKey)
        XCTAssertEqual(ControlPreferences(defaults: defaults).strategy, .automatic)
    }

    func testNonStringStrategyFallsBackToAutomatic() {
        defaults.set(42, forKey: ControlPreferences.strategyKey)
        XCTAssertEqual(ControlPreferences(defaults: defaults).strategy, .automatic)
    }

    func testInvalidRpmFallsBackToDefault() {
        for dirty in [0.0, -1200.0, Double.nan, Double.infinity] {
            defaults.set(dirty, forKey: ControlPreferences.fixedRpmKey)
            XCTAssertEqual(
                ControlPreferences(defaults: defaults).fixedRpm,
                ControlPreferences.defaultFixedRpm,
                "脏值 \(dirty) 不应被当成转速"
            )
        }
    }

    /// 区间收敛交给 ControlStore（要等 helper 报出真实区间），这里只保证原样读回，
    /// 免得不同机型上存过的 6000 RPM 在还没连上 helper 时就被砍成 4900。
    func testOutOfDefaultRangeRpmIsPreserved() {
        defaults.set(6200.0, forKey: ControlPreferences.fixedRpmKey)
        XCTAssertEqual(ControlPreferences(defaults: defaults).fixedRpm, 6200)
    }

    // MARK: - 调速依据

    func testTemperatureAggregationDefaultsToPeak() {
        XCTAssertEqual(ControlPreferences(defaults: defaults).temperatureAggregation, .peak)
    }

    func testTemperatureAggregationSurvivesNewInstance() {
        ControlPreferences(defaults: defaults).temperatureAggregation = .average
        XCTAssertEqual(ControlPreferences(defaults: defaults).temperatureAggregation, .average)
    }

    func testUnknownTemperatureAggregationFallsBackToPeak() {
        defaults.set("median", forKey: ControlPreferences.temperatureAggregationKey)
        XCTAssertEqual(ControlPreferences(defaults: defaults).temperatureAggregation, .peak)
    }

    // MARK: - 兼容性契约

    /// rawValue 会写进用户 plist，改名等于让老用户的选择回落到自动。
    func testRawValuesAreStable() {
        XCTAssertEqual(ControlStrategy.automatic.rawValue, "automatic")
        XCTAssertEqual(ControlStrategy.fixed.rawValue, "fixed")
        XCTAssertEqual(ControlStrategy.curve.rawValue, "curve")
        XCTAssertEqual(ControlStrategy.rules.rawValue, "rules")
    }

    func testKeysAreNamespaced() {
        XCTAssertEqual(ControlPreferences.strategyKey, "FunFan.controlStrategy")
        XCTAssertEqual(ControlPreferences.fixedRpmKey, "FunFan.fixedRpm")
        XCTAssertEqual(ControlPreferences.temperatureAggregationKey, "FunFan.temperatureAggregation")
    }

    func testAutomatedStrategies() {
        XCTAssertTrue(ControlStrategy.curve.isAutomated)
        XCTAssertTrue(ControlStrategy.rules.isAutomated)
        XCTAssertFalse(ControlStrategy.automatic.isAutomated)
        XCTAssertFalse(ControlStrategy.fixed.isAutomated)
    }
}
