import XCTest
@testable import FunFanCore

/// T7：安全策略——任何策略输出都必须经下限 clamp。
///
/// 安全语义（Spec §7）：只能比系统更激进，绝不允许低于系统下限、绝不允许 0 RPM。
/// 真机参考值：F0Mn=1000、F0Mx=4900。
final class SafetyPolicyTests: XCTestCase {

    private let limits = FanLimits(minRpm: 1000, maxRpm: 4900)

    // MARK: - 动态下限

    func testFloorAtLowTemperatureIsSystemMin() {
        XCTAssertEqual(SafetyPolicy.floorRpm(dieCelsius: 30, limits: limits), 1000, accuracy: 1e-9)
        XCTAssertEqual(SafetyPolicy.floorRpm(dieCelsius: 60, limits: limits), 1000, accuracy: 1e-9)
    }

    func testFloorAtHighTemperatureIsSystemMax() {
        XCTAssertEqual(SafetyPolicy.floorRpm(dieCelsius: 95, limits: limits), 4900, accuracy: 1e-9)
        XCTAssertEqual(SafetyPolicy.floorRpm(dieCelsius: 120, limits: limits), 4900, accuracy: 1e-9)
    }

    func testFloorInterpolatesLinearly() {
        // 60→1000, 95→4900，中点 77.5℃ 应为 2950
        XCTAssertEqual(SafetyPolicy.floorRpm(dieCelsius: 77.5, limits: limits), 2950, accuracy: 1e-6)
        // 80℃：1000 + 3900 × 20/35 ≈ 3228.57
        XCTAssertEqual(SafetyPolicy.floorRpm(dieCelsius: 80, limits: limits), 3228.571, accuracy: 0.01)
    }

    func testFloorNeverExceedsMaxWhenLimitsInverted() {
        // 机型返回异常（min > max）时不得产出越界下限
        let broken = FanLimits(minRpm: 4000, maxRpm: 2000)
        let floor = SafetyPolicy.floorRpm(dieCelsius: 99, limits: broken)
        XCTAssertEqual(floor, 4000, accuracy: 1e-9)
    }

    /// 传感器异常（NaN/∞）时退回系统下限，而不是把风扇拉满。
    func testFloorWithInvalidTemperatureFallsBackToMin() {
        XCTAssertEqual(SafetyPolicy.floorRpm(dieCelsius: .nan, limits: limits), 1000, accuracy: 1e-9)
        XCTAssertEqual(SafetyPolicy.floorRpm(dieCelsius: .infinity, limits: limits), 1000, accuracy: 1e-9)
    }

    // MARK: - clamp

    func testClampRaisesBelowFloorCommand() {
        // 用户/规则想把风扇压到 200，50℃ 下限 1000 → 必须抬到 1000
        XCTAssertEqual(SafetyPolicy.clamp(200, dieCelsius: 50, limits: limits), 1000, accuracy: 1e-9)
    }

    func testClampNeverReturnsZero() {
        XCTAssertEqual(SafetyPolicy.clamp(0, dieCelsius: 40, limits: limits), 1000, accuracy: 1e-9)
        XCTAssertEqual(SafetyPolicy.clamp(-500, dieCelsius: 40, limits: limits), 1000, accuracy: 1e-9)
        XCTAssertEqual(SafetyPolicy.clamp(.nan, dieCelsius: 40, limits: limits), 1000, accuracy: 1e-9)
    }

    func testClampCapsAtMax() {
        XCTAssertEqual(SafetyPolicy.clamp(9999, dieCelsius: 40, limits: limits), 4900, accuracy: 1e-9)
    }

    func testClampRespectsDynamicFloorAboveUserValue() {
        // 90℃ 下限 ≈ 4342.86，用户设 3000 必须被抬升
        let result = SafetyPolicy.clamp(3000, dieCelsius: 90, limits: limits)
        XCTAssertEqual(result, SafetyPolicy.floorRpm(dieCelsius: 90, limits: limits), accuracy: 1e-9)
        XCTAssertGreaterThan(result, 4000)
    }

    func testClampKeepsValueAboveFloor() {
        XCTAssertEqual(SafetyPolicy.clamp(4000, dieCelsius: 50, limits: limits), 4000, accuracy: 1e-9)
    }

    // MARK: - 合法性判定（helper 侧二次校验用）

    func testIsValidTarget() {
        XCTAssertTrue(SafetyPolicy.isValidTarget(1000, limits: limits))
        XCTAssertTrue(SafetyPolicy.isValidTarget(4900, limits: limits))
        XCTAssertFalse(SafetyPolicy.isValidTarget(0, limits: limits))
        XCTAssertFalse(SafetyPolicy.isValidTarget(999, limits: limits))
        XCTAssertFalse(SafetyPolicy.isValidTarget(4901, limits: limits))
        XCTAssertFalse(SafetyPolicy.isValidTarget(.nan, limits: limits))
    }
}
