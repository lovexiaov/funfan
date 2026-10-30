import XCTest
@testable import FunFanCore

/// T6 剩余：`AppleSmartBattery` 明细解析（健康度/循环/电流/电压/温度）。
///
/// 解析器为纯函数，测试用真实 ioreg 形态的字典驱动，不依赖本机是否有电池。
final class BatteryDetailTests: XCTestCase {

    private func appleSiliconProperties() -> [String: Any] {
        [
            "CurrentCapacity": 4350,
            "MaxCapacity": 4700,
            "AppleRawCurrentCapacity": 4350,
            "AppleRawMaxCapacity": 4700,
            "DesignCapacity": 5000,
            "CycleCount": 123,
            "Amperage": -850,          // mA，放电为负
            "Voltage": 12300,          // mV
            "Temperature": 3030,       // 0.1 K
            "IsCharging": false,
            "ExternalConnected": false,
        ]
    }

    func testParsesFullAppleSiliconProperties() {
        let state = BatteryDetailParser.parse(appleSiliconProperties())

        XCTAssertTrue(state.present)
        XCTAssertEqual(state.percentage!, 92.55, accuracy: 0.01)
        XCTAssertEqual(state.health!, 94.0, accuracy: 0.01)
        XCTAssertEqual(state.cycleCount, 123)
        XCTAssertEqual(state.amperage!, -0.85, accuracy: 1e-6)     // mA → A
        XCTAssertEqual(state.voltage!, 12.3, accuracy: 1e-6)       // mV → V
        XCTAssertEqual(state.powerWatts!, -10.455, accuracy: 1e-3)
        XCTAssertEqual(state.temperatureCelsius!, 29.85, accuracy: 0.01)
        XCTAssertFalse(state.isCharging)
        XCTAssertFalse(state.externalConnected)
        XCTAssertEqual(state.designCapacity!, 5000, accuracy: 1e-9)
    }

    func testPrefersRawCapacityKeys() {
        var props = appleSiliconProperties()
        props["AppleRawMaxCapacity"] = 5000   // 与旧键不同，应取 raw
        props["AppleRawCurrentCapacity"] = 2500

        let state = BatteryDetailParser.parse(props)

        XCTAssertEqual(state.maxCapacity!, 5000, accuracy: 1e-9)
        XCTAssertEqual(state.currentCapacity!, 2500, accuracy: 1e-9)
        XCTAssertEqual(state.percentage!, 50.0, accuracy: 0.01)
        XCTAssertEqual(state.health!, 100.0, accuracy: 0.01)
    }

    func testFallsBackToLegacyCapacityKeys() {
        let props: [String: Any] = [
            "CurrentCapacity": 2000,
            "MaxCapacity": 4000,
            "DesignCapacity": 5000,
        ]

        let state = BatteryDetailParser.parse(props)

        XCTAssertEqual(state.percentage!, 50.0, accuracy: 0.01)
        XCTAssertEqual(state.health!, 80.0, accuracy: 0.01)
        XCTAssertNil(state.cycleCount)
        XCTAssertNil(state.amperage)
    }

    func testEmptyPropertiesYieldsAbsent() {
        XCTAssertFalse(BatteryDetailParser.parse([:]).present)
        XCTAssertNil(BatteryDetailParser.parse([:]).percentage)
    }

    func testChargingFlags() {
        var props = appleSiliconProperties()
        props["IsCharging"] = true
        props["ExternalConnected"] = true
        props["Amperage"] = 1200

        let state = BatteryDetailParser.parse(props)

        XCTAssertTrue(state.isCharging)
        XCTAssertTrue(state.externalConnected)
        XCTAssertEqual(state.powerWatts!, 14.76, accuracy: 0.01)
    }

    // MARK: - 温度单位启发式

    func testTemperatureDeciKelvin() {
        XCTAssertEqual(BatteryDetailParser.temperatureCelsius(fromRaw: 3030)!, 29.85, accuracy: 0.01)
    }

    func testTemperatureKelvin() {
        XCTAssertEqual(BatteryDetailParser.temperatureCelsius(fromRaw: 310.15)!, 37.0, accuracy: 0.01)
    }

    func testTemperatureAlreadyCelsius() {
        XCTAssertEqual(BatteryDetailParser.temperatureCelsius(fromRaw: 35)!, 35.0, accuracy: 0.01)
    }

    func testTemperatureNilAndZero() {
        XCTAssertNil(BatteryDetailParser.temperatureCelsius(fromRaw: nil))
        XCTAssertNil(BatteryDetailParser.temperatureCelsius(fromRaw: 0))
    }

    /// 电池温度必须落在合理区间，异常值直接丢弃（避免 UI 显示 -240℃）。
    func testTemperatureRejectsImplausible() {
        XCTAssertNil(BatteryDetailParser.temperatureCelsius(fromRaw: 1))
    }
}
