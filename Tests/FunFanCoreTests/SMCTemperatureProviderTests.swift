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

    // MARK: - 键表计数（回答「这台机器有没有这类传感器」）

    /// 键表还没枚举 → `nil`。UI 据此保持「暂无读数」，不能判成「无传感器」。
    func testSensorCountIsNilBeforeEnumeration() {
        let provider = SMCTemperatureProvider(
            keyLister: { self.fakeKeys },
            reader: { self.values()[$0] ?? 0 }
        )
        XCTAssertNil(provider.sensorCount(for: .ambient))
        XCTAssertNil(provider.sensorCount(for: .ssd))
    }

    /// 计数看的是**键存在**，不是**这一帧读成功**：读失败/越界被过滤掉，
    /// 计数依然是 1——否则唤醒瞬间会误报「这台机器没有环境传感器」。
    func testSensorCountSurvivesUnreadableFrame() {
        struct Boom: Error {}
        let provider = SMCTemperatureProvider(
            keyLister: { self.fakeKeys },
            reader: { key in
                if key == "TA0P" { throw Boom() }
                return self.values()[key] ?? 0
            }
        )

        XCTAssertTrue(provider.readings().allSatisfy { $0.descriptor.category != .ambient })
        XCTAssertEqual(provider.sensorCount(for: .ambient), 1)
        XCTAssertEqual(provider.sensorCount(for: .ssd), 0)
    }

    /// 不在采样范围内的类别（`.other`）也要能计数。
    /// 本机 Mac mini M4 的 `Ta0p`/`TH0p` 就落在这里：默认不采样，但要知道它们存在。
    func testSensorCountCoversCategoriesOutsideSamplingScope() {
        let keys = ["Tp01", "Ta0p", "TH0p"]
        let provider = SMCTemperatureProvider(keyLister: { keys }, reader: { _ in 30 })

        XCTAssertEqual(provider.readings().count, 1, "other 不进采样")
        XCTAssertEqual(provider.sensorCount(for: .other), 2, "但计数要能看到它们")
        XCTAssertEqual(provider.sensorCount(for: .ambient), 0)
    }

    /// 重新枚举后计数跟着更新（机型/系统变化、睡眠唤醒重建连接）。
    func testSensorCountFollowsRescan() {
        var keys = ["Tp01"]
        let provider = SMCTemperatureProvider(keyLister: { keys }, reader: { _ in 30 })

        _ = provider.readings()
        XCTAssertEqual(provider.sensorCount(for: .ambient), 0)

        keys = ["Tp01", "TA0P"]
        provider.invalidateKeyCache()
        XCTAssertNil(provider.sensorCount(for: .ambient), "缓存失效后回到未知")
        _ = provider.readings()
        XCTAssertEqual(provider.sensorCount(for: .ambient), 1)
    }

    // MARK: - 两层采样（M14：快帧只读热键白名单，其余键复用上轮全扫缓存）

    /// 键位安排：4 个 CPU 探测点 + 1 个 GPU 探测点（前缀决定类别）。
    private let tierKeys = ["Tp01", "Tp02", "Tp03", "Tp04", "Tg0G"]

    /// `fullScanEvery: 1`（默认）必须保持旧行为：每个键每帧都真读。
    func testLegacyModeReadsEveryKeyEveryFrame() {
        var readCounts: [String: Int] = [:]
        let provider = SMCTemperatureProvider(
            keyLister: { self.tierKeys },
            reader: { key in readCounts[key, default: 0] += 1; return 50 },
            fullScanEvery: 1
        )

        for _ in 0..<3 { _ = provider.readings() }

        XCTAssertEqual(readCounts["Tp01"], 3)
        XCTAssertEqual(readCounts["Tg0G"], 3)
    }

    /// 第 1 帧恒为全量扫描：白名单和缓存都从这里建立。
    func testFirstFrameIsAlwaysFullScan() {
        var readCounts: [String: Int] = [:]
        let provider = SMCTemperatureProvider(
            keyLister: { self.tierKeys },
            reader: { key in readCounts[key, default: 0] += 1; return 50 },
            fullScanEvery: 10
        )

        let readings = provider.readings()

        XCTAssertEqual(readings.count, 5)
        XCTAssertEqual(readCounts["Tp04"], 1, "首帧必须全量")
    }

    /// 快帧只真读白名单键（每类最热 K 个 + 键数 ≤ K 的整类），其余键复用缓存，
    /// 输出形状与全量一致——消费方（均温 / hottest / 明细列表）零改动。
    func testFastFrameReadsOnlyHotKeysAndMergesCache() {
        var table: [String: Double] = ["Tp01": 60, "Tp02": 70, "Tp03": 65, "Tp04": 55, "Tg0G": 48]
        var readCounts: [String: Int] = [:]
        let provider = SMCTemperatureProvider(
            keyLister: { self.tierKeys },
            reader: { key in
                readCounts[key, default: 0] += 1
                return table[key] ?? 0
            },
            fullScanEvery: 10,
            perCategoryHotKeys: 2
        )

        _ = provider.readings()                       // 帧 1：全量
        table["Tp02"] = 72                            // 白名单键本轮有新值
        let fast = provider.readings()                // 帧 2：快帧

        // 只真读：CPU 最热 2 个（Tp02 70、Tp03 65）+ GPU 整类（Tg0G，1 ≤ 2）
        XCTAssertEqual(readCounts["Tp02"], 2)
        XCTAssertEqual(readCounts["Tp03"], 2)
        XCTAssertEqual(readCounts["Tg0G"], 2)
        XCTAssertEqual(readCounts["Tp01"], 1, "冷键不在白名单，快帧不读")
        XCTAssertEqual(readCounts["Tp04"], 1)

        // 输出形状不变：5 个键全在，白名单键是新值，其余是缓存值
        XCTAssertEqual(fast.count, 5)
        let byKey = Dictionary(uniqueKeysWithValues: fast.map { ($0.descriptor.key, $0.celsius) })
        XCTAssertEqual(byKey["Tp02"], 72, "白名单键必须拿到新读数")
        XCTAssertEqual(byKey["Tp01"], 60, "非白名单键复用上轮全扫缓存")
        XCTAssertEqual(byKey["Tp04"], 55)
    }

    /// 周期性全量扫描刷新缓存与白名单：fullScanEvery = 3 → 帧 1/4/7… 全量。
    /// K=2：CPU 最热 2 个进白名单，Tp04/Tp01 之外的两个冷键快帧不读。
    func testPeriodicFullScanRefreshesCacheAndWhitelist() {
        var readCounts: [String: Int] = [:]
        let provider = SMCTemperatureProvider(
            keyLister: { self.tierKeys },
            reader: { key in readCounts[key, default: 0] += 1; return 50 },
            fullScanEvery: 3,
            perCategoryHotKeys: 2
        )

        for _ in 0..<4 { _ = provider.readings() }    // 帧 1 全量，2/3 快帧，4 全量

        XCTAssertEqual(readCounts["Tp04"], 2, "冷键只在帧 1 与帧 4（全量帧）各读一次")
        XCTAssertEqual(readCounts["Tp01"], 4, "白名单键每帧都读")
    }

    /// 热点漂移后白名单必须跟上：全量扫描时重新评选每类最热键。
    func testWhitelistFollowsNewHotspots() {
        var table: [String: Double] = ["Tp01": 60, "Tp02": 55, "Tg0G": 48]
        var readCounts: [String: Int] = [:]
        let provider = SMCTemperatureProvider(
            keyLister: { ["Tp01", "Tp02", "Tg0G"] },
            reader: { key in
                readCounts[key, default: 0] += 1
                return table[key] ?? 0
            },
            fullScanEvery: 3,
            perCategoryHotKeys: 1
        )

        _ = provider.readings()                       // 帧 1 全量：白名单 = {Tp01, Tg0G}
        _ = provider.readings()                       // 帧 2 快帧
        table["Tp02"] = 99                            // 冷键升温（在帧 1–3 之间发生）
        _ = provider.readings()                       // 帧 3 快帧：仍读 Tp01
        _ = provider.readings()                       // 帧 4 全量：发现新热点

        table["Tp01"] = 60                            // Tp01 已降温
        _ = provider.readings()                       // 帧 5 快帧：应改读 Tp02

        XCTAssertGreaterThanOrEqual(readCounts["Tp02"] ?? 0, 3, "帧 4 全量 + 帧 5 快帧都要读新热点")
        XCTAssertEqual(readCounts["Tp01"], 4, "帧 1/4 全量 + 帧 2/3 快帧；帧 5 起让位给新热点")
    }

    /// 缓存值不许凭空消失：快帧里缓存键仍在输出里参与 hottest / 均温，
    /// hottest 不会因为白名单键降温而误降（保守不回退）。
    func testMergedFastFrameKeepsCachedHottest() {
        var table: [String: Double] = ["Tp01": 90, "Tp02": 80, "Tg0G": 48]
        let provider = SMCTemperatureProvider(
            keyLister: { ["Tp01", "Tp02", "Tg0G"] },
            reader: { table[$0] ?? 0 },
            fullScanEvery: 10,
            perCategoryHotKeys: 1
        )

        _ = provider.readings()                       // 帧 1 全量：白名单 = {Tp01, Tg0G}
        table["Tp01"] = 50                            // 热点键骤冷
        let fast = provider.readings()                // 帧 2 快帧

        XCTAssertEqual(fast.count, 3, "缓存键不能丢")
        // 控制引擎取「快照内最高温度」的方式就是 readings.map(\.celsius).max()
        // （RuleEngine.swift dieCelsius 同款）——缓存值必须参与其中兜底
        XCTAssertEqual(fast.map(\.celsius).max(), 80, "hottest = max(白名单新值 50, 缓存 80)——缓存保守兜底")
    }

    /// `invalidateKeyCache()` 后必须回到全量扫描：键表都变了，旧缓存不可信。
    func testInvalidateKeyCacheForcesFullScan() {
        var readCounts: [String: Int] = [:]
        let provider = SMCTemperatureProvider(
            keyLister: { self.tierKeys },
            reader: { key in readCounts[key, default: 0] += 1; return 50 },
            fullScanEvery: 10,
            perCategoryHotKeys: 2
        )

        _ = provider.readings()                       // 帧 1 全量
        _ = provider.readings()                       // 帧 2 快帧（冷键不读）
        provider.invalidateKeyCache()
        _ = provider.readings()                       // 重建后必须全量

        XCTAssertEqual(readCounts["Tp04"], 2, "帧 1 全量 + 失效重建后的第一帧全量；中间快帧不读冷键")
    }
}
