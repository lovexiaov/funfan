import Foundation
import CoreGraphics
import Darwin

/// 环境信息采集接口。
///
/// 抽成协议是为了让「采集 → 报告」这段逻辑能在单测里跑（不需要真机、不需要 root）。
public protocol DiagnosticsProbing {
    func macOSVersion() -> String
    func osBuild() -> String
    func architecture() -> String
    func hardwareModel() -> String
    func chipName() -> String
    func isRoot() -> Bool
    func hasBattery() -> Bool
    func displays() -> DisplayProbe
    func helperDiagnosis() -> HelperDiagnosis
    /// 系统启动时间（kern.boottime）。用于判断「是不是刚重启完」——
    /// FunFan 作为登录项在开机后很快启动，此时探测到 helper 没自启基本就是重启导致。
    /// 拿不到（sysctl 失败）返回 nil，调用方据此「不编造结论」。
    func systemBootTime() -> Date?
}

/// 真实环境实现（sysctl / IOKit / CoreGraphics / 文件系统）。
public struct SystemProbe: DiagnosticsProbing {

    public init() {}

    public func macOSVersion() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    public func osBuild() -> String {
        Sysctl.string("kern.osversion") ?? "—"
    }

    public func architecture() -> String {
        var info = utsname()
        guard uname(&info) == 0 else { return "—" }
        return withUnsafeBytes(of: &info.machine) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
    }

    public func hardwareModel() -> String {
        Sysctl.string("hw.model") ?? "—"
    }

    public func chipName() -> String {
        Sysctl.string("machdep.cpu.brand_string") ?? "—"
    }

    public func isRoot() -> Bool {
        getuid() == 0
    }

    public func hasBattery() -> Bool {
        BatteryDetailParser.parse(AppleSmartBatteryReader.properties()).present
    }

    /// 系统启动时间：`kern.boottime` 是 `struct timeval`（Unix 纪元秒 + 微秒）。
    /// spawn/sysctl 失败返回 nil，绝不编造。
    public func systemBootTime() -> Date? {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 else { return nil }
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
    }

    /// 用「在线」显示列表：显示器休眠只是 active = false，合盖才是物理断电离线。
    public func displays() -> DisplayProbe {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else {
            return DisplayProbe()
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else {
            return DisplayProbe()
        }

        var probe = DisplayProbe(totalOnline: Int(count))
        for id in ids.prefix(Int(count)) {
            if CGDisplayIsBuiltin(id) != 0 {
                probe.builtinOnline = true
            } else {
                probe.externalOnline = true
            }
        }
        return probe
    }

    public func helperDiagnosis() -> HelperDiagnosis {
        let fileManager = FileManager.default
        return HelperDiagnosis(
            binaryInstalled: fileManager.fileExists(atPath: HelperPaths.binary),
            plistInstalled: fileManager.fileExists(atPath: HelperPaths.plist),
            launchdLoaded: Self.launchdLoaded(label: HelperPaths.machServiceName),
            logTail: Self.tail(of: HelperPaths.log, lines: 8)
        )
    }

    /// launchd 是否加载了该服务：`launchctl print system/<label>` 退出码。
    ///
    /// 普通用户就能读 system 域（真机验证过），不需要 root。
    /// spawn 失败返回 nil——分不清「没加载」和「没探成」时不要编造结论。
    /// HelperInstaller 的重启修复判定与诊断报告共用这一份事实来源。
    public static func launchdLoaded(label: String) -> Bool? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "system/\(label)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    // MARK: - 内部

    private static func tail(of path: String, lines: Int) -> [String] {
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else { return [] }
        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .suffix(lines)
            .map(String.init)
    }
}

/// helper 的安装路径（安装脚本、CLI、诊断三处共用同一份定义）。
public enum HelperPaths {
    /// 全部转发到 XPC 合约里的那份定义，避免路径在多处漂移。
    public static var machServiceName: String { HelperConstants.machServiceName }
    public static var binary: String { HelperConstants.installedBinaryPath }
    public static var plist: String { HelperConstants.installedPlistPath }
    public static var log: String { HelperConstants.logPath }
}

/// `sysctl` 读取（失败返回 nil，不抛错）。
enum Sysctl {
    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// 整型 sysctl（如 `hw.perflevel0.physicalcpu`）。失败或大小异常返回 nil。
    static func int(_ name: String) -> Int? {
        var value: Int = 0
        var size = MemoryLayout<Int>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }
}
