import Foundation

/// 能力状态：诊断报告里每一条「这台机器能不能做这件事」的结论。
public enum CapabilityStatus: String, Codable, CaseIterable {
    /// 一切正常
    case ok
    /// 能用，但有前提或降级（例如「写入需 root」）
    case degraded
    /// 本机硬件/系统不支持（例如台式机没有盖子）
    case unsupported
    /// 期望能用但失败了——这是要修的部分
    case failed

    public var symbol: String {
        switch self {
        case .ok: return "✓"
        case .degraded: return "!"
        case .unsupported: return "–"
        case .failed: return "✗"
        }
    }

    public var label: String {
        switch self {
        case .ok: return "正常"
        case .degraded: return "降级"
        case .unsupported: return "不适用"
        case .failed: return "失败"
        }
    }

    /// 是否需要在报告里显著提示（失败/降级排前面）。
    var severity: Int {
        switch self {
        case .failed: return 0
        case .degraded: return 1
        case .unsupported: return 2
        case .ok: return 3
        }
    }
}

/// 单条能力探测结果。
public struct Capability: Codable, Equatable {
    /// 稳定标识，便于按 id 做回归对比（`smc.open` / `fan.write` …）。
    public let id: String
    public let title: String
    public let status: CapabilityStatus
    /// 本机实测到什么。
    public let detail: String
    /// 出问题时该往哪查（ok 时通常为 nil）。
    public let hint: String?

    public init(id: String, title: String, status: CapabilityStatus, detail: String, hint: String? = nil) {
        self.id = id
        self.title = title
        self.status = status
        self.detail = detail
        self.hint = hint
    }
}

/// helper 安装/运行状态（bug 报告里最常需要的一块）。
public struct HelperDiagnosis: Codable, Equatable {
    public var binaryInstalled: Bool
    public var plistInstalled: Bool
    public var logTail: [String]

    public init(binaryInstalled: Bool = false, plistInstalled: Bool = false, logTail: [String] = []) {
        self.binaryInstalled = binaryInstalled
        self.plistInstalled = plistInstalled
        self.logTail = logTail
    }

    public var summary: String {
        switch (binaryInstalled, plistInstalled) {
        case (true, true): return "已安装（二进制 + LaunchDaemon）"
        case (true, false): return "只装了二进制，缺 LaunchDaemon plist"
        case (false, true): return "有 plist 但缺二进制"
        case (false, false): return "未安装"
        }
    }
}

/// 显示器探测结果——合盖判定要用，也顺手写进报告。
public struct DisplayProbe: Codable, Equatable {
    public var builtinOnline: Bool
    public var externalOnline: Bool
    public var totalOnline: Int

    public init(builtinOnline: Bool = false, externalOnline: Bool = false, totalOnline: Int = 0) {
        self.builtinOnline = builtinOnline
        self.externalOnline = externalOnline
        self.totalOnline = totalOnline
    }

    public var summary: String {
        "在线 \(totalOnline) 块（内建 \(builtinOnline ? "有" : "无")，外接 \(externalOnline ? "有" : "无")）"
    }
}

/// 环境快照：与具体能力无关的“这台机器是什么”。
public struct SystemSnapshot: Codable, Equatable {
    public var appVersion: String
    public var macOSVersion: String
    public var osBuild: String
    public var architecture: String
    public var hardwareModel: String
    public var chipName: String
    public var isRoot: Bool
    public var isPortable: Bool
    public var hasBattery: Bool
    public var fanCount: Int?
    public var fanRange: String?
    public var smcKeyCount: Int?
    public var temperatureKeyCount: Int?
    public var displays: DisplayProbe
    public var helper: HelperDiagnosis

    public init(
        appVersion: String = "dev",
        macOSVersion: String = "—",
        osBuild: String = "—",
        architecture: String = "—",
        hardwareModel: String = "—",
        chipName: String = "—",
        isRoot: Bool = false,
        isPortable: Bool = false,
        hasBattery: Bool = false,
        fanCount: Int? = nil,
        fanRange: String? = nil,
        smcKeyCount: Int? = nil,
        temperatureKeyCount: Int? = nil,
        displays: DisplayProbe = DisplayProbe(),
        helper: HelperDiagnosis = HelperDiagnosis()
    ) {
        self.appVersion = appVersion
        self.macOSVersion = macOSVersion
        self.osBuild = osBuild
        self.architecture = architecture
        self.hardwareModel = hardwareModel
        self.chipName = chipName
        self.isRoot = isRoot
        self.isPortable = isPortable
        self.hasBattery = hasBattery
        self.fanCount = fanCount
        self.fanRange = fanRange
        self.smcKeyCount = smcKeyCount
        self.temperatureKeyCount = temperatureKeyCount
        self.displays = displays
        self.helper = helper
    }
}

/// 一份完整诊断报告：能直接贴进 issue 的那种。
public struct DiagnosticReport: Codable, Equatable {

    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let generatedAt: Date
    /// 为什么采这份报告（「helper 不可用」/ 用户手动触发…）。
    public let reason: String
    public let system: SystemSnapshot
    public let capabilities: [Capability]
    /// 额外的自由文本上下文（错误链、日志尾部、当时的参数…）。
    public let context: [String: String]

    public init(
        generatedAt: Date = Date(),
        reason: String,
        system: SystemSnapshot,
        capabilities: [Capability],
        context: [String: String] = [:]
    ) {
        self.schemaVersion = Self.schemaVersion
        self.generatedAt = generatedAt
        self.reason = reason
        self.system = system
        self.capabilities = capabilities
        self.context = context
    }

    /// 有没有需要修的东西。
    public var hasFailures: Bool {
        capabilities.contains { $0.status == .failed }
    }

    // MARK: - 渲染

    public var markdown: String {
        var lines: [String] = []

        lines.append("# FunFan 诊断报告")
        lines.append("")
        lines.append("- 生成时间：\(Self.iso.string(from: generatedAt))")
        lines.append("- 触发原因：\(reason)")
        lines.append("- 结论：\(headline)")
        lines.append("")

        lines.append("## 系统")
        lines.append("")
        lines.append("| 项目 | 值 |")
        lines.append("| --- | --- |")
        for (key, value) in systemRows {
            lines.append("| \(key) | \(value) |")
        }
        lines.append("")

        lines.append("## 能力")
        lines.append("")
        lines.append("| 状态 | 能力 | 实测 | 排查建议 |")
        lines.append("| --- | --- | --- | --- |")
        for capability in sortedCapabilities {
            let hint = capability.hint.map(escapeCell) ?? "—"
            lines.append("| \(capability.status.symbol) \(capability.status.label) | \(capability.title) | \(escapeCell(capability.detail)) | \(hint) |")
        }

        if !context.isEmpty {
            lines.append("")
            lines.append("## 附加上下文")
            lines.append("")
            lines.append("```")
            for key in context.keys.sorted() {
                lines.append("\(key): \(context[key] ?? "")")
            }
            lines.append("```")
        }

        if !system.helper.logTail.isEmpty {
            lines.append("")
            lines.append("## helper 日志（末尾）")
            lines.append("")
            lines.append("```")
            lines.append(contentsOf: system.helper.logTail)
            lines.append("```")
        }

        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// 结构化版：给脚本/回归对比用（键排序、日期 ISO8601）。
    public var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - 内部

    private var headline: String {
        let failed = capabilities.filter { $0.status == .failed }
        if failed.isEmpty {
            let degraded = capabilities.filter { $0.status == .degraded }
            return degraded.isEmpty ? "全部能力正常" : "无失败，\(degraded.count) 项降级"
        }
        return "\(failed.count) 项失败：\(failed.map(\.title).joined(separator: "、"))"
    }

    /// 失败的排前面，其余保持采集顺序——看报告时先看到要修的东西。
    private var sortedCapabilities: [Capability] {
        capabilities.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.status.severity != rhs.element.status.severity {
                    return lhs.element.status.severity < rhs.element.status.severity
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    private var systemRows: [(String, String)] {
        [
            ("FunFan", system.appVersion),
            ("macOS", "\(system.macOSVersion) (\(system.osBuild))"),
            ("架构", system.architecture),
            ("机型", system.hardwareModel),
            ("芯片", system.chipName),
            ("笔记本", system.isPortable ? "是" : "否"),
            ("电池", system.hasBattery ? "有" : "无"),
            ("风扇", system.fanCount.map { "\($0) 个" } ?? "未读到"),
            ("转速区间", system.fanRange ?? "—"),
            ("SMC 键总数", system.smcKeyCount.map(String.init) ?? "未读到"),
            ("温度传感器", system.temperatureKeyCount.map { "\($0) 个" } ?? "未读到"),
            ("显示器", system.displays.summary),
            ("helper", system.helper.summary),
            ("运行身份", system.isRoot ? "root" : "普通用户"),
        ]
    }

    private func escapeCell(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
