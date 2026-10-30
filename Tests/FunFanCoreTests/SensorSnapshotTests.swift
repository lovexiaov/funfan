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
}
