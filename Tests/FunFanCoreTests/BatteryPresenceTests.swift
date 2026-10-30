import XCTest
@testable import FunFanCore

/// 台式机（无电池）不得被误判为「有电池」。
///
/// 真机证据：Mac 台式机的 `AppleSmartBattery` 节点可能存在但容量全为 0
/// （`CycleCount = 0`、`Voltage = 0`），仅凭节点存在就判定 present 会显示一张空电池卡。
final class BatteryPresenceTests: XCTestCase {

    func testAllZeroPropertiesAreAbsent() {
        let props: [String: Any] = [
            "CurrentCapacity": 0,
            "MaxCapacity": 0,
            "AppleRawCurrentCapacity": 0,
            "AppleRawMaxCapacity": 0,
            "CycleCount": 0,
            "Amperage": 0,
            "Voltage": 0,
        ]

        let state = BatteryDetailParser.parse(props)

        XCTAssertFalse(state.present)
        XCTAssertNil(state.percentage)
        XCTAssertNil(state.cycleCount)
        XCTAssertNil(state.powerWatts)
    }

    func testCycleCountAloneIsNotEnough() {
        XCTAssertFalse(BatteryDetailParser.parse(["CycleCount": 0]).present)
        XCTAssertFalse(BatteryDetailParser.parse(["CycleCount": 12]).present)
    }

    func testDesignCapacityAloneIsNotEnoughWhenZero() {
        XCTAssertFalse(BatteryDetailParser.parse(["DesignCapacity": 0]).present)
    }

    /// 有容量即视为有电池——即使缺少循环次数等明细。
    func testPositiveCapacityMeansPresent() {
        let state = BatteryDetailParser.parse(["MaxCapacity": 100, "CurrentCapacity": 50])

        XCTAssertTrue(state.present)
        XCTAssertEqual(state.percentage!, 50, accuracy: 1e-9)
        XCTAssertNil(state.cycleCount)
    }
}
