import XCTest
@testable import FunFanCore

/// 传感器「粒度」语义（修复「展开 CPU/GPU 个数和实际对不上」后）：
/// SMC 温度键是「探测点」不是「核」。核心数由 `ChipTopology`（sysctl/IORegistry）提供，
/// 这里的断言只保证——① 归类正确可参与均温；② 展开分组列出真实键名、不编造核号；
/// ③ 簇内探测点数量 = 真实 SMC 键数量，绝不虚构。
final class SensorGranularityTests: XCTestCase {

    /// 前缀回退发现的键不得被伪装成「核」：其展示名必须是真实键名本身。
    func testFallbackKeyNameIsRealKey() {
        XCTAssertEqual(SensorCatalog.descriptor(for: "Tp0W")!.name, "Tp0W")
        XCTAssertEqual(SensorCatalog.descriptor(for: "Te0V")!.name, "Te0V")
        // 但仍归到正确类别，才能参与簇均温
        XCTAssertEqual(SensorCatalog.descriptor(for: "Tp0W")!.category, .cpu)
        XCTAssertEqual(SensorCatalog.descriptor(for: "Tp0W")!.subcluster, .performance)
        XCTAssertEqual(SensorCatalog.descriptor(for: "Tg0d")!.category, .gpu)
    }

    /// 内置表项仍正确归类到对应簇（不再用 isCoreLevel 标记「逐核」）。
    func testCuratedEntriesMappedToCorrectCluster() {
        XCTAssertEqual(SensorCatalog.descriptor(for: "Tp01")!.subcluster, .performance)
        XCTAssertEqual(SensorCatalog.descriptor(for: "Te05")!.subcluster, .efficiency)
        XCTAssertEqual(SensorCatalog.descriptor(for: "Tg0G")!.category, .gpu)
    }

    /// 簇均温必须包含该簇全部传感器（无论是否收录），不受「粒度」影响。
    func testClusterAverageIncludesAllSensorsOfSubcluster() {
        let readings = [
            reading("Te05", 50),      // 收录 E 核
            reading("Te0V", 60),      // 未收录，但前缀表明是 E 簇
        ]
        let snapshot = SensorSnapshot(readings: readings, timestamp: Date())
        let avg = snapshot.average(subcluster: .efficiency)
        XCTAssertEqual(avg!, 55, accuracy: 1e-9)
    }

    /// 核心保证：展开分组列出簇内真实探测点，数量 = 真实键数，键名不编造。
    func testCoreGroupsListAllClusterSensorsWithRealKeys() {
        let readings = [
            reading("Tp01", 60),
            reading("Tp0W", 70),
            reading("Tp3S", 80),
            reading("Te05", 55),
            reading("Tg0G", 50),
        ]
        let snapshot = SensorSnapshot(readings: readings, timestamp: Date())
        let groups = snapshot.coreGroups()

        let pGroup = groups.first { $0.id == "cpu-performance" }
        XCTAssertNotNil(pGroup, "P 簇应存在")
        // 3 个 Tp 探测点全部列出（含回退键），数量不再被「逐核」裁剪
        XCTAssertEqual(pGroup?.sensorCount, 3)
        let keys = (pGroup?.sensors.map { $0.key }) ?? []
        XCTAssertEqual(Set(keys), ["Tp01", "Tp0W", "Tp3S"])
        // 每个探测点都用真实键名，而非「P-Core 0」这类编造名
        XCTAssertFalse(keys.contains { $0.contains("Core") })
    }

    // MARK: - 辅助

    private func reading(_ key: String, _ celsius: Double) -> SensorReading {
        SensorReading(descriptor: SensorCatalog.descriptor(for: key)!, celsius: celsius)
    }
}
