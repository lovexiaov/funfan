import Foundation

/// 宿主消失自退场（T20）。
///
/// 平台背景：macOS 没有「App 被卸载」回调——用户把 App 拖进废纸篓时，
/// App 侧没有任何机会跑代码。唯一能自己动手的是还活着的特权 daemon：
/// 它检测宿主 App 消失后清理自己，避免留下一个连着 SMC 的 root 进程。
///
/// 分工：本文件只放**纯逻辑**（路径推导、缺席计数、清理步骤序列），
/// 可单测；`FunFanHelper` 侧做薄壳执行（定时器 + FileManager + launchctl）。
///
/// 结构性局限（记录在案，不解决）：
/// - **脚本直装**（二进制在 `/Library/PrivilegedHelperTools`，独立于 App 包）：
///   App 删掉甚至重启之后 daemon 都能再跑起来，自清 100% 可靠；
/// - **App 包内安装**（脚本授权直装 / SMAppService，`BundleProgram`）：
///   二进制随 App 一起被删，只有「删除时 daemon 恰好还在运行」才有机会自清；
///   若用户「删 App → 重启」，launchd 拉不起不存在的文件，自清无从发生，
///   只会留一条指向空路径的后台项（无害，但难看）。
public enum HelperSelfCleanup {

    // MARK: - 宿主路径推导

    /// 从 helper 可执行文件路径推导宿主 App 包路径。
    ///
    /// App 包内安装的 daemon 一定长在 `<宿主>.app/Contents/MacOS/` 下，
    /// 由此反推宿主；不在这种结构里（脚本直装的裸二进制）返回 nil——
    /// 表示「不知道宿主在哪」，调用方应关闭自清而不是猜。
    ///
    /// 判据是精确的路径结构（`.app` 结尾 + `/Contents/MacOS/` 分隔），
    /// 目录名里碰巧带 `.app` 的备份目录（如 `FunFan.app.backup`）不算。
    public static func hostAppBundlePath(executablePath: String) -> String? {
        let marker = "/Contents/MacOS/"
        guard let range = executablePath.range(of: marker) else { return nil }
        let prefix = String(executablePath[..<range.lowerBound])
        guard prefix.hasSuffix(".app"), !prefix.isEmpty else { return nil }
        return prefix
    }

    // MARK: - 安装形态

    /// daemon 的两种安装形态，决定了「自己有哪些文件可删」。
    public enum InstallVariant: Equatable {
        /// 脚本直装：二进制、plist、日志都是独立文件，全部可自删。
        case script(binaryPath: String, plistPath: String, logPath: String)
        /// App 包内安装（授权直装 / SMAppService）：二进制随 App 包生灭。
        /// 可清理的：授权直装写下的 plist（SMAppService 安装没有这个文件，
        /// 删不存在的路径是无害的 no-op）、各条注册路径的日志。
        /// SMAppService 与授权直装的日志落点不同，调用方把两处都传进来。
        case appEmbedded(plistPath: String, logPaths: [String])
    }

    // MARK: - 清理步骤

    public enum Step: Equatable {
        /// 删除一个文件（文件不存在时调用方应静默跳过）。
        case deleteFile(String)
        /// `launchctl bootout system/<label>`，**必须排最后**：
        /// bootout 会向本进程发 SIGTERM，之后没有机会再删任何东西。
        case bootout(label: String)
    }

    public struct Plan: Equatable {
        public let steps: [Step]
    }

    /// 生成有序的自清步骤。
    ///
    /// 顺序即语义：先删文件（运行中的进程 unlink 自己的可执行文件是安全的，
    /// 已映射的代码段不受影响），最后 bootout。
    public static func plan(variant: InstallVariant, label: String) -> Plan {
        switch variant {
        case .script(let binaryPath, let plistPath, let logPath):
            return Plan(steps: [
                .deleteFile(plistPath),
                .deleteFile(binaryPath),
                .deleteFile(logPath),
                .bootout(label: label),
            ])
        case .appEmbedded(let plistPath, let logPaths):
            return Plan(steps:
                [.deleteFile(plistPath)]
                    + logPaths.map { Step.deleteFile($0) }
                    + [.bootout(label: label)]
            )
        }
    }

    /// bootout 的 launchctl 调用参数（daemon 侧用 Process 执行，不走 shell）。
    public static func bootoutArguments(label: String) -> [String] {
        ["/bin/launchctl", "bootout", "system/\(label)"]
    }
}

/// 宿主连续缺席计数。
///
/// 为什么不能缺席一次就自毁：外置卷瞬时卸载、App 更新期的换包间隙，
/// 都会让宿主短暂「消失」。策略是**连续**缺席达到阈值才动手，
/// 中途见到宿主回来就清零。
public struct HostWatchState: Equatable {

    public private(set) var consecutiveMisses = 0

    public init() {}

    /// 记录一次检查结果。
    /// - Returns: 连续缺席已达到阈值（调用方应执行自清）。
    @discardableResult
    public mutating func record(hostPresent: Bool, threshold: Int) -> Bool {
        if hostPresent {
            consecutiveMisses = 0
            return false
        }
        consecutiveMisses += 1
        return consecutiveMisses >= threshold
    }
}
