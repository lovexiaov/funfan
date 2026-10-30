import XCTest
@testable import FunFanCore

/// T4 剩余：SMC 全键枚举（三级回退的第 2 级——不依赖候选列表，覆盖任意机型）。
final class SMCKeyEnumerationTests: XCTestCase {

    // MARK: - 枚举驱动（纯逻辑，注入 count/keyAt）

    func testEnumeratesAllKeysByIndex() throws {
        let pool = ["#KEY", "Tp01", "Te05", "F0Ac", "Tg0G"]

        let keys = try SMCKeyEnumeration.allKeys(
            keyCount: { pool.count },
            keyAt: { pool[$0] }
        )

        XCTAssertEqual(keys, pool)
    }

    func testCallsKeyAtIndexExactlyCountTimes() throws {
        var calls = 0
        _ = try SMCKeyEnumeration.allKeys(
            keyCount: { 4 },
            keyAt: { index in
                calls += 1
                return "K00\(index)"
            }
        )
        XCTAssertEqual(calls, 4)
    }

    func testZeroCountYieldsEmpty() throws {
        let keys = try SMCKeyEnumeration.allKeys(keyCount: { 0 }, keyAt: { _ in "XXXX" })
        XCTAssertTrue(keys.isEmpty)
    }

    func testNegativeCountYieldsEmpty() throws {
        let keys = try SMCKeyEnumeration.allKeys(keyCount: { -5 }, keyAt: { _ in "XXXX" })
        XCTAssertTrue(keys.isEmpty)
    }

    func testPropagatesKeyCountError() {
        struct Boom: Error {}
        XCTAssertThrowsError(
            try SMCKeyEnumeration.allKeys(keyCount: { throw Boom() }, keyAt: { _ in "XXXX" })
        )
    }

    /// 个别索引读失败时应跳过该项而不是整体失败（真机上存在残留/无效槽位）。
    func testSkipsFailingIndexes() throws {
        struct Boom: Error {}
        let keys = try SMCKeyEnumeration.allKeys(
            keyCount: { 4 },
            keyAt: { index in
                if index == 1 { throw Boom() }
                return "T00\(index)"
            }
        )
        XCTAssertEqual(keys, ["T000", "T002", "T003"])
    }

    // MARK: - 温度键筛选

    func testFiltersTemperatureKeys() {
        let allKeys = [
            "#KEY", "Tp01", "Te05", "F0Ac", "Tg0G", "Tp01", "TA0P", "TC0P", "LD0R", "TB0T",
        ]

        let temperatures = SensorCatalog.temperatureKeys(fromAllKeys: allKeys)

        XCTAssertEqual(temperatures, ["TA0P", "TB0T", "TC0P", "Te05", "Tg0G", "Tp01"])
    }

    func testFilterDropsNonFourCharAndNonTKeys() {
        let allKeys = ["Tp01", "T00", "Tp001", "Xp01", "", "T"]

        XCTAssertEqual(SensorCatalog.temperatureKeys(fromAllKeys: allKeys), ["Tp01"])
    }

    /// 全键枚举 + 归类应能把未知代系的温度键自动认出来（三级回退的核心价值）。
    func testEnumerationPlusCatalogCoversUnknownGeneration() {
        let allKeys = ["#KEY", "Tp0Z", "Tf1A", "Te0X", "Tg0Q", "Ts1P", "F0Ac"]

        let descriptors = SensorCatalog.descriptors(
            forKeys: SensorCatalog.temperatureKeys(fromAllKeys: allKeys)
        )

        XCTAssertEqual(descriptors.count, 5)
        XCTAssertEqual(descriptors.filter { $0.category == .cpu }.count, 3)
        XCTAssertEqual(descriptors.filter { $0.category == .gpu }.count, 1)
        XCTAssertEqual(descriptors.filter { $0.category == .ssd }.count, 1)
        // 未知键也必须有可展示的名字（不出现空名）
        XCTAssertTrue(descriptors.allSatisfy { !$0.name.isEmpty })
    }

    // MARK: - 键名常量

    func testKeyCountKeyConstant() {
        XCTAssertEqual(SMCKeyName.keyCount, "#KEY")
        XCTAssertEqual(SMCCommand.readIndex.rawValue, 8)
    }
}
