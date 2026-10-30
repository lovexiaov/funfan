import XCTest
@testable import FunFanCore

/// T5 粘合层：SMC 采样源——「全键枚举一次 → 缓存 → 每周期只读温度键」。
///
/// 该层是 `SensorMonitor` 的真实数据来源，必须可注入（不依赖真机）以便确定性测试。
final class SMCTemperatureProviderTests: XCTestCase {

    private let fakeKeys = ["#KEY", "Tp01", "Tp0W", "Te05", "Tg0G", "F0Ac", "TA0P"]

    private func values() -> [String: Double] {
        ["Tp01": 60, "Tp0W": 70, "Te05": 55, "Tg0G": 48, "TA0P": 30, "F0Ac": 1200]
    }

    func testReadsOnlyTemperatureKeys() {
        var listCalls = 0
        let provider = SMCTemperatureProvider(
            keyLister: { listCalls += 1; return self.fakeKeys },
            reader: { self.values()[$0] ?? 0 }
        )

        let readings = provider.readings()

        XCTAssertEqual(readings.map(\.descriptor.key).sorted(), ["TA0P", "Te05", "Tg0G", "Tp01", "Tp0W"])
        XCTAssertEqual(listCalls, 1)
    }

    func testCachesKeyListAcrossCycles() {
        var listCalls = 0
        let provider = SMCTemperatureProvider(
            keyLister: { listCalls += 1; return self.fakeKeys },
            reader: { self.values()[$0] ?? 0 }
        )

        _ = provider.readings()
        _ = provider.readings()
        _ = provider.readings()

        XCTAssertEqual(listCalls, 1, "键表必须缓存，否则每 0.5s 枚举 1369 个键会浪费 CPU")
    }

    func testFiltersImplausibleValues() {
        var table = values()
        table["Tp01"] = 0        // 未初始化
        table["Te05"] = 250      // 明显超范围
        table["Tg0G"] = 4.9      // 低于下限
        table["TA0P"] = 132      // 高于上限

        let provider = SMCTemperatureProvider(
            keyLister: { self.fakeKeys },
            reader: { table[$0] ?? 0 }
        )

        let readings = provider.readings()

        XCTAssertEqual(readings.map(\.descriptor.key).sorted(), ["Tp0W"], "只保留 5–131℃ 的合理值")
    }

    func testSkipsUnreadableKeys() {
        struct Boom: Error {}
        let provider = SMCTemperatureProvider(
            keyLister: { self.fakeKeys },
            reader: { key in
                if key == "Tp01" { throw Boom() }
                return self.values()[key] ?? 0
            }
        )

        let readings = provider.readings()

        XCTAssertFalse(readings.contains { $0.descriptor.key == "Tp01" })
        XCTAssertEqual(readings.count, 4)
    }

    func testListerFailureYieldsEmptyThenRetries() {
        struct Boom: Error {}
        var shouldFail = true
        var listCalls = 0

        let provider = SMCTemperatureProvider(
            keyLister: {
                listCalls += 1
                if shouldFail { throw Boom() }
                return self.fakeKeys
            },
            reader: { self.values()[$0] ?? 0 }
        )

        XCTAssertTrue(provider.readings().isEmpty)
        shouldFail = false
        XCTAssertEqual(provider.readings().count, 5, "失败后下一周期必须重试枚举")
        XCTAssertEqual(listCalls, 2)
    }

    func testRescanPicksUpNewKeys() {
        var keys = ["Tp01"]
        let provider = SMCTemperatureProvider(
            keyLister: { keys },
            reader: { self.values()[$0] ?? 0 }
        )

        XCTAssertEqual(provider.readings().count, 1)
        keys = ["Tp01", "Tg0G"]
        provider.invalidateKeyCache()
        XCTAssertEqual(provider.readings().count, 2)
    }

    /// 与 `SensorMonitor` 串起来：单周期产出快照并参与均温。
    func testIntegratesWithSensorMonitor() {
        let provider = SMCTemperatureProvider(
            keyLister: { self.fakeKeys },
            reader: { self.values()[$0] ?? 0 }
        )
        let monitor = SensorMonitor(windowCapacity: 4, provider: { provider.readings() })

        let snapshot = monitor.tick()

        XCTAssertEqual(snapshot.readings.count, 5)
        XCTAssertEqual(snapshot.averageCPU()!, (60 + 70 + 55) / 3, accuracy: 1e-9)
    }
}
