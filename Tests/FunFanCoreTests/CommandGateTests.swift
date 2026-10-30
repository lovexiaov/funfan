import XCTest
@testable import FunFanCore

/// 命令闸门：死区 / 重断言 / 解除只发一次。
///
/// 这层是「算法算出目标」与「真的写硬件」之间的唯一闸口，
/// 它一旦漏判，风扇会被每秒一次的无意义写入刷出可听见的抖动。
final class CommandGateTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testFirstTargetIsSentImmediately() {
        var gate = ControlCommandGate()
        XCTAssertEqual(gate.update(target: 2000, now: t0), .setRpm(2000))
        XCTAssertTrue(gate.isActive)
    }

    func testSmallChangeIsSwallowed() {
        var gate = ControlCommandGate(config: .init(deadbandRpm: 40, refreshInterval: 10))
        _ = gate.update(target: 2000, now: t0)

        // 39 RPM 以内不发
        XCTAssertNil(gate.update(target: 2020, now: t0.addingTimeInterval(1)))
        XCTAssertNil(gate.update(target: 1980, now: t0.addingTimeInterval(2)))
        // 超过死区才发
        XCTAssertEqual(gate.update(target: 2060, now: t0.addingTimeInterval(3)), .setRpm(2060))
    }

    func testRefreshReassertsSameTarget() {
        var gate = ControlCommandGate(config: .init(deadbandRpm: 40, refreshInterval: 10))
        _ = gate.update(target: 2000, now: t0)

        // 目标没变、也没到周期 → 沉默
        XCTAssertNil(gate.update(target: 2000, now: t0.addingTimeInterval(9)))
        // 到周期 → 重发（thermalmonitord 可能已把模式改回自动）
        XCTAssertEqual(gate.update(target: 2000, now: t0.addingTimeInterval(10)), .setRpm(2000))
    }

    func testReleaseIsSentOnlyOnce() {
        var gate = ControlCommandGate()
        _ = gate.update(target: 2000, now: t0)

        XCTAssertEqual(gate.update(target: nil, now: t0.addingTimeInterval(1)), .release)
        XCTAssertFalse(gate.isActive)
        XCTAssertNil(gate.update(target: nil, now: t0.addingTimeInterval(2)))
        XCTAssertNil(gate.update(target: nil, now: t0.addingTimeInterval(30)))
    }

    func testNeverActiveNeverReleases() {
        var gate = ControlCommandGate()
        XCTAssertNil(gate.update(target: nil, now: t0))
    }

    func testResetForgetsEverything() {
        var gate = ControlCommandGate()
        _ = gate.update(target: 2000, now: t0)
        gate.reset()

        XCTAssertFalse(gate.isActive)
        // reset 后不能补发 release（否则切策略时会多写一次硬件）
        XCTAssertNil(gate.update(target: nil, now: t0.addingTimeInterval(1)))
        // 新目标按「首帧」处理，立即下发
        XCTAssertEqual(gate.update(target: 3000, now: t0.addingTimeInterval(2)), .setRpm(3000))
    }

    func testExternallyReleasedClearsWithoutEmitting() {
        var gate = ControlCommandGate()
        _ = gate.update(target: 2000, now: t0)
        gate.noteExternallyReleased()

        XCTAssertFalse(gate.isActive)
        XCTAssertNil(gate.update(target: nil, now: t0.addingTimeInterval(1)))
    }
}
