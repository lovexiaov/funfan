import Foundation
import Darwin
import FunFanCore

// funfanctl —— FunFan 的特权命令行工具（M4）
//
// 职责：
//   doctor   诊断：权限、风扇、模式键、解锁键、键类型、当前值
//   topology 打印芯片真实核心数（P/E/GPU，来自 sysctl/IORegistry）
//   status   只读状态（不需要 root）
//   spin     写入验证：设目标 → 采样 F0Ac → 自动返还系统自动（需要 root）
//   set      保持手动（需要 root，务必随后 restore）
//   restore  返还系统自动（需要 root）
//
// 安全设计：
//   - `spin` 用 defer 保证任何路径（含 Ctrl-C）都会返还系统自动；
//   - 绝不写 F0Mn / F0Mx，绝不设 0 RPM；
//   - 写入前 clamp 到系统区间，超出即拒绝。

// MARK: - 信号：只置标志位，交给主流程安全返还

var interrupted = false
signal(SIGINT) { _ in interrupted = true }
signal(SIGTERM) { _ in interrupted = true }
signal(SIGHUP) { _ in interrupted = true }

// MARK: - 小工具

let isRoot = geteuid() == 0

func out(_ text: String) {
    FileHandle.standardOutput.write((text + "\n").data(using: .utf8)!)
}

func err(_ text: String) {
    FileHandle.standardError.write((text + "\n").data(using: .utf8)!)
}

func optionValue(_ name: String, in args: [String]) -> String? {
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
    return args[index + 1]
}

func intOption(_ name: String, in args: [String]) -> Int? {
    optionValue(name, in: args).flatMap(Int.init)
}

func doubleOption(_ name: String, in args: [String]) -> Double? {
    optionValue(name, in: args).flatMap(Double.init)
}

func usage() {
    out("""
    funfanctl —— FunFan 风扇控制命令行（M4）

    用法：
      funfanctl diagnose [--json] [--save]
                                         系统信息采集：逐项能力实测 + 排查建议
                                         （--json 机读、--save 落盘，有失败项时退出码 2）
      funfanctl doctor                   诊断硬件与权限（只读）
      funfanctl topology                打印芯片真实核心数（P/E/GPU，来自 sysctl/IORegistry）
      funfanctl raw <KEY>... | --type <T> 打印原始字节与候选解码（未支持类型取证）
      funfanctl status                   当前风扇状态（只读）
      funfanctl spin [--rpm N] [--seconds N] [--fan N]
                                         写入验证：设目标→观测实际转速→自动返还
      funfanctl set <rpm> [--fan N]      保持手动（需随后 restore）
      funfanctl restore [--fan N]        返还系统自动

    注意：写操作需要 root，请用 sudo 运行。
    """)
}

func requireRoot(_ action: String) -> Bool {
    guard isRoot else {
        err("✗ 该操作需要 root（SMC 写入必须由特权进程执行）。")
        err("  请用： sudo .build/release/funfanctl \(action)")
        return false
    }
    return true
}

func describe(_ error: Error) -> String {
    guard let e = error as? FunFanError else { return "\(error)" }
    switch e {
    case .smcAccessDenied: return "AppleSMC 访问被拒绝（写入需 root）"
    case .keyNotFound(let k): return "当前机型无此 SMC 键：\(k)"
    case .dataTypeUnsupported(let t): return "不支持的数据类型：\(t)"
    case .decodeFailed(let k, let t): return "解码失败：\(k) (\(t))"
    case .thermalManagerRefused: return "thermalmonitord 拒绝写入（解锁失效或机型限制）"
    case .helperUnavailable: return "特权 helper 不可用"
    case .invalidTargetRpm(let rpm): return "非法目标转速：\(rpm)"
    }
}

// MARK: - 打开 SMC

func openSMC() -> SMCService? {
    let smc = SMCService()
    do {
        try smc.open()
        return smc
    } catch {
        err("✗ 打开 AppleSMC 失败：\(describe(error))")
        if !isRoot {
            err("  读操作通常无需 root；若仍失败，说明系统策略或机型不支持。")
        }
        return nil
    }
}

// MARK: - doctor

func runDoctor() {
    out("=== FunFan doctor ===")
    out("权限：\(isRoot ? "root ✓（可写）" : "普通用户（只读；写入请用 sudo）")")
    out("SMCParamStruct：\(MemoryLayout<SMCParamStruct>.size) 字节\(MemoryLayout<SMCParamStruct>.size == 80 ? " ✓" : " ✗ 异常")")
    // 机型 + 芯片 + 系统：排障时这三项决定「这条结论适不适用于你的机器」
    out("机型标识：\(ProcessInfo.processInfo.machineHardwareName)  芯片：\(ProcessInfo.processInfo.chipName)")
    out("系统：\(ProcessInfo.processInfo.operatingSystemVersionString)  架构：\(ProcessInfo.processInfo.architectureLabel)")
    // 键名速查：用户报障时最常需要确认的就是「你的机器上到底有没有这些键」。
    out("关键键：\(SMCKeyName.fanCount)、\(SMCKeyName.fanTarget(0))、"
        + "\(SMCKeyName.fanModeCandidates(0).joined(separator: " / "))、\(SMCKeyName.ftst)")

    guard let smc = openSMC() else { exit(1) }
    defer { smc.close() }

    let driver = FanHardwareDriver(device: smc)
    let count = driver.fanCount()
    out("风扇数量：\(count)\(count == 0 ? "（无风扇机型，仅支持监控）" : "")")

    for index in 0..<max(count, 1) where count > 0 {
        let probe = driver.probe(fanIndex: index)
        out("")
        out("--- Fan \(index) ---")
        out("  模式键：\(probe.modeKey ?? "无（不支持手动控制）")")
        out("  Ftst 解锁键：\(probe.hasFtst ? "存在（M3/M4 需解锁）" : "不存在（可直接写 F0Tg）")")

        for key in [SMCKeyName.fanActual(index), SMCKeyName.fanTarget(index),
                    SMCKeyName.fanMin(index), SMCKeyName.fanMax(index)] {
            if let info = try? smc.keyInfo(key), let value = try? smc.readKey(key) {
                out(String(format: "  %@  %@  %.0f  attr=0x%02X", key, info.dataType, value, info.dataAttributes))
            } else {
                out("  \(key)  不存在")
            }
        }

        if let state = try? driver.state(fanIndex: index) {
            out("  状态：实际 \(String(format: "%.0f", state.actualRpm)) / 目标 \(String(format: "%.0f", state.targetRpm)) RPM，"
                + "区间 \(String(format: "%.0f", state.minRpm))–\(String(format: "%.0f", state.maxRpm))，"
                + "模式 \(state.mode.rawValue)")
            // 冲突自检：手动模式是「有程序在写」的硬证据（系统自己不会进手动）。
            if state.isManual {
                out("  ⚠ 当前处于手动模式：若 FunFan 没在运行，说明有其他程序持有控制权"
                    + "（Macs Fan Control / TG Pro 等）。FunFan 启动时会拒绝接管并提示，避免互相覆盖。")
            }
            if index == 0 {
                let limits = state.limits
                let suggested = (limits.minRpm + limits.normalizedMax) / 2
                out("  建议验证目标：\(String(format: "%.0f", suggested)) RPM（区间中点）")
            }
        } else {
            out("  ✗ 读取状态失败")
        }
    }

    out("")
    // 写入能力实测：幂等写（把 F0Tg 写成它已有的值），行为零变化
    switch probeWriteCapability(smc: smc, fanIndex: 0) {
    case .success:
        out("写入能力：✓ 当前进程可写 SMC\(isRoot ? "" : "（非 root 也能写，属例外情况）")")
    case .failure(let reason):
        out("写入能力：✗ \(reason)")
    }

    out("")
    out("结论：\(isRoot ? "具备写入条件，可以执行 sudo funfanctl spin 验证" : "仅可监控；写入需 sudo")")
}

// MARK: - topology

/// 打印芯片真实核心数（来自 sysctl / IORegistry，不是 SMC 温度键倒推）。
/// 用于核对「展开面板里的 CPU/GPU 个数」是否与系统接口一致。
func runTopology() {
    let probe = SystemTopologyProbe()
    guard let topo = probe.read() else {
        err("✗ 无法读取芯片拓扑（sysctl / IORegistry 均不可用）。")
        exit(1)
    }
    out("=== 芯片真实拓扑（核心数来自系统接口，非 SMC 倒推） ===")
    out("芯片：\(topo.chipName)")
    out("CPU：\(topo.totalCPUCores) 核（性能 \(topo.performanceCores) + 能效 \(topo.efficiencyCores)）")
    out("GPU：\(topo.gpuCores) 核")
}

/// 幂等写入探测：写入当前已有的目标值，不改变任何行为。
/// 目的只是判断「本进程是否有写权限」，而不是真的控制风扇。
enum WriteCapability {
    case success
    case failure(String)
}

func probeWriteCapability(smc: SMCService, fanIndex: Int) -> WriteCapability {
    let key = SMCKeyName.fanTarget(fanIndex)
    guard let current = try? smc.readKey(key) else {
        return .failure("无法读取 \(key)")
    }
    do {
        try smc.writeKey(key, value: current)
        return .success
    } catch {
        return .failure(describe(error))
    }
}

// MARK: - status

func runStatus() {
    guard let smc = openSMC() else { exit(1) }
    defer { smc.close() }

    let driver = FanHardwareDriver(device: smc)
    let count = driver.fanCount()
    out("风扇数量：\(count)")
    for index in 0..<count {
        guard let state = try? driver.state(fanIndex: index) else { continue }
        // `restoreAuto` 刻意只写模式键、绝不写 `F0Tg`（写目标反而可能把风扇拉起来），
        // 所以返还之后 `F0Tg` 会留着上一次的值。不标注的话，输出看起来像
        // 「模式 automatic 但目标还是 1842」，非常容易被误读成「没返还干净」。
        let target = state.isManual
            ? String(format: "%.0f", state.targetRpm)
            : String(format: "%.0f（残留值，未生效）", state.targetRpm)
        out(String(format: "Fan %d: 实际 %.0f  目标 %@  区间 %.0f–%.0f  模式 %@",
                   index, state.actualRpm, target, state.minRpm, state.maxRpm, state.mode.rawValue))
    }
}

// MARK: - spin / set / restore

func runSpin(args: [String]) {
    guard requireRoot("spin") else { exit(1) }
    guard let smc = openSMC() else { exit(1) }
    defer { smc.close() }

    let fanIndex = intOption("--fan", in: args) ?? 0
    let seconds = doubleOption("--seconds", in: args) ?? 6
    let driver = FanHardwareDriver(device: smc)

    guard driver.fanCount() > 0 else {
        err("✗ 本机没有风扇，无写入目标。")
        exit(1)
    }

    guard let before = try? driver.state(fanIndex: fanIndex) else {
        err("✗ 读取风扇状态失败")
        exit(1)
    }
    let limits = before.limits
    guard limits.isUsable else {
        err("✗ 风扇上下限异常（\(limits.minRpm)–\(limits.maxRpm)），拒绝写入。")
        exit(1)
    }

    let midpoint = (limits.minRpm + limits.normalizedMax) / 2
    var target = doubleOption("--rpm", in: args) ?? midpoint
    target = min(max(target, limits.minRpm), limits.normalizedMax)

    out("=== FunFan spin（写入验证）===")
    out(String(format: "机位 Fan %d｜当前 %.0f RPM｜区间 %.0f–%.0f", fanIndex, before.actualRpm, limits.minRpm, limits.normalizedMax))
    out(String(format: "目标 %.0f RPM，持续 %.0f s，结束后自动返还系统自动", target, seconds))
    out("")

    var restored = false
    func restore() {
        guard !restored else { return }
        restored = true
        do {
            try driver.restoreAuto(fanIndex: fanIndex)
            out("✓ 已返还系统自动控制")
        } catch {
            err("✗ 返还失败：\(describe(error))  ← 如风扇仍异常，请运行 sudo funfanctl restore")
        }
    }
    defer { restore() }

    do {
        let state = try driver.setTarget(fanIndex: fanIndex, rpm: target, limits: limits)
        out(String(format: "✓ 已写入目标 %.0f（写后目标读回 %.0f，模式 %@）",
                   target, state.targetRpm, state.mode.rawValue))
    } catch {
        err("✗ 写入失败：\(describe(error))")
        exit(1)
    }

    out("")
    out("观测 F0Ac（实际转速）收敛过程：")
    let deadline = Date().addingTimeInterval(seconds)
    var samples: [Double] = []
    while Date() < deadline && !interrupted {
        if let actual = try? smc.readKey(SMCKeyName.fanActual(fanIndex)) {
            samples.append(actual)
            let barLength = Int(max(0, min(40, (actual - limits.minRpm) / max(1, limits.normalizedMax - limits.minRpm) * 40)))
            out(String(format: "  %.0f RPM  %@", actual, String(repeating: "█", count: barLength)))
        }
        Thread.sleep(forTimeInterval: 0.5)
    }

    if interrupted { err("\n[!] 收到中断信号，立即返还。") }

    out("")
    guard !samples.isEmpty else {
        err("⚠ 未采集到任何转速样本")
        return
    }

    // 判定依据：**收敛后的稳态值**，而不是峰值。
    // 风扇起飞瞬间会过冲（实测 2950 目标冲到 3396 再回落），过冲是正常的 PID/惯性行为，
    // 拿峰值判定会把成功误判成失败。
    let tolerance = max(150, target * 0.05)
    let tail = samples.suffix(min(5, samples.count))
    let steady = tail.reduce(0, +) / Double(tail.count)

    out(String(format: "目标 %.0f RPM｜峰值 %.0f RPM｜稳态（末 %d 次均值）%.0f RPM",
               target, samples.max()!, tail.count, steady))

    if abs(steady - target) <= tolerance {
        out(String(format: "✓ 已收敛到目标（偏差 %.0f RPM，容差 %.0f）—— 写入链路验证通过", abs(steady - target), tolerance))
        if let peak = samples.max(), peak > target + tolerance {
            out(String(format: "  备注：起飞瞬间过冲至 %.0f RPM，属正常风扇惯性，无需处理", peak))
        }
    } else {
        // 失败原因要能区分：是被系统回收（模式回到自动），还是单纯没跟上
        let modeKey = driver.probe(fanIndex: fanIndex).modeKey
        let modeValue = modeKey.flatMap { try? smc.readKey($0) }
        if let modeValue, modeValue == 0 {
            out("⚠ 未收敛，且模式已被重置为自动 → thermalmonitord 回收了手动接管")
            out("  对策：M5 的 helper 需周期性重断言模式键（租约看门狗内每 1 s 重写一次）")
        } else {
            out(String(format: "⚠ 未收敛（稳态 %.0f 距目标 %.0f 超出容差 %.0f），但模式仍为手动", steady, target, tolerance))
            out("  可能原因：目标超出该风扇实际可承载范围，或转速变化被固件限速")
        }
    }
}

func runSet(args: [String]) {
    guard requireRoot("set") else { exit(1) }
    guard let rpmText = args.dropFirst().first(where: { !$0.hasPrefix("--") && Double($0) != nil }),
          let rpm = Double(rpmText) else {
        err("用法：sudo funfanctl set <rpm> [--fan N]")
        exit(1)
    }
    guard let smc = openSMC() else { exit(1) }
    defer { smc.close() }

    let fanIndex = intOption("--fan", in: args) ?? 0
    let driver = FanHardwareDriver(device: smc)

    do {
        let state = try driver.state(fanIndex: fanIndex)
        let limits = state.limits
        let applied = try driver.setTarget(fanIndex: fanIndex, rpm: rpm, limits: limits)
        out(String(format: "✓ 已设为 %.0f RPM（实际 %.0f，目标 %.0f）",
                   rpm, applied.actualRpm, applied.targetRpm))
        out("⚠ 现在是手动模式会持续保持。完成后请运行： sudo funfanctl restore")
    } catch {
        err("✗ 设置失败：\(describe(error))")
        exit(1)
    }
}

/// 系统信息采集：把「这台机器能不能做某事」逐条实测出来，输出可直接贴进 issue 的报告。
///
/// 用法：
///   funfanctl diagnose            人读版（Markdown）
///   funfanctl diagnose --json     机读版
///   funfanctl diagnose --save     额外落盘到 ~/Library/Application Support/FunFan/diagnostics/
func runDiagnose(args: [String]) {
    let report = SystemInfoCollector.collect(
        reason: optionValue("--reason", in: args) ?? "手动诊断（funfanctl diagnose）"
    )

    if args.contains("--json") {
        out(report.json)
    } else {
        out(report.markdown)
        if report.hasFailures {
            err("")
            err("✗ 存在失败项，报告已包含排查建议。")
        }
    }

    if args.contains("--save"), let url = SystemInfoCollector.save(report, to: SystemInfoCollector.defaultDirectory()) {
        err("已保存：\(url.path)")
    }

    exit(report.hasFailures ? 2 : 0)
}

func runRestore(args: [String]) {
    guard requireRoot("restore") else { exit(1) }
    guard let smc = openSMC() else { exit(1) }
    defer { smc.close() }

    let fanIndex = intOption("--fan", in: args) ?? 0
    let driver = FanHardwareDriver(device: smc)
    do {
        try driver.restoreAuto(fanIndex: fanIndex)
        let state = try? driver.state(fanIndex: fanIndex)
        out("✓ 已返还系统自动控制（模式 \(state?.mode.rawValue ?? "?")）")
    } catch {
        err("✗ 返还失败：\(describe(error))")
        exit(1)
    }
}

// MARK: - raw（原始字节 + 候选解码，用于未支持类型取证）

/// 对一段原始字节给出所有常见解释，便于肉眼比对哪个才合理。
///
/// 只在 `raw` 命令里用，不参与正常读取路径——生产解码必须走 `SMCDataCodec`。
func candidateInterpretations(_ bytes: [UInt8]) -> [(String, Double)] {
    var result: [(String, Double)] = []

    if bytes.count >= 8 {
        // ioft 的标准解释：小端 48.16 定点（有符号，能识别高位全 1 的哨兵值）
        var raw: UInt64 = 0
        for index in 0..<8 { raw |= UInt64(bytes[index]) << (UInt64(index) * 8) }
        result.append(("i48.16-LE", Double(Int64(bitPattern: raw)) / 65_536))
        result.append(("u48.16-LE", Double(raw) / 65_536))
        result.append(("u64-LE", Double(raw)))
    }
    if bytes.count >= 4 {
        let le = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
        let be = UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
        result.append(("f32-LE", Double(Float(bitPattern: le))))
        result.append(("f32-BE", Double(Float(bitPattern: be))))
        result.append(("u32-BE", Double(be)))
        result.append(("u32-LE", Double(le)))
        result.append(("i32-BE/256", Double(Int32(bitPattern: be)) / 256))
        result.append(("i32-BE/65536", Double(Int32(bitPattern: be)) / 65536))
    }
    if bytes.count >= 2 {
        let be = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        let le = UInt16(bytes[1]) << 8 | UInt16(bytes[0])
        result.append(("u16-BE", Double(be)))
        result.append(("i16-BE/256", Double(Int16(bitPattern: be)) / 256))
        result.append(("u16-LE", Double(le)))
    }
    if let first = bytes.first {
        result.append(("u8", Double(first)))
    }
    return result
}

func runRaw(args: [String]) {
    guard let smc = openSMC() else { exit(1) }
    defer { smc.close() }

    var keys: [String] = []
    if let type = optionValue("--type", in: args) {
        // 按类型扫全表：排查「哪些键用了我们还不支持的类型」
        let all = (try? smc.allKeys()) ?? []
        keys = all.filter { (try? smc.keyInfo($0))?.dataType == type }
        guard !keys.isEmpty else {
            out("没有类型为 \(type) 的键")
            return
        }
        out("类型 \(type) 共 \(keys.count) 个键\n")
    } else {
        keys = args.dropFirst().filter { !$0.hasPrefix("--") }
    }

    guard !keys.isEmpty else {
        err("用法：funfanctl raw <KEY>...   或   funfanctl raw --type <四字符类型>")
        exit(1)
    }

    for key in keys {
        guard let info = try? smc.keyInfo(key) else {
            out("\(key)\t<无此键>")
            continue
        }
        let bytes = (try? smc.readRawBytes(key)) ?? []
        let hex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
        let decoded = SMCDataCodec.decode(type: info.dataType, bytes: bytes)
            .map { String(format: "%.3f", $0) } ?? "—"

        out("\(key)  type=\(info.dataType)  \(info.dataSize)B  [\(hex)]  现行解码=\(decoded)")
        for (label, value) in candidateInterpretations(bytes) {
            out(String(format: "      %-12@ %12.3f", label, value))
        }
    }
}

// MARK: - 入口

extension ProcessInfo {
    /// 机型标识（如 Mac14,13），用于 doctor 报告。
    var machineHardwareName: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }

    /// 芯片名（如 "Apple M4"）。`hw.model` 只给编号，排障时不够直观。
    var chipName: String {
        sysctlString("machdep.cpu.brand_string") ?? "未知"
    }

    /// 进程架构，区分 Rosetta 下运行（那会让 SMC 访问表现异常，值得一眼看见）。
    var architectureLabel: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return isTranslated ? "x86_64（Rosetta）" : "x86_64"
        #else
        return "unknown"
        #endif
    }
}

/// 读一个字符串型 sysctl；失败返回 nil（不 throw，doctor 不该因为一项读不到就中断）。
func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
    return String(cString: buffer)
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    usage()
    exit(0)
}

switch command {
case "diagnose": runDiagnose(args: args)
case "raw":     runRaw(args: args)
case "doctor":  runDoctor()
case "topology": runTopology()
case "status":  runStatus()
case "spin":    runSpin(args: args)
case "set":     runSet(args: args)
case "restore": runRestore(args: args)
case "-h", "--help", "help": usage()
default:
    err("未知命令：\(command)")
    usage()
    exit(1)
}
