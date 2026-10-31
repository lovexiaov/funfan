import Foundation
import FunFanCore

// 真机探针：用 FunFanCore 自身的代码验证真实管线
// 「全键枚举 → 温度键筛选 → 归类 → 2Hz 采样 → 平滑 → 快照」与电量读取。
// 运行：swift run --disable-sandbox FunFanProbe [--keys]

let smc = SMCService()
do {
    try smc.open()
    print("[SMC] opened OK, struct=\(MemoryLayout<SMCParamStruct>.size) bytes")

    // 1) 全键枚举
    let started = Date()
    let allKeys = try smc.allKeys()
    let enumerateMs = Date().timeIntervalSince(started) * 1000
    print(String(format: "[SMC] 全键枚举 %d 个键，耗时 %.0f ms", allKeys.count, enumerateMs))

    // 2) 温度键筛选
    let tempKeys = SensorCatalog.temperatureKeys(fromAllKeys: allKeys)
    print("[SMC] 温度键 \(tempKeys.count) 个")

    // --keys：打印全部温度键与读数（诊断用，后续可作为 doctor 子命令）
    if CommandLine.arguments.contains("--keys") {
        for key in tempKeys {
            let value = (try? smc.readKey(key)).map { String(format: "%.1f", $0) } ?? "n/a"
            let category = SensorCatalog.descriptor(for: key)?.category.rawValue ?? "?"
            print("   \(key)  \(value)°C  \(category)")
        }
    }

    // 3) 真实管线：provider（缓存键表）→ monitor（滑动均值）
    let provider = SMCTemperatureProvider(service: smc)
    let monitor = SensorMonitor(windowCapacity: 60, provider: { provider.readings() })

    var firstTickMs: Double = 0
    var steadyTickMs: Double = 0
    var snapshot: SensorSnapshot!

    for cycle in 0..<3 {
        let ipcBefore = smc.ipcCallCount
        let tickStart = Date()
        snapshot = monitor.tick()
        let ms = Date().timeIntervalSince(tickStart) * 1000
        let ipc = smc.ipcCallCount - ipcBefore
        if cycle == 0 { firstTickMs = ms } else { steadyTickMs = ms }
        print(String(format: "[Tick %d] %d 个读数，IPC %d 次，耗时 %.1f ms", cycle + 1, snapshot.readings.count, ipc, ms))
        if cycle < 2 { Thread.sleep(forTimeInterval: 0.5) }
    }
    print(String(format: "[Perf] 首帧 %.1f ms（含枚举）／稳态 %.1f ms（仅读缓存键表）", firstTickMs, steadyTickMs))

    // 4) 按类别均温
    for category in SensorCategory.allCases {
        let items = snapshot.readings(in: category)
        guard !items.isEmpty else { continue }
        let avg = snapshot.average(for: category)!
        print(String(format: "   %@: %d 个，均温 %.1f°C", category.rawValue, items.count, avg))
    }

    // 5) CPU 按簇（P/E/Super）聚合
    for subcluster in [CPUSubcluster.performance, .efficiency, .superCluster] {
        let group = snapshot.readings.filter { $0.descriptor.subcluster == subcluster }
        guard !group.isEmpty else { continue }
        let avg = snapshot.average(subcluster: subcluster)!
        let sensorCount = snapshot.readings.filter { $0.descriptor.subcluster == subcluster }.count
        print(String(format: "   CPU · %@: %d 个温度探测点，均温 %.1f°C",
                     subcluster.rawValue, sensorCount, avg))
    }

    // 6) 风扇
    if let fanCount = try? smc.readKey(SMCKeyName.fanCount) {
        print("[Fan] count=\(Int(fanCount))")
        for i in 0..<Int(fanCount) {
            let actual = (try? smc.readKey(SMCKeyName.fanActual(i))).map { String(format: "%.0f", $0) } ?? "n/a"
            let minimum = (try? smc.readKey(SMCKeyName.fanMin(i))).map { String(format: "%.0f", $0) } ?? "n/a"
            let maximum = (try? smc.readKey(SMCKeyName.fanMax(i))).map { String(format: "%.0f", $0) } ?? "n/a"
            print("   Fan \(i): actual=\(actual) min=\(minimum) max=\(maximum)")
        }
    }

    // 7) M4 前置诊断：手动模式键与 Ftst 解锁键是否存在（只探测，不写入）
    let modeKeys = SMCKeyName.fanModeCandidates(0)
    let presentModeKeys = modeKeys.filter { smc.keyExists($0) }
    print("[Diag] 模式键候选 \(modeKeys) → 存在: \(presentModeKeys.isEmpty ? "无" : presentModeKeys.joined(separator: ","))")
    print("[Diag] Ftst 解锁键: \(smc.keyExists(SMCKeyName.ftst) ? "存在（M3/M4 需要解锁序列）" : "不存在（可直接写 F0Tg）")")

    // 8) 控制引擎真机演练（只算不写）：安全下限 / 曲线 / 规则
    if let fanCount = try? smc.readKey(SMCKeyName.fanCount), fanCount >= 1,
       let minRpm = try? smc.readKey(SMCKeyName.fanMin(0)),
       let maxRpm = try? smc.readKey(SMCKeyName.fanMax(0)) {
        let limits = FanLimits(minRpm: minRpm, maxRpm: maxRpm)
        let die = snapshot.readings.map(\.celsius).max() ?? 0
        print(String(format: "[Control] limits=%.0f–%.0f  die=%.1f℃  安全下限=%.0f",
                     limits.minRpm, limits.maxRpm, die,
                     SafetyPolicy.floorRpm(dieCelsius: die, limits: limits)))

        let curve = FanCurve(points: [
            CurvePoint(celsius: 45, rpm: minRpm),
            CurvePoint(celsius: 70, rpm: (minRpm + maxRpm) / 2),
            CurvePoint(celsius: 92, rpm: maxRpm),
        ])
        var engine = CurveEngine(curve: curve)
        if let curveRpm = engine.update(celsius: die, secondsElapsed: 1) {
            let clamped = SafetyPolicy.clamp(curveRpm, dieCelsius: die, limits: limits)
            print(String(format: "[Control] 曲线目标 %.0f → clamp 后 %.0f", curveRpm, clamped))
        }

        var rules = RuleEngine()
        let demoRule = FanRule(
            name: "CPU ≥ 60℃ → 60% 转速",
            subject: .category(.cpu),
            comparator: .greaterThanOrEqual,
            thresholdCelsius: 60,
            action: .setPercent(60),
            hysteresisCelsius: 3
        )
        let result = rules.evaluate(snapshot: snapshot, rules: [demoRule], limits: limits)
        if let rpm = result.commandedRpm {
            print(String(format: "[Control] 规则触发 → 目标 %.0f（触发规则 %d 条）", rpm, result.triggeredRuleIDs.count))
        } else {
            print("[Control] 规则未触发（CPU 均温未达阈值）")
        }
    }
} catch {
    print("[SMC] error: \(error)")
}
smc.close()

// 7) 电量（IOPS + AppleSmartBattery 明细）
let battery = BatteryStore()
let state = battery.refresh()
let pct = state.percentage.map { String(format: "%.1f", $0) } ?? "n/a"
let health = state.health.map { String(format: "%.1f", $0) } ?? "n/a"
let cycles = state.cycleCount.map(String.init) ?? "n/a"
let watts = state.powerWatts.map { String(format: "%.2f", $0) } ?? "n/a"
let temp = state.temperatureCelsius.map { String(format: "%.1f", $0) } ?? "n/a"
print("[Battery] present=\(state.present) pct=\(pct)% health=\(health)% cycles=\(cycles) power=\(watts)W temp=\(temp)°C charging=\(state.isCharging) external=\(state.externalConnected)")
