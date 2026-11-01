import XCTest
@testable import FunFanCore

/// T4：SensorSnapshot 按类别求均温
final class SensorSnapshotTests: XCTestCase {

    private func reading(_ key: String, _ celsius: Double) -> SensorReading {
        guard let d = SensorCatalog.descriptor(for: key) else {
            fatalError("unexpected non-temp key \(key)")
        }
        return SensorReading(descriptor: d, celsius: celsius)
    }

    func testAverageByCategory() {
        let snap = SensorSnapshot(
            readings: [
                reading("Tp01", 70), reading("Tp09", 80), reading("Te05", 60),
                reading("Tg0G", 50), reading("Tg0H", 54),
            ],
            timestamp: Date(timeIntervalSince1970: 0)
        )
        XCTAssertEqual(snap.average(for: .cpu)!, 70.0, accuracy: 1e-9)
        XCTAssertEqual(snap.average(for: .gpu)!, 52.0, accuracy: 1e-9)
        XCTAssertNil(snap.average(for: .ssd))
    }

    func testPerCoreListing() {
        let snap = SensorSnapshot(
            readings: [reading("Tp01", 70), reading("Tp09", 80), reading("Tg0G", 50)],
            timestamp: Date(timeIntervalSince1970: 0)
        )
        XCTAssertEqual(snap.readings(in: .cpu).count, 2)
        XCTAssertEqual(snap.readings(in: .gpu).count, 1)
    }

    // MARK: - 可用性三态（区分「这台机器没有」与「暂时没读数」）

    /// 有该类别传感器 → `.available`，值就是均温。
    func testAvailabilityAvailableWhenCategoryHasReadings() {
        let snap = SensorSnapshot(
            readings: [reading("TA0P", 28), reading("TA1P", 30)],
            timestamp: Date(timeIntervalSince1970: 0)
        )
        guard case .available(let value) = snap.availability(for: .ambient, sensorCount: 2) else {
            return XCTFail("ambient 有读数时应为 available")
        }
        XCTAssertEqual(value, 29.0, accuracy: 1e-9)
    }

    /// 键表确认该类别有 0 个键 → `.unsupported`。
    /// 这是本机 Mac mini M4 的真实情形：180 个温度键里 `TA*` 一个都没有。
    func testAvailabilityUnsupportedWhenMachineHasNoSuchSensor() {
        let snap = SensorSnapshot(
            readings: [reading("Tp01", 70), reading("Tg0G", 50), reading("Ts0P", 40)],
            timestamp: Date(timeIntervalSince1970: 0)
        )
        XCTAssertEqual(snap.availability(for: .ambient, sensorCount: 0), .unsupported)
        XCTAssertEqual(snap.availability(for: .battery, sensorCount: 0), .unsupported)
    }

    /// **有键但本帧没读到**（睡眠唤醒偶发超时、读数越界被过滤）→ `.pending`。
    /// 这里不能判成 `unsupported`，否则唤醒瞬间会误报「无传感器」、下一帧又跳回数值。
    func testAvailabilityPendingWhenSensorExistsButFrameMissedIt() {
        let snap = SensorSnapshot(
            readings: [reading("Tp01", 70)],
            timestamp: Date(timeIntervalSince1970: 0)
        )
        XCTAssertEqual(snap.availability(for: .ambient, sensorCount: 3), .pending)
    }

    /// 键表还没枚举（`sensorCount == nil`）→ `.pending`，不下「没有」的结论。
    func testAvailabilityPendingBeforeKeyTableKnown() {
        let snap = SensorSnapshot(
            readings: [reading("Tp01", 70)],
            timestamp: Date(timeIntervalSince1970: 0)
        )
        XCTAssertEqual(snap.availability(for: .ambient, sensorCount: nil), .pending)
        let empty = SensorSnapshot(readings: [], timestamp: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(empty.availability(for: .ambient, sensorCount: nil), .pending)
    }

    /// 其它类别不受影响：有 CPU 就 `available`，缺 SSD 才 `unsupported`。
    func testAvailabilityIsPerCategory() {
        let snap = SensorSnapshot(
            readings: [reading("Tp01", 68), reading("TA0P", 27)],
            timestamp: Date(timeIntervalSince1970: 0)
        )
        XCTAssertEqual(snap.availability(for: .cpu, sensorCount: 1), .available(68))
        XCTAssertEqual(snap.availability(for: .ssd, sensorCount: 0), .unsupported)
    }
}
