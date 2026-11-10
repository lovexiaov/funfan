import Foundation
import FunFanCore

// 真机探针：用 FunFanCore 自身的代码验证真实管线
// 「全键枚举 → 温度键筛选 → 归类 → 2Hz 采样 → 平滑 → 快照」与电量读取。
// 运行：swift run --disable-sandbox FunFanProbe [--keys]

// --update-check：真机打一次 GitHub 发布列表。
// 必须在 `smc.open()` 之前分流：检查更新不需要任何硬件权限，
// 而 SMC 打不开（无权限/非本机）时它仍应能验证网络与解析链路。
//   swift run --disable-sandbox FunFanProbe --update-check [--current 1.0.0-alpha.5]
if CommandLine.arguments.contains("--update-check") {
    runUpdateCheckProbe()
    exit(0)
}

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

    // --tier：两层采样 A/B 对比（M14 真机验收）——旧行为 vs 生产参数，
    // 同进程交替采样，对比耗时/IPC/数据偏差。跑完即退出。
    if CommandLine.arguments.contains("--tier") {
        runTierComparison(smc: smc)
        exit(0)   // 对比模式到此为止，不走后面的风扇/控制/电量流程
    }

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
        let die = snapshot.controlCelsius(.peak) ?? 0
        print(String(format: "[Control] limits=%.0f–%.0f  die=%.1f℃  安全下限=%.0f",
                     limits.minRpm, limits.maxRpm, die,
                     SafetyPolicy.floorRpm(dieCelsius: die, limits: limits)))

        // 两种调速口径的真机差值（设置项「调速依据温度」）：同一帧数据下
        // 均温口径会把安全下限压低多少，靠静态推算看不出来。
        if let avgDie = snapshot.controlCelsius(.average) {
            let peakFloor = SafetyPolicy.floorRpm(dieCelsius: die, limits: limits)
            let avgFloor = SafetyPolicy.floorRpm(dieCelsius: avgDie, limits: limits)
            print(String(format: "[Control] 均温口径 %.1f℃  安全下限=%.0f（比最高温口径 %+.0f）",
                         avgDie, avgFloor, avgFloor - peakFloor))
        }

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

// MARK: - 两层采样 A/B 对比（M14 真机验收）

/// 同进程里跑「旧模式（每帧全量）」与「生产两层采样」各 N 帧，交替进行，
/// 对比三项：耗时/IPC（省了多少）、各类均温偏差（显示准不准）、
/// hottest 偏差（控制准不准）、单键最大偏差（兜底）。
/// A/B 逐帧紧挨着读，期间温度漂移最小，偏差可近似视为纯方法差异。
private func runTierComparison(smc: SMCService) {
    let frames = 20
    let legacy = SMCTemperatureProvider(service: smc)                                   // 旧行为：fullScanEvery = 1
    let tiered = SMCTemperatureProvider(service: smc, fullScanEvery: 10, perCategoryHotKeys: 4) // 生产参数

    _ = legacy.readings()   // 各自预热（键表枚举）
    _ = tiered.readings()

    var legacyMs: [Double] = [], tieredMs: [Double] = []
    var legacyIPC = 0, tieredIPC = 0
    var maxAvgDelta = 0.0, maxHottestDelta = 0.0, maxKeyDelta = 0.0
    var maxAvgCategory = "", shapeMismatchFrames = 0

    for _ in 0..<frames {
        // A：全量
        var before = smc.ipcCallCount
        var t0 = DispatchTime.now()
        let a = legacy.readings()
        legacyMs.append(Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6)
        legacyIPC += smc.ipcCallCount - before
        let snapA = SensorSnapshot(readings: a, timestamp: Date())

        // B：两层采样（紧挨着读）
        before = smc.ipcCallCount
        t0 = DispatchTime.now()
        let b = tiered.readings()
        tieredMs.append(Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6)
        tieredIPC += smc.ipcCallCount - before
        let snapB = SensorSnapshot(readings: b, timestamp: Date())

        // 形状必须一致（M14 的核心承诺：消费方零改动）
        if Set(a.map(\.descriptor.key)) != Set(b.map(\.descriptor.key)) {
            shapeMismatchFrames += 1
        }

        // hottest（控制引擎同款算法）
        let hotA = a.map(\.celsius).max() ?? 0
        let hotB = b.map(\.celsius).max() ?? 0
        maxHottestDelta = max(maxHottestDelta, abs(hotA - hotB))

        // 各类均温（显示用）
        for category in SensorCategory.allCases {
            guard let avgA = snapA.average(for: category),
                  let avgB = snapB.average(for: category) else { continue }
            let delta = abs(avgA - avgB)
            if delta > maxAvgDelta {
                maxAvgDelta = delta
                maxAvgCategory = category.rawValue
            }
        }

        // 单键最大偏差（兜底视角）
        var byKey: [String: Double] = [:]
        for r in b { byKey[r.descriptor.key] = r.celsius }
        for r in a {
            if let v = byKey[r.descriptor.key] {
                maxKeyDelta = max(maxKeyDelta, abs(r.celsius - v))
            }
        }
    }

    func stats(_ xs: [Double]) -> (avg: Double, max: Double) {
        (xs.reduce(0, +) / Double(xs.count), xs.max() ?? 0)
    }
    let la = stats(legacyMs), ta = stats(tieredMs)

    print("[Tier] A/B 各 \(frames) 帧（B：每 10 帧全量 + 每类最热 4 键快帧）")
    print(String(format: "[Tier] 耗时：全量帧 均值 %.1f ms / 最大 %.1f ms；两层帧 均值 %.1f ms / 最大 %.1f ms（均值 -%.0f%%）",
                 la.avg, la.max, ta.avg, ta.max, (1 - ta.avg / la.avg) * 100))
    print(String(format: "[Tier] IPC：全量 %d 次，两层 %d 次（-%.0f%%）",
                 legacyIPC, tieredIPC, (1 - Double(tieredIPC) / Double(legacyIPC)) * 100))
    print(String(format: "[Tier] 数据对比：均温最大偏差 %.3f℃（%@）｜hottest 最大偏差 %.3f℃｜单键最大偏差 %.3f℃",
                 maxAvgDelta, maxAvgCategory as NSString, maxHottestDelta, maxKeyDelta))
    print("[Tier] 形状：\(shapeMismatchFrames == 0 ? "全部 \(frames) 帧键集合一致 ✓" : "\(shapeMismatchFrames) 帧键集合不一致 ✗")")
}

// MARK: - 更新检查探针

/// 真机验证「检查更新」的完整链路：真实网络 → 真实 GitHub 列表 → 版本比较。
///
/// 为什么放在探针里而不是只靠单测：单测用的夹具是我按文档写的，
/// 而 `tag_name` / `prerelease` / `browser_download_url` 这些字段到底叫什么、
/// 草稿会不会漏出来、`/releases/latest` 是不是真的 404，只有打一次真接口才知道。
func runUpdateCheckProbe() {
    let arguments = CommandLine.arguments
    let overridden = arguments.firstIndex(of: "--current").flatMap { index -> String? in
        index + 1 < arguments.count ? arguments[index + 1] : nil
    }
    let fromBundle = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    let raw = overridden ?? fromBundle ?? "0.0.0"
    guard let current = SemanticVersion(parsing: raw) else {
        print("[Update] 版本号无法解析：\(raw)")
        return
    }

    let source = overridden != nil ? "--current" : (fromBundle != nil ? "Info.plist" : "兜底默认")
    print("[Update] 当前版本 \(current)（来源：\(source)）")
    print("[Update] 端点 \(UpdateChecker.defaultFeedURL.absoluteString)")

    let prefs = UpdatePreferences(defaults: .standard)
    print("[Update] 自动检查默认值=\(UpdatePreferences.defaultAutoCheck) 当前=\(prefs.autoCheckEnabled) "
          + "已忽略=\(prefs.skippedVersion ?? "无") 上次检查=\(prefs.lastCheckedAt.map { "\($0)" } ?? "从未")")

    // --feed <文件>：用一份抓下来的真实响应跑选择逻辑（不联网）。
    // 用途：出口 IP 被限流时仍能验证解析；复现「某次发布为什么没被推出来」。
    if let index = arguments.firstIndex(of: "--feed"), index + 1 < arguments.count {
        let path = arguments[index + 1]
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let releases = try ReleaseFeed.decode(data)
            print("[Update] 本地响应解析出 \(releases.count) 条已发布版本：")
            for info in releases.sorted(by: { $0.version < $1.version }) {
                print("[Update]   \(info.version)  tag=\(info.tag)  pre=\(info.isPrerelease)  "
                      + "assets=\(info.assets.count)  dmg=\(info.assets.contains { $0.name.lowercased().hasSuffix(".dmg") })")
            }
            let outcome = UpdateChecker.select(
                from: releases, current: current, skipping: prefs.skippedVersion
            )
            describe(outcome, elapsed: nil)
        } catch {
            print("[Update] 本地响应解析失败：\(error)")
        }
        return
    }

    let semaphore = DispatchSemaphore(value: 0)
    Task {
        let started = Date()
        do {
            let outcome = try await UpdateChecker().check(current: current, skipping: prefs.skippedVersion)
            describe(outcome, elapsed: Date().timeIntervalSince(started) * 1000)
        } catch let failure as UpdateFailure {
            print("[Update] 失败（分类）：\(failure)")
            print("[Update] 给用户的话：\(failure.message)")
        } catch {
            print("[Update] 失败（未归类）：\(error.localizedDescription)")
        }
        semaphore.signal()
    }
    semaphore.wait()
}

/// 把选择结果打印成人话。联网与本地响应两条路径共用，避免两边说法不一致。
private func describe(_ outcome: UpdateOutcome, elapsed: Double?) {
    let timing = elapsed.map { String(format: "，耗时 %.0f ms", $0) } ?? ""
    switch outcome {
    case .upToDate(let version):
        print("[Update] 已是最新（当前 \(version)\(timing)）")
    case .available(let info):
        print("[Update] 发现新版本 \(info.version)（tag \(info.tag)，预发布=\(info.isPrerelease ? "是" : "否")\(timing)）")
        print("[Update] 下载链接：\(info.downloadURL?.absoluteString ?? "无")")
        print("[Update] 发布页面：\(info.pageURL?.absoluteString ?? "无")")
        if let published = info.publishedAt {
            print("[Update] 发布时间：\(published)")
        }
        for line in info.notes.split(separator: "\n").prefix(3) {
            print("[Update] notes| \(line)")
        }
    }
}
