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
            logTail: Self.tail(of: HelperPaths.log, lines: 8)
        )
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
    /// Mach service 名沿用 XPC 合约里的定义，避免两处漂移。
    public static let machServiceName = HelperConstants.machServiceName
    public static let binary = "/Library/PrivilegedHelperTools/com.funfan.helper"
    public static let plist = "/Library/LaunchDaemons/com.funfan.helper.plist"
    public static let log = "/var/log/com.funfan.helper.log"
}

/// `sysctl` 字符串读取（失败返回 nil，不抛错）。
enum Sysctl {
    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
