import Foundation

/// 「管理员授权安装」的脚本构造。
///
/// 为什么需要第二条安装路径：`SMAppService` 要求 App 有 Developer ID 签名、
/// 且位于稳定位置。开发机（adhoc 签名）和裸二进制上它一律失败，而把人赶去
/// 终端敲 `sudo bash scripts/install-helper.sh` 是最容易被放弃的一步。
///
/// 这里把「落盘 → 修权限 → 修签名 → 写 LaunchDaemon → 加载」表达成可测的
/// 命令序列，由 App 层用 `do shell script ... with administrator privileges`
/// 执行：用户只需在系统弹窗里输一次密码，跟装普通软件的手感一致。
///
/// 安全边界：所有路径都是常量或 App 包自身路径，不拼接任何用户输入；
/// 命令一律用绝对路径（`do shell script` 的 PATH 只有 /usr/bin:/bin:/usr/sbin:/sbin）。
public enum HelperInstallScript {

    /// 与 `scripts/install-helper.sh` 保持一致的日志落点，便于两套安装互查。
    public static var logPath: String { HelperConstants.logPath }

    /// LaunchDaemon plist。
    ///
    /// 用 `ProgramArguments` 绝对路径而不是 `BundleProgram`：后者是
    /// SMAppService 专用的相对路径写法，`launchctl bootstrap` 直装不认。
    /// 不设 `FUNFAN_REQUIRE_SIGNATURE`：helper 自己会按签名能力决定是否校验客户端。
    public static func daemonPlist(
        label: String,
        programPath: String,
        logPath: String
    ) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(programPath)</string>
            </array>
            <key>MachServices</key>
            <dict>
                <key>\(label)</key>
                <true/>
            </dict>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <dict>
                <key>SuccessfulExit</key>
                <false/>
            </dict>
            <key>StandardErrorPath</key>
            <string>\(logPath)</string>
        </dict>
        </plist>

        """
    }

    /// 安装命令序列。
    ///
    /// - Parameters:
    ///   - helperSource: App 包（或 SPM 产物目录）里的 `FunFanHelper`。
    ///   - plistSource: 已写好的临时 plist（App 进程无权限写 /Library，只能先落临时目录）。
    public static func installCommands(
        helperSource: String,
        plistSource: String,
        label: String,
        binaryPath: String,
        plistPath: String,
        logPath: String
    ) -> [String] {
        [
            "/bin/mkdir -p \(quoted((binaryPath as NSString).deletingLastPathComponent))",
            // ditto 而不是 cp：保留权限位与扩展属性，也避免跨卷时的怪问题
            "/usr/bin/ditto \(quoted(helperSource)) \(quoted(binaryPath))",
            "/usr/sbin/chown root:wheel \(quoted(binaryPath))",
            "/bin/chmod 755 \(quoted(binaryPath))",
            // 签名策略：Developer ID 的（有 TeamIdentifier）原样保留，不动信任链；
            // adhoc 的一律重签成「纯 adhoc」。
            //
            // 为什么连已经 verify 通过的 adhoc+runtime 也要重签：硬运行时是公证
            // 才需要的，直装路径用不到；而本机已验证 launchd 能吃纯 adhoc（flags=0x2），
            // 至于 adhoc + runtime 组合没验过，不拿用户的机器当试验场。
            "if /usr/bin/codesign -dv --verbose=4 \(quoted(binaryPath)) 2>&1"
                + " | /usr/bin/grep -q 'TeamIdentifier=not set'; then"
                + " /usr/bin/codesign --force --sign - --identifier \(quoted(label)) \(quoted(binaryPath)); fi",
            "/bin/chmod 544 \(quoted(binaryPath))",
            "/bin/cp \(quoted(plistSource)) \(quoted(plistPath))",
            "/usr/sbin/chown root:wheel \(quoted(plistPath))",
            "/bin/chmod 644 \(quoted(plistPath))",
            // 先卸再装：既覆盖旧的脚本安装，也让「重装」总是从干净状态开始
            "/bin/launchctl bootout system/\(label) >/dev/null 2>&1 || true",
            "/bin/launchctl enable system/\(label) >/dev/null 2>&1 || true",
            "/bin/launchctl bootstrap system \(quoted(plistPath))",
            // bootstrap 之后给 launchd 一点时间把进程拉起来，否则状态查询会打架
            "/bin/sleep 1",
            "if ! /bin/launchctl print system/\(label) >/dev/null 2>&1; then"
                + " echo 'installed but not running' >&2; exit 1; fi",
            "/bin/cat \(quoted(logPath)) 2>/dev/null | /usr/bin/tail -n 5 || true",
        ]
    }

    public static func uninstallCommands(label: String, binaryPath: String, plistPath: String) -> [String] {
        [
            "/bin/launchctl bootout system/\(label) >/dev/null 2>&1 || true",
            "/bin/rm -f \(quoted(plistPath)) \(quoted(binaryPath))",
        ]
    }

    /// 清理改名前的安装残留，必须跑在安装命令之前。
    ///
    /// 反域名标识从 `com.funfan.*` 换成 `cn.lovexiaov.fun.fan*` 之后，旧 label 的
    /// daemon 不会被新流程覆盖 —— 它仍以 root 跑着、仍连着 SMC。两份写手并存，
    /// 表现就是风扇转速忽快忽慢、App 退出后不返还。所以先杀掉再装。
    ///
    /// 全部带 `|| true`：旧机器上本来就没有这些文件，清不掉不该阻断安装。
    public static func legacyCleanupCommands(
        label: String,
        binaryPath: String,
        plistPath: String
    ) -> [String] {
        [
            "/bin/launchctl bootout system/\(label) >/dev/null 2>&1 || true",
            "/bin/rm -f \(quoted(plistPath)) \(quoted(binaryPath)) 2>/dev/null || true",
        ]
    }

    /// 拼成一段 shell：`set -e` 保证任何一步失败都中断，而不是留下半个安装。
    public static func shellScript(_ commands: [String]) -> String {
        (["set -e"] + commands).joined(separator: "\n")
    }

    /// 包成 AppleScript 的 `do shell script … with administrator privileges`。
    ///
    /// `prompt` 会显示在系统密码弹窗的正文里——说清「装什么、为什么」，
    /// 比只弹一个「osascript 想要进行更改」让人放心得多。
    public static func appleScript(shellScript: String, prompt: String) -> String {
        "do shell script \"\(escapeForAppleScript(shellScript))\""
            + " with prompt \"\(escapeForAppleScript(prompt))\""
            + " with administrator privileges"
    }

    // MARK: - 转义

    /// POSIX shell 单引号包裹：路径里有空格、`$`、反引号都不会被解释。
    static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// AppleScript 字符串字面量转义。
    ///
    /// 顺序要紧：先转义反斜杠，再转义引号，最后才把真实换行换成 `\n`——
    /// 反过来的话，刚插入的 `\n` 里的反斜杠会被二次转义，shell 收到字面量 "\n"。
    static func escapeForAppleScript(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}
