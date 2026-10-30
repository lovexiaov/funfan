import XCTest
@testable import FunFanCore

/// 传感器「粒度」语义：只有内置密钥表确认的键才算「逐核」，
/// 前缀回退发现的键只保证类别，不代表一个核（同一核常有多个探测点）。
final class SensorGranularityTests: XCTestCase {

    func testCuratedEntriesAreCoreLevel() {
        XCTAssertTrue(SensorCatalog.descriptor(for: "Tp01")!.isCoreLevel)
        XCTAssertTrue(SensorCatalog.descriptor(for: "Te05")!.isCoreLevel)
        XCTAssertTrue(SensorCatalog.descriptor(for: "Tg0G")!.isCoreLevel)
    }

    func testPrefixFallbackIsNotCoreLevel() {
        // 真实机型上存在大量未收录键（如 Tp0W/Tp3S/Te0V），不得伪造成「核」
        XCTAssertFalse(SensorCatalog.descriptor(for: "Tp0W")!.isCoreLevel)
        XCTAssertFalse(SensorCatalog.descriptor(for: "Tp3S")!.isCoreLevel)
        XCTAssertFalse(SensorCatalog.descriptor(for: "Te0V")!.isCoreLevel)
        // 但它们仍必须归到正确类别，才能参与均温
        XCTAssertEqual(SensorCatalog.descriptor(for: "Tp0W")!.category, .cpu)
        XCTAssertEqual(SensorCatalog.descriptor(for: "Tg0d")!.category, .gpu)
    }

    func testCoreLevelFilteringInSnapshot() {
        let readings = [
            reading("Tp01", 60),      // 收录 → 逐核
            reading("Tp0W", 70),      // 未收录 → 非逐核
            reading("Tp3S", 80),      // 未收录 → 非逐核
            reading("Tg0G", 50),
        ]
        let snapshot = SensorSnapshot(readings: readings, timestamp: Date())

        XCTAssertEqual(snapshot.coreLevelReadings(in: .cpu).count, 1)
        // 类别均温仍应包含全部传感器（不被粒度影响）
        XCTAssertEqual(snapshot.averageCPU()!, (60 + 70 + 80) / 3, accuracy: 1e-9)
    }

    func testClusterAverageIncludesAllSensorsOfSubcluster() {
        let readings = [
            reading("Te05", 50),      // 收录 E 核
            reading("Te0V", 60),      // 未收录，但前缀表明是 E 簇
        ]
        let snapshot = SensorSnapshot(readings: readings, timestamp: Date())

        let avg = snapshot.average(subcluster: .efficiency)
        XCTAssertEqual(avg!, 55, accuracy: 1e-9)
    }

    // MARK: - 辅助

    private func reading(_ key: String, _ celsius: Double) -> SensorReading {
        SensorReading(descriptor: SensorCatalog.descriptor(for: key)!, celsius: celsius)
    }
}
