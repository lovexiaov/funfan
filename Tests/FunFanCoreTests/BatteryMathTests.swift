import XCTest
@testable import FunFanCore

/// T6：电量派生计算（纯逻辑）
final class BatteryMathTests: XCTestCase {

    func testPercentage() {
        XCTAssertEqual(BatteryMath.percentage(current: 87, max: 100)!, 87, accuracy: 1e-9)
        XCTAssertEqual(BatteryMath.percentage(current: 4350, max: 5000)!, 87, accuracy: 1e-9)
        XCTAssertNil(BatteryMath.percentage(current: nil, max: 100))
        XCTAssertNil(BatteryMath.percentage(current: 10, max: 0))
    }

    func testHealth() {
        XCTAssertEqual(BatteryMath.health(max: 4700, design: 5000)!, 94, accuracy: 1e-9)
        XCTAssertNil(BatteryMath.health(max: nil, design: 5000))
        XCTAssertNil(BatteryMath.health(max: 4700, design: 0))
    }

    func testPower() {
        XCTAssertEqual(BatteryMath.power(voltage: 12.3, amperage: 1.0)!, 12.3, accuracy: 1e-9)
        XCTAssertEqual(BatteryMath.power(voltage: 12.0, amperage: -0.5)!, -6.0, accuracy: 1e-9)
        XCTAssertNil(BatteryMath.power(voltage: nil, amperage: 1.0))
    }

    func testResolveMaxCapacityRawFirst() {
        XCTAssertEqual(BatteryMath.resolveMaxCapacity(raw: 4700, legacy: 4600), 4700)
        XCTAssertEqual(BatteryMath.resolveMaxCapacity(raw: nil, legacy: 4600), 4600)
        XCTAssertNil(BatteryMath.resolveMaxCapacity(raw: nil, legacy: nil))
    }

    func testAbsentBatteryState() {
        let s = BatteryState.absent
        XCTAssertFalse(s.present)
        XCTAssertNil(s.percentage)
    }
}
