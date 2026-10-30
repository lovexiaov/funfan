import XCTest
@testable import FunFanCore

/// T4：SensorCatalog 语义归类 + 动态枚举（纯逻辑，无需硬件）
final class SensorCatalogTests: XCTestCase {

    func testClassifyKnownPerformanceCore() {
        let d = SensorCatalog.descriptor(for: "Tp01")
        XCTAssertEqual(d?.key, "Tp01")
        XCTAssertEqual(d?.category, .cpu)
        XCTAssertEqual(d?.subcluster, .performance)
    }

    func testClassifyEfficiencyCore() {
        XCTAssertEqual(SensorCatalog.descriptor(for: "Te05")?.subcluster, .efficiency)
    }

    func testClassifySuperCluster() {
        XCTAssertEqual(SensorCatalog.descriptor(for: "Tp0O")?.subcluster, .superCluster)
    }

    func testClassifyGPU() {
        XCTAssertEqual(SensorCatalog.descriptor(for: "Tg0G")?.category, .gpu)
    }

    func testClassifyBatterySSDAmbientMemory() {
        XCTAssertEqual(SensorCatalog.descriptor(for: "TB0T")?.category, .battery)
        XCTAssertEqual(SensorCatalog.descriptor(for: "Ts0P")?.category, .ssd)
        XCTAssertEqual(SensorCatalog.descriptor(for: "TA0P")?.category, .ambient)
        XCTAssertEqual(SensorCatalog.descriptor(for: "Tm0P")?.category, .memory)
    }

    func testPrefixFallbackForUnlistedKeys() {
        XCTAssertEqual(SensorCatalog.descriptor(for: "Tg9Z")?.category, .gpu)
        XCTAssertEqual(SensorCatalog.descriptor(for: "Te9Z")?.subcluster, .efficiency)
    }

    func testUnknownTemperatureGoesToOther() {
        XCTAssertEqual(SensorCatalog.descriptor(for: "Tz9Z")?.category, .other)
    }

    func testNonTemperatureReturnsNil() {
        XCTAssertNil(SensorCatalog.descriptor(for: "F0Ac"))
        XCTAssertNil(SensorCatalog.descriptor(for: "PWRB"))
    }

    func testDescriptorsDeduplicatesFiltersAndSorts() {
        let keys = ["Tg0G", "Tp01", "Tp01", "F0Ac", "Te05"]
        let descs = SensorCatalog.descriptors(forKeys: keys)
        XCTAssertEqual(descs.map(\.key), ["Te05", "Tg0G", "Tp01"])
    }
}
