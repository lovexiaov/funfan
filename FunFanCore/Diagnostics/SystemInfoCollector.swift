import Foundation

/// 需要「枚举全部键」的能力接口。
///
/// `SMCDevice` 只覆盖单键读写（够控制用），但诊断还想知道「这台机器到底有多少键、
/// 多少个温度键」，因此单独抽一个协议，`SMCService` 天然满足。
public protocol SMCCapabilitySource {
    func allKeys() throws -> [String]
}

extension SMCService: SMCCapabilitySource {}

/// 系统信息采集器：把「这台机器能不能做某件事」逐条实测出来。
///
/// 设计取向：**报错时最需要的信息优先**。所以除了环境快照，还会逐项给出
/// 能力状态（ok / 降级 / 不适用 / 失败）以及失败时该往哪查。
public enum SystemInfoCollector {

    /// 采集一份完整报告。
    ///
    /// - Parameters:
    ///   - reason: 为什么采（会写进报告，便于对照 issue）
    ///   - probe: 环境探针，默认真实系统；单测传假实现
    ///   - device: 已建立的 SMC 连接；传 nil 时按 `smcFactory` 自己开一条（只读，不需要 root）
    ///   - context: 额外上下文（错误链、参数、日志…）
    public static func collect(
        reason: String,
        probe: DiagnosticsProbing = SystemProbe(),
        device: (any SMCDevice & SMCCapabilitySource)? = nil,
        context: [String: String] = [:],
        now: Date = Date(),
        smcFactory: () throws -> any SMCDevice & SMCCapabilitySource = SystemInfoCollector.openSystemSMC
    ) -> DiagnosticReport {

        var capabilities: [Capability] = []
        var snapshot = SystemSnapshot(
            macOSVersion: probe.macOSVersion(),
            osBuild: probe.osBuild(),
            architecture: probe.architecture(),
            hardwareModel: probe.hardwareModel(),
            chipName: probe.chipName(),
            isRoot: probe.isRoot(),
            hasBattery: probe.hasBattery(),
            displays: probe.displays(),
            helper: probe.helperDiagnosis()
        )
        snapshot.isPortable = LidPolicy.isPortable(
            model: snapshot.hardwareModel,
            hasBattery: snapshot.hasBattery
        )

        // MARK: SMC 连接
        let source: (any SMCDevice & SMCCapabilitySource)?
        if let device {
            source = device
            capabilities.append(Capability(
                id: "smc.open", title: "SMC 连接", status: .ok,
                detail: "使用调用方已建立的连接"
            ))
        } else {
            do {
                let opened = try smcFactory()
                source = opened
                capabilities.append(Capability(
                    id: "smc.open", title: "SMC 连接", status: .ok,
                    detail: "AppleSMC 打开成功（结构体 \(MemoryLayout<SMCParamStruct>.size) 字节）"
                ))
            } catch {
                source = nil
                capabilities.append(Capability(
                    id: "smc.open", title: "SMC 连接", status: .failed,
                    detail: "打开 AppleSMC 失败：\(describe(error))",
                    hint: "读操作本不需要 root；失败通常是沙箱限制或系统版本变更，先确认非沙箱环境再跑一次"
                ))
            }
        }

        guard let smc = source else {
            // SMC 打不开时其余能力没法判定，直接标失败并说明因果
            capabilities.append(Capability(
                id: "smc.keys", title: "键枚举", status: .failed,
                detail: "SMC 不可用，未执行", hint: "先解决 smc.open"
            ))
            capabilities.append(Capability(
                id: "fan.describe", title: "风扇信息", status: .failed,
                detail: "SMC 不可用，未执行", hint: "先解决 smc.open"
            ))
            capabilities.append(Capability(
                id: "smc.temperature", title: "温度传感器", status: .failed,
                detail: "SMC 不可用，未执行", hint: "先解决 smc.open"
            ))
            appendNonSMCCapabilities(&capabilities, snapshot: snapshot)
            return DiagnosticReport(
                generatedAt: now, reason: reason, system: snapshot,
                capabilities: capabilities, context: context
            )
        }

        // MARK: 键枚举
        var allKeys: [String] = []
        do {
            allKeys = try smc.allKeys()
            snapshot.smcKeyCount = allKeys.count
            capabilities.append(Capability(
                id: "smc.keys", title: "键枚举", status: allKeys.isEmpty ? .failed : .ok,
                detail: "枚举到 \(allKeys.count) 个键",
                hint: allKeys.isEmpty ? "枚举为空通常意味着 #KEY 读取异常，附上本报告即可定位" : nil
            ))
        } catch {
            capabilities.append(Capability(
                id: "smc.keys", title: "键枚举", status: .failed,
                detail: "枚举失败：\(describe(error))",
                hint: "全键枚举依赖 #KEY 与 READ_INDEX 两个命令，失败信息很关键，请附本报告"
            ))
        }

        // MARK: 温度传感器
        let temperatureKeys = allKeys.isEmpty
            ? []
            : SensorCatalog.temperatureKeys(fromAllKeys: allKeys)
        snapshot.temperatureKeyCount = temperatureKeys.isEmpty ? nil : temperatureKeys.count
        if temperatureKeys.isEmpty {
            capabilities.append(Capability(
                id: "smc.temperature", title: "温度传感器", status: .failed,
                detail: "未发现任何 T* 温度键",
                hint: "检查键枚举是否为空；空枚举时温度键自然为 0"
            ))
        } else {
            var unreadable: [String] = []
            var readable = 0
            for key in temperatureKeys {
                if let value = try? smc.readKey(key), value.isFinite {
                    readable += 1
                } else {
                    unreadable.append(key)
                }
            }
            let status: CapabilityStatus = readable == 0
                ? .failed
                : (unreadable.isEmpty ? .ok : .degraded)

            // 读不出来的键名 + 类型必须写进报告：这是「换机型就少几个传感器」的根因线索
            var detail = "\(temperatureKeys.count) 个温度键，可读 \(readable) 个"
            if !unreadable.isEmpty {
                let names = unreadable.prefix(8)
                    .map { key in (try? smc.keyInfo(key)).map { "\(key)(\($0.dataType))" } ?? key }
                    .joined(separator: "、")
                let more = unreadable.count > 8 ? "…（共 \(unreadable.count) 个）" : ""
                detail += "；不可读：\(names)\(more)"
            }
            capabilities.append(Capability(
                id: "smc.temperature", title: "温度传感器", status: status,
                detail: detail,
                hint: readable == 0 ? "键全部读不出，多为数据类型未支持；请附本报告" : nil
            ))
        }

        // MARK: 风扇
        appendFanCapabilities(&capabilities, smc: smc, snapshot: &snapshot)
        appendNonSMCCapabilities(&capabilities, snapshot: snapshot)

        return DiagnosticReport(
            generatedAt: now, reason: reason, system: snapshot,
            capabilities: capabilities, context: context
        )
    }

    /// 便捷入口：采完直接落盘，返回文件路径（bug 报告就取这个文件）。
    @discardableResult
    public static func write(
        reason: String,
        context: [String: String] = [:],
        to directory: URL = defaultDirectory()
    ) -> URL? {
        save(collect(reason: reason, context: context), to: directory)
    }

    /// 把已有报告写成 Markdown 文件（文件名带时间戳）。
    @discardableResult
    public static func save(_ report: DiagnosticReport, to directory: URL) -> URL? {
        let fileManager = FileManager.default
        guard (try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)) != nil else {
            return nil
        }
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
        stamp.timeZone = .current   // 文件名用本地时间，方便和用户描述的「几点几分出错」对上
        let name = "diagnostic-\(stamp.string(from: report.generatedAt).replacingOccurrences(of: ":", with: "-")).md"
        let url = directory.appendingPathComponent(name)
        do {
            try report.markdown.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    /// 默认实现：开一条只读的 AppleSMC 连接。
    public static func openSystemSMC() throws -> any SMCDevice & SMCCapabilitySource {
        let service = SMCService()
        try service.open()
        return service
    }

    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return base.appendingPathComponent("FunFan/diagnostics", isDirectory: true)
    }

    // MARK: - 风扇能力

    private static func appendFanCapabilities(
        _ capabilities: inout [Capability],
        smc: any SMCDevice & SMCCapabilitySource,
        snapshot: inout SystemSnapshot
    ) {
        guard let rawCount = try? smc.readKey(SMCKeyName.fanCount) else {
            capabilities.append(Capability(
                id: "fan.describe", title: "风扇信息", status: .failed,
                detail: "读不到 \(SMCKeyName.fanCount)",
                hint: "风扇数量键缺失，通常说明机型无风扇（如部分 iPad 派生平台）或 SMC 接口变更"
            ))
            return
        }

        let count = Int(rawCount)
        snapshot.fanCount = count
        guard count > 0 else {
            capabilities.append(Capability(
                id: "fan.describe", title: "风扇信息", status: .unsupported,
                detail: "本机无风扇（\(SMCKeyName.fanCount) = 0）"
            ))
            return
        }

        // 逐风扇：区间 + 模式键 + 解锁键
        for index in 0..<count {
            let minRpm = try? smc.readKey(SMCKeyName.fanMin(index))
            let maxRpm = try? smc.readKey(SMCKeyName.fanMax(index))
            if index == 0, let minRpm, let maxRpm {
                snapshot.fanRange = String(format: "%.0f–%.0f RPM", minRpm, maxRpm)
            }
            capabilities.append(Capability(
                id: "fan.describe.\(index)", title: "风扇 \(index) 区间",
                status: (minRpm != nil && maxRpm != nil) ? .ok : .failed,
                detail: "\(format(minRpm))–\(format(maxRpm)) RPM",
                hint: (minRpm == nil || maxRpm == nil) ? "F\(index)Mn / F\(index)Mx 读不到，无法做安全 clamp" : nil
            ))

            let modeKeys = SMCKeyName.fanModeCandidates(index).filter { smc.keyExists($0) }
            capabilities.append(Capability(
                id: "fan.mode.\(index)", title: "风扇 \(index) 模式键",
                status: modeKeys.isEmpty ? .failed : .ok,
                detail: modeKeys.isEmpty
                    ? "候选 \(SMCKeyName.fanModeCandidates(index)) 均不存在"
                    : "存在 \(modeKeys.joined(separator: "、"))",
                hint: modeKeys.isEmpty ? "没有模式键就无法返还系统自动控制，这是必须修的项" : nil
            ))
        }

        let hasFtst = smc.keyExists(SMCKeyName.ftst)
        capabilities.append(Capability(
            id: "fan.unlock", title: "手动接管前置",
            status: .ok,
            detail: hasFtst
                ? "存在 Ftst，需要走解锁序列"
                : "无 Ftst，可直接写 \(SMCKeyName.fanTarget(0))"
        ))

        // 写入能力：root + 目标键可写属性（attr 0xD4 可写，0x84 只读）
        let targetKey = SMCKeyName.fanTarget(0)
        let attrHint: String
        if let info = try? smc.keyInfo(targetKey) {
            let writable = (info.dataAttributes & 0x40) != 0
            attrHint = String(format: "%@ attr=0x%02X（%@）", targetKey, info.dataAttributes, writable ? "可写" : "只读")
        } else {
            attrHint = "读不到 \(targetKey) 的键信息"
        }

        if snapshot.isRoot {
            capabilities.append(Capability(
                id: "fan.write", title: "风扇写入", status: .ok,
                detail: "以 root 运行；\(attrHint)"
            ))
        } else {
            capabilities.append(Capability(
                id: "fan.write", title: "风扇写入", status: .degraded,
                detail: "普通用户，SMC 写入会被拒绝；\(attrHint)",
                hint: "写操作必须 root：用 sudo 或经特权 helper"
            ))
        }

        // 只读自检：能读出当前转速才说明「监控」这条路是通的
        if let actual = try? smc.readKey(SMCKeyName.fanActual(0)) {
            capabilities.append(Capability(
                id: "fan.read", title: "转速读取", status: .ok,
                detail: String(format: "Fan 0 = %.0f RPM", actual)
            ))
        } else {
            capabilities.append(Capability(
                id: "fan.read", title: "转速读取", status: .failed,
                detail: "读不到 \(SMCKeyName.fanActual(0))",
                hint: "监控主指标读不到，基本等于不可用，需附本报告"
            ))
        }
    }

    // MARK: - 与 SMC 无关的能力（电量 / 合盖 / helper）

    private static func appendNonSMCCapabilities(
        _ capabilities: inout [Capability],
        snapshot: SystemSnapshot
    ) {
        capabilities.append(Capability(
            id: "battery", title: "电池",
            status: snapshot.hasBattery ? .ok : .unsupported,
            detail: snapshot.hasBattery ? "检测到电池（可读电量/健康度/功率）" : "无电池（台式机）"
        ))

        let lidStatus = LidPolicy.isClosed(
            builtinDisplayOnline: snapshot.displays.builtinOnline,
            externalDisplayOnline: snapshot.displays.externalOnline,
            isPortable: snapshot.isPortable
        )
        if !snapshot.isPortable {
            capabilities.append(Capability(
                id: "lid", title: "合盖检测", status: .unsupported,
                detail: "台式机无盖子（机型 \(snapshot.hardwareModel)，无电池）"
            ))
        } else if !snapshot.displays.builtinOnline && !snapshot.displays.externalOnline {
            capabilities.append(Capability(
                id: "lid", title: "合盖检测", status: .degraded,
                detail: "看不到任何在线显示器，退化依赖睡眠通知",
                hint: "无头/远程会话下显示器列表不可信，合盖判定只信 willSleep"
            ))
        } else {
            capabilities.append(Capability(
                id: "lid", title: "合盖检测",
                status: .ok,
                detail: "\(snapshot.displays.summary)，当前判定：\(lidStatus ? "合盖" : "开盖")"
            ))
        }

        let helper = snapshot.helper
        let helperStatus: CapabilityStatus
        let hint: String?
        switch (helper.binaryInstalled, helper.plistInstalled) {
        case (true, true):
            if helper.launchdLoaded == false {
                // issue #1 的关键场景：文件都在但 launchd 没加载——重启后必然不自启。
                // 文件存在不代表能自启，所以不能照旧给 .ok。
                helperStatus = .degraded
                hint = "plist 在盘上但 launchd 没加载。排查：sudo launchctl print-disabled system | grep \(HelperPaths.machServiceName)；"
                    + "临时修复：sudo launchctl bootstrap system \(HelperPaths.plist)"
            } else {
                helperStatus = .ok
                hint = nil
            }
        case (true, false):
            helperStatus = .failed
            hint = "缺 \(HelperPaths.plist)：重跑 sudo bash scripts/install-helper.sh"
        case (false, true):
            helperStatus = .failed
            hint = "缺二进制：重跑 sudo bash scripts/install-helper.sh"
        case (false, false):
            helperStatus = .degraded
            hint = "未安装 helper，只能监控；装：sudo bash scripts/install-helper.sh"
        }
        capabilities.append(Capability(
            id: "helper", title: "特权 helper", status: helperStatus,
            detail: helper.summary, hint: hint
        ))
    }

    // MARK: - 文案

    private static func format(_ value: Double?) -> String {
        value.map { String(format: "%.0f", $0) } ?? "n/a"
    }

    private static func describe(_ error: Error) -> String {
        guard let e = error as? FunFanError else { return "\(error)" }
        switch e {
        case .smcAccessDenied: return "SMC 访问被拒绝"
        case .keyNotFound(let key): return "键不存在：\(key)"
        case .dataTypeUnsupported(let type): return "数据类型不支持：\(type)"
        case .decodeFailed(let key, let type): return "解码失败：\(key) (\(type))"
        case .thermalManagerRefused: return "系统拒绝手动写入"
        case .helperUnavailable: return "helper 不可用"
        case .invalidTargetRpm(let rpm): return "非法目标转速：\(rpm)"
        }
    }
}
