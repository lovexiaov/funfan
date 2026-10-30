import Foundation
import FunFanCore

/// 特权组件的命令行入口（`--helper-status` / `--helper-install` / `--helper-uninstall`）。
///
/// 为什么 GUI 要带这几个参数：`SMAppService` 的注册只认「从 .app 里跑的进程」，
/// 而点按钮需要人坐在屏幕前。有了这三个开关，打包后可以脚本化验收：
///
///     dist/FunFan.app/Contents/MacOS/FunFan --helper-status
///     dist/FunFan.app/Contents/MacOS/FunFan --helper-install
///
/// 注意：必须直接跑 App 包里的可执行文件（而不是 `open -a`），
/// 才能拿到 stdout 与退出码；两者都有 Bundle.main = FunFan.app。
///
/// 每一行都「打印 + 落盘 + 立即 flush」：SMAppService 在受限环境里可能卡在
/// XPC 上没有返回，缓冲区不 flush 就什么也看不到，等于白跑一次。
enum HelperCLI {

    static let flags = ["--helper-status", "--helper-install", "--helper-uninstall"]

    /// 命中则执行并返回退出码；未命中返回 nil（继续正常启动 GUI）。
    static func runIfRequested() -> Int32? {
        let args = CommandLine.arguments
        guard let flag = flags.first(where: { args.contains($0) }) else { return nil }

        emit("=== \(flag) ===")
        emit("App 包：\(Bundle.main.bundleURL.path)")

        // Team ID 先报：后面「注册失败」十有八九要归因到签名。
        let team = CodeSigningInfo.ownTeamIdentifier()
        emit("签名 Team ID：\(team ?? "无（adhoc 签名）")")

        let supported = HelperInstaller.isSupported
        emit("系统注册能力：\(supported ? "可用" : "不可用 —— \(HelperInstaller.unsupportedReason)")")

        // 查询/注册动作放在最后：它可能卡住，前面的事实先落地。
        let installer = HelperInstaller()
        switch flag {
        case "--helper-install":
            installer.install(sync: true)
            waitForInstaller(installer)
        case "--helper-uninstall":
            installer.uninstall(sync: true)
            waitForInstaller(installer)
        default:
            installer.refresh()
        }

        // 两套记账要分开说：SMAppService 的注册状态与直装到 /Library 的那份无关，
        // 混在一起会出现「系统未找到」但风扇明明能控的矛盾输出。
        if installer.directInstallPresent {
            emit("后台组件：已直装到 \(HelperConstants.installedBinaryPath)")
            emit("launchd 运行中：\(HelperInstaller.daemonLoaded() ? "是" : "否")")
        } else if installer.status.isInstalled {
            emit("后台组件：已由系统登记（SMAppService）")
        } else {
            emit("后台组件：\(installer.status.title)")
        }
        if let note = installer.note {
            emit("说明：\(note)")
        }
        if !installer.directInstallPresent, let guidance = installer.status.guidance {
            emit("下一步：\(guidance)")
        }
        if let error = installer.error {
            emit("错误：\(error)")
        }

        // 退出码约定：0 = 已经能用；1 = 装了但没生效（待批准/未运行）；2 = 这个产物装不了
        if installer.status.isInstalled { return 0 }
        if installer.directInstallPresent { return HelperInstaller.daemonLoaded() ? 0 : 1 }
        if !HelperInstaller.canInstallAnyhow { return 2 }
        return 1
    }

    // MARK: - 输出

    /// 授权安装是异步的（`osascript` 子进程弹密码框），这里把主 runloop 转起来等它。
    ///
    /// 上限 5 分钟：够慢慢输密码，也不会在无人值守的脚本里无限挂住。
    private static func waitForInstaller(_ installer: HelperInstaller) {
        guard installer.isBusy else { return }
        emit("等待管理员授权（系统会弹出密码框）…")
        let deadline = Date().addingTimeInterval(300)
        while installer.isBusy, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        if installer.isBusy {
            emit("超时：5 分钟内没有完成授权。")
        }
    }

    /// 打印 + 追加落盘 + flush。
    private static func emit(_ line: String) {
        print(line)
        fflush(stdout)
        append(line)
    }

    /// `~/Library/Application Support/FunFan/helper-cli.log`。
    /// 用 `open --args` 启动时没有可见 stdout，用户报障也需要这一段。
    private static func append(_ line: String) {
        let fm = FileManager.default
        guard let support = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return }
        let directory = support.appendingPathComponent("FunFan", isDirectory: true)
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("helper-cli.log")

        let stamp = ISO8601DateFormatter().string(from: Date())
        let text = "[\(stamp)] \(line)\n"
        guard let data = text.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: file, options: .atomic)
        }
    }
}
