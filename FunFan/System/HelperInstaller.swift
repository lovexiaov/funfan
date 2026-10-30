import Foundation
import AppKit
import Combine
import ServiceManagement
import FunFanCore

/// 特权组件（root LaunchDaemon）的安装、卸载与状态。
///
/// 两条安装路径，UI 上合并成**一个**按钮：
///
/// 1. `SMAppService.daemon` —— 正式路径。系统登记一次，升级 App 不用重新授权，
///    卸载 App 时后台项一起清掉。前提是 Developer ID 签名 + 包内有 daemon plist。
/// 2. 管理员授权直装 —— 开发/adhoc 包、以及「已经用旧脚本装过」的机器。
///    用 `do shell script … with administrator privileges` 让系统弹一次密码框，
///    然后落盘到 `/Library/PrivilegedHelperTools` + `launchctl bootstrap`。
///
/// 为什么必须有第二条：`SMAppService` 在 adhoc 签名下**能注册但启动不了**，
/// 而让人去终端敲 `sudo bash scripts/install-helper.sh` 是最容易被放弃的一步。
/// 两条路都走不通时才报错，并说清缺什么。
final class HelperInstaller: ObservableObject {

    static let daemonPlistName = "com.funfan.helper.plist"

    @Published private(set) var status: HelperInstallStatus = .notFound
    @Published private(set) var error: String?
    /// 非错误的过程说明（「系统注册不可用，已改用管理员安装」这类）。
    @Published private(set) var note: String?
    @Published private(set) var isBusy = false
    /// 每次安装/卸载真正生效后 +1：AppDelegate 据此重连 helper、刷新控制能力。
    @Published private(set) var completionTick = 0
    /// 直装那份（`/Library/PrivilegedHelperTools`）当前是否存在。
    @Published private(set) var directInstallPresent = HelperInstaller.directInstallDetected()

    private var service: SMAppService?

    init() {
        service = Self.makeService()
        status = Self.currentStatus()
        directInstallPresent = Self.directInstallDetected()
    }

    // MARK: - 环境

    /// 构造系统的 daemon 注册器；不满足前提时返回 nil。
    static func makeService() -> SMAppService? {
        guard Bundle.main.bundleIdentifier != nil,
              Bundle.main.bundlePath.hasSuffix(".app") else { return nil }
        let plist = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchDaemons/\(daemonPlistName)")
        guard FileManager.default.fileExists(atPath: plist.path) else { return nil }
        return SMAppService.daemon(plistName: daemonPlistName)
    }

    /// 系统注册是否可用（不等于「一定能成功」，adhoc 包会在 register 时才暴露）。
    static var isSupported: Bool { makeService() != nil }

    /// 管理员授权安装是否可用：包内（或产物目录）得有一个能跑的 helper。
    static var canInstallWithAdministrator: Bool { administratorHelperSource() != nil }

    /// 任意一条路可走，UI 就该给「一键安装」按钮。
    static var canInstallAnyhow: Bool { isSupported || canInstallWithAdministrator }

    static var unsupportedReason: String {
        guard administratorHelperSource() != nil else {
            return "这个构建产物里没有 FunFanHelper 可执行文件，无法安装后台组件。请重新 make app。"
        }
        return "当前以开发模式运行（裸二进制），系统无法登记后台组件，只能用管理员授权方式直装。"
    }

    /// helper 可执行文件来源。
    ///
    /// 两种布局都要支持：`.app/Contents/MacOS/FunFanHelper`（分发形态），
    /// 以及和主可执行文件同目录（`make run` 跑的 SPM 裸二进制）。
    static func administratorHelperSource() -> String? {
        var candidates: [URL] = []
        if Bundle.main.bundlePath.hasSuffix(".app") {
            candidates.append(
                Bundle.main.bundleURL
                    .appendingPathComponent("Contents/MacOS/FunFanHelper")
            )
        }
        if let executable = Bundle.main.executableURL {
            candidates.append(
                executable.deletingLastPathComponent()
                    .appendingPathComponent("FunFanHelper")
            )
        }
        return candidates
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }?
            .path
    }

    static func currentStatus() -> HelperInstallStatus {
        guard let service = makeService() else { return .notFound }
        return HelperInstallStatus(rawStatus: service.status.rawValue)
    }

    /// 直装那份是否在盘上。与 SMAppService 注册是两套记账，必须分开看。
    static func directInstallDetected() -> Bool {
        FileManager.default.fileExists(atPath: HelperConstants.installedBinaryPath)
            || FileManager.default.fileExists(atPath: HelperConstants.installedPlistPath)
    }

    /// launchd 是否真的把服务拉起来了（比状态枚举更硬的事实）。
    static func daemonLoaded() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "system/\(HelperConstants.machServiceName)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// 旧脚本安装：同一路径、同一 label，必须先覆盖或卸载才能换装。
    static var legacyInstallDetected: Bool { directInstallDetected() }

    // MARK: - 安装

    /// 统一入口：能用系统注册就用，不行就管理员授权直装。
    ///
    /// 真正的工作默认推到下一个 runloop，让「安装中…」先画出来；
    /// CLI 传 `sync: true` —— 它没有 UI 要刷新，直接在当前栈上跑更好定位问题。
    /// 注意授权安装本身仍是异步的（`osascript` 子进程），所以两条路径返回时
    /// `isBusy` 都可能还是 true，调用方要看这个标志判断是否还在进行。
    func install(sync: Bool = false) {
        guard !isBusy else { return }
        error = nil
        note = nil
        isBusy = true
        if sync {
            performInstall(allowPasswordPrompt: true)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.performInstall(allowPasswordPrompt: true)
            }
        }
    }

    /// 安装主体。
    ///
    /// - Parameter allowPasswordPrompt: CLI 路径传 false —— 无人值守验收里
    ///   弹出密码框只会把进程挂在那里，不如直接报错并提示改用 `--helper-script`。
    func performInstall(allowPasswordPrompt: Bool) {
        // 已装且真在跑：不要再覆盖一遍，重连即可（可能是 XPC 一侧卡住了）。
        if status.isInstalled, Self.daemonLoaded() {
            note = "后台组件已经在运行，已重新连接"
            finish(success: true)
            return
        }

        let legacy = Self.directInstallDetected()

        if !legacy, let service {
            do {
                try service.register()
                refresh()
                if status.isInstalled {
                    note = nil
                    finish(success: true)
                    return
                }
                if status.needsUserApproval {
                    // 系统的正常流程：等用户去「登录项与扩展」点批准
                    note = "已在系统登记，等待你在「系统设置 → 通用 → 登录项与扩展」里批准"
                    finish(success: false)
                    return
                }
                note = "系统登记返回「\(status.title)」，改用管理员授权安装"
            } catch {
                note = "系统登记未成功，改用管理员授权安装（原因：\(Self.describe(error)))"
            }
        } else if legacy {
            note = "检测到已有的直装组件，将在同一路径覆盖（旧进程会被停掉）"
        }

        installWithAdministrator(allowPasswordPrompt: allowPasswordPrompt)
    }

    /// 管理员授权直装：一次密码，落盘 + 修签名 + 写 daemon + 加载。
    private func installWithAdministrator(allowPasswordPrompt: Bool) {
        guard allowPasswordPrompt else {
            error = "系统登记不可用，而命令行模式不会弹管理员密码框。"
                + "请改用 `--helper-script` 输出脚本后 `sudo bash` 执行。"
            isBusy = false
            return
        }
        guard let source = Self.administratorHelperSource() else {
            error = Self.unsupportedReason
            isBusy = false
            return
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("funfan-install-\(UUID().uuidString)", isDirectory: true)
        let plistURL = directory.appendingPathComponent(Self.daemonPlistName)
        let plist = HelperInstallScript.daemonPlist(
            label: HelperConstants.machServiceName,
            programPath: HelperConstants.installedBinaryPath,
            logPath: HelperInstallScript.logPath
        )

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try plist.write(to: plistURL, atomically: true, encoding: .utf8)
        } catch {
            self.error = "无法准备安装文件：\(error.localizedDescription)"
            isBusy = false
            return
        }
        // 注意：临时目录不能在这里 defer 删——授权是异步的，脚本要等用户输完密码
        // 才真正开始跑，提前删掉 plist 会让 cp 直接失败。删除挪到完成回调里。

        let commands = HelperInstallScript.installCommands(
            helperSource: source,
            plistSource: plistURL.path,
            label: HelperConstants.machServiceName,
            binaryPath: HelperConstants.installedBinaryPath,
            plistPath: HelperConstants.installedPlistPath,
            logPath: HelperInstallScript.logPath
        )
        let script = HelperInstallScript.appleScript(
            shellScript: HelperInstallScript.shellScript(commands),
            prompt: "FunFan 需要安装「风扇控制组件」——一个以 root 运行的后台服务。"
                + "它只做一件事：代表 FunFan 写风扇转速，并在 FunFan 退出后立刻把风扇交还系统。"
        )

        Self.runAsAdministrator(script) { [weak self] message in
            try? FileManager.default.removeItem(at: directory)
            DispatchQueue.main.async {
                guard let self else { return }
                self.isBusy = false
                self.refresh()
                if let message {
                    self.error = message
                    return
                }
                if Self.daemonLoaded() {
                    self.finish(success: true)
                } else {
                    self.error = "文件已写入，但服务没启动起来。日志：\(HelperInstallScript.logPath)"
                }
            }
        }
    }

    // MARK: - 卸载

    func uninstall(sync: Bool = false) {
        guard !isBusy else { return }
        error = nil
        note = nil
        isBusy = true
        if sync {
            performUninstall(allowPasswordPrompt: true)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.performUninstall(allowPasswordPrompt: true)
            }
        }
    }

    func performUninstall(allowPasswordPrompt: Bool) {
        // 系统登记的那份
        if let service, status != .notRegistered {
            do {
                try service.unregister()
            } catch {
                self.error = Self.describe(error)
            }
        }

        // 直装的那份（脚本版或管理员安装）
        if Self.directInstallDetected() || Self.daemonLoaded() {
            uninstallWithAdministrator(allowPasswordPrompt: allowPasswordPrompt)
            return
        }

        finish(success: true)
    }

    private func uninstallWithAdministrator(allowPasswordPrompt: Bool) {
        guard allowPasswordPrompt else {
            if error == nil {
                error = "直装组件需要管理员权限才能删除：sudo launchctl bootout system/\(HelperConstants.machServiceName)"
                    + " && sudo rm -f \(HelperConstants.installedPlistPath) \(HelperConstants.installedBinaryPath)"
            }
            isBusy = false
            refresh()
            return
        }
        let commands = HelperInstallScript.uninstallCommands(
            label: HelperConstants.machServiceName,
            binaryPath: HelperConstants.installedBinaryPath,
            plistPath: HelperConstants.installedPlistPath
        )
        let script = HelperInstallScript.appleScript(
            shellScript: HelperInstallScript.shellScript(commands),
            prompt: "FunFan 需要管理员权限来卸载「风扇控制组件」。卸载后风扇完全交回系统管理。"
        )
        Self.runAsAdministrator(script) { [weak self] message in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isBusy = false
                self.refresh()
                if let message {
                    if self.error == nil { self.error = message }
                    return
                }
                self.finish(success: true)
            }
        }
    }

    // MARK: - 其它

    func refresh() {
        status = Self.currentStatus()
        directInstallPresent = Self.directInstallDetected()
    }

    private func finish(success: Bool) {
        isBusy = false
        refresh()
        if success { completionTick &+= 1 }
    }

    /// 需要用户批准时，直接把人送到「登录项与扩展」页面 ——
    /// 让人自己去系统设置里翻三层菜单是最容易被放弃的一步。
    func openApprovalSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
        else { return }
        NSWorkspace.shared.open(url)
    }

    /// 当前是否「已装好且可能可用」，用于 UI 文案分层。
    var isInstalled: Bool { status.isInstalled || directInstallPresent }

    // MARK: - 管理员授权

    /// 执行 `do shell script … with administrator privileges`。
    ///
    /// 用 `osascript` 子进程而不是 `NSAppleScript`：后者会把调用线程整个堵在
    /// 「等用户输密码」上——在菜单栏 app 里就是主线程冻结、popover 卡死，
    /// 用户只会以为点崩了。子进程弹框期间我们的事件循环照常转。
    ///
    /// 完成回调在后台线程，调用方自己切回主线程。
    static func runAsAdministrator(
        _ source: String,
        completion: @escaping (String?) -> Void
    ) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        // `-` 表示从 stdin 读脚本：脚本带引号又长，塞进 -e 参数容易被 shell 再解释一遍
        process.arguments = ["-"]

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        process.terminationHandler = { finished in
            let errorText = String(
                data: stderr.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            guard finished.terminationStatus == 0 else {
                // osascript 把 AppleScript 的 -128（用户取消）原样带在 stderr 里，
                // 不能当成"程序坏了"来报。
                if errorText.contains("(-128)") {
                    completion("已取消：安装后台组件需要你在系统弹窗里授权。")
                } else {
                    completion("授权安装失败：\(errorText.isEmpty ? "退出码 \(finished.terminationStatus)" : errorText)")
                }
                return
            }
            completion(nil)
        }

        do {
            try process.run()
        } catch {
            completion("无法启动授权进程：\(error.localizedDescription)")
            return
        }

        if let data = source.data(using: .utf8) {
            try? stdin.fileHandleForWriting.write(contentsOf: data)
        }
        try? stdin.fileHandleForWriting.close()
    }

    // MARK: - 错误解释

    /// 把 `SMAppServiceErrorDomain` 的裸错误码翻译成「为什么 + 怎么办」。
    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        let head = "\(ns.localizedDescription)（\(ns.domain) \(ns.code)）"

        if ns.domain == "SMAppServiceErrorDomain" || ns.domain == NSCocoaErrorDomain {
            return head + "：App 未被系统信任（adhoc 签名或位于临时目录）。"
                + "已自动改用管理员授权安装；若仍失败，请把 App 拖进「应用程序」后再试。"
        }
        return head
    }
}
