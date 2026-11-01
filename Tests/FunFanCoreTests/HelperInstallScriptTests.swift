import XCTest
@testable import FunFanCore

final class HelperInstallScriptTests: XCTestCase {

    private let label = "cn.lovexiaov.fun.fan.helper"
    private let binary = "/Library/PrivilegedHelperTools/cn.lovexiaov.fun.fan.helper"
    private let plist = "/Library/LaunchDaemons/cn.lovexiaov.fun.fan.helper.plist"

    private func installCommands() -> [String] {
        HelperInstallScript.installCommands(
            helperSource: "/Applications/FunFan.app/Contents/MacOS/FunFanHelper",
            plistSource: "/tmp/abc/cn.lovexiaov.fun.fan.helper.plist",
            label: label,
            binaryPath: binary,
            plistPath: plist,
            logPath: HelperInstallScript.logPath
        )
    }

    // MARK: - plist

    func testDaemonPlistIsValidPropertyList() throws {
        let text = HelperInstallScript.daemonPlist(
            label: label,
            programPath: binary,
            logPath: HelperInstallScript.logPath
        )
        let data = try XCTUnwrap(text.data(using: .utf8))
        let object = try PropertyListSerialization.propertyList(from: data, format: nil)
        let dictionary = try XCTUnwrap(object as? [String: Any])

        XCTAssertEqual(dictionary["Label"] as? String, label)
        XCTAssertEqual(dictionary["ProgramArguments"] as? [String], [binary])
        XCTAssertEqual(dictionary["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(dictionary["StandardErrorPath"] as? String, HelperInstallScript.logPath)

        let mach = try XCTUnwrap(dictionary["MachServices"] as? [String: Bool])
        XCTAssertEqual(mach[label], true)
    }

    /// 直装方案必须用 ProgramArguments（launchctl 不认 BundleProgram）。
    func testDaemonPlistUsesAbsoluteProgramPath() {
        let text = HelperInstallScript.daemonPlist(
            label: label,
            programPath: binary,
            logPath: "/var/log/x.log"
        )
        XCTAssertTrue(text.contains("<key>ProgramArguments</key>"))
        XCTAssertFalse(text.contains("BundleProgram"))
        XCTAssertFalse(text.contains("FUNFAN_REQUIRE_SIGNATURE"))
    }

    // MARK: - 命令序列

    func testInstallOrderCopiesBeforeLoading() throws {
        let commands = installCommands()
        let joined = commands.joined(separator: "\n")

        func index(_ needle: String) throws -> Int {
            try XCTUnwrap(
                commands.firstIndex { $0.contains(needle) },
                "缺少步骤：\(needle)"
            )
        }

        XCTAssertTrue(commands.first!.contains("mkdir -p '/Library/PrivilegedHelperTools'"))
        XCTAssertLessThan(try index("ditto"), try index("bootstrap system"))
        XCTAssertLessThan(try index("codesign"), try index("chmod 544"))
        XCTAssertLessThan(try index("bootout"), try index("bootstrap system"))
        XCTAssertTrue(joined.contains("bootstrap system '/Library/LaunchDaemons/cn.lovexiaov.fun.fan.helper.plist'"))
    }

    /// 签名策略：Developer ID 保留，adhoc 重签成纯 adhoc。
    func testInstallNormalizesAdhocSignature() throws {
        let commands = installCommands()
        let sign = try XCTUnwrap(commands.first { $0.contains("codesign") })
        XCTAssertTrue(sign.contains("TeamIdentifier=not set"))
        XCTAssertTrue(sign.contains("--force --sign -"))
        // 重签发生在改权限前：544 不可写，codesign 需要能改文件
        XCTAssertLessThan(
            try XCTUnwrap(commands.firstIndex { $0.contains("codesign") }),
            try XCTUnwrap(commands.firstIndex { $0.contains("chmod 544") })
        )
    }

    func testUninstallRemovesBothArtifacts() {
        let commands = HelperInstallScript.uninstallCommands(
            label: label,
            binaryPath: binary,
            plistPath: plist
        )
        let joined = commands.joined(separator: "\n")
        XCTAssertTrue(joined.contains("bootout system/cn.lovexiaov.fun.fan.helper"))
        XCTAssertTrue(joined.contains(binary))
        XCTAssertTrue(joined.contains(plist))
        XCTAssertTrue(joined.contains("rm -f"))
    }

    // MARK: - 改名迁移

    /// 清理旧 label 必须排在安装之前。
    ///
    /// 反域名标识换过一次（`com.funfan.*` → `cn.lovexiaov.fun.fan*`）。旧 daemon
    /// 不会被新流程覆盖，它会留在机器上和新 helper 同时写 SMC —— 风扇忽快忽慢、
    /// App 退出后不返还。所以这条链路必须「先杀旧、再装新」，顺序错了就白做。
    func testLegacyCleanupRunsBeforeInstall() throws {
        let legacy = HelperInstallScript.legacyCleanupCommands(
            label: HelperConstants.Legacy.machServiceName,
            binaryPath: HelperConstants.Legacy.installedBinaryPath,
            plistPath: HelperConstants.Legacy.installedPlistPath
        )
        let combined = legacy + installCommands()

        let killLegacy = try XCTUnwrap(combined.firstIndex { $0.contains("bootout system/com.funfan.helper") })
        let startInstall = try XCTUnwrap(combined.firstIndex { $0.contains("mkdir -p '/Library/PrivilegedHelperTools'") })
        XCTAssertLessThan(killLegacy, startInstall, "必须先清理旧 label 再安装")

        let joined = combined.joined(separator: "\n")
        XCTAssertTrue(joined.contains("/Library/PrivilegedHelperTools/com.funfan.helper"))
        XCTAssertTrue(joined.contains("/Library/LaunchDaemons/com.funfan.helper.plist"))
    }

    /// 清理步骤在「本来就没有旧残留」的机器上不能失败（否则老用户装不上）。
    func testLegacyCleanupNeverFailsInstaller() {
        let legacy = HelperInstallScript.legacyCleanupCommands(
            label: HelperConstants.Legacy.machServiceName,
            binaryPath: HelperConstants.Legacy.installedBinaryPath,
            plistPath: HelperConstants.Legacy.installedPlistPath
        )
        // `set -e` 下只要有一条命令非零退出，整个安装就中断
        for command in legacy {
            XCTAssertTrue(
                command.hasSuffix("|| true"),
                "清理命令必须容错，否则新机器上装不了：\(command)"
            )
        }
    }

    /// 所有标识、路径都从同一个根派生，不允许任何一处再写字面量。
    func testAllIdentifiersShareOneRoot() {
        let root = HelperConstants.identifierRoot
        XCTAssertEqual(root, "cn.lovexiaov.fun.fan")
        XCTAssertEqual(HelperConstants.machServiceName, "\(root).helper")
        XCTAssertEqual(HelperConstants.installedBinaryPath, "/Library/PrivilegedHelperTools/\(root).helper")
        XCTAssertEqual(HelperConstants.installedPlistPath, "/Library/LaunchDaemons/\(root).helper.plist")
        XCTAssertEqual(HelperConstants.logPath, "/var/log/\(root).helper.log")

        // 诊断、安装脚本里的那份必须指到同一处，不能各写各的
        XCTAssertEqual(HelperPaths.machServiceName, HelperConstants.machServiceName)
        XCTAssertEqual(HelperPaths.binary, HelperConstants.installedBinaryPath)
        XCTAssertEqual(HelperPaths.plist, HelperConstants.installedPlistPath)
        XCTAssertEqual(HelperPaths.log, HelperConstants.logPath)
        XCTAssertEqual(HelperInstallScript.logPath, HelperConstants.logPath)

        // 旧标识必须和新标识完全不相交，否则清理逻辑会误删当前安装
        XCTAssertFalse(HelperConstants.Legacy.machServiceName.hasPrefix(root))
        XCTAssertNotEqual(HelperConstants.Legacy.installedBinaryPath, HelperConstants.installedBinaryPath)
        XCTAssertNotEqual(HelperConstants.Legacy.installedPlistPath, HelperConstants.installedPlistPath)
    }

    func testShellScriptFailsFast() {
        let script = HelperInstallScript.shellScript(["echo a", "echo b"])
        XCTAssertTrue(script.hasPrefix("set -e"))
        XCTAssertTrue(script.contains("echo a\necho b"))
    }

    /// 用 `osacompile` 真编译一遍 AppleScript，证明转义没把脚本弄坏。
    ///
    /// bash -n 只能验 shell 那一半；AppleScript 的字面量里多一个反斜杠，
    /// 用户看到的就是「无法构造安装脚本」，而这一步在命令行里没法复现。
    func testAppleScriptCompilesWithOsacompile() throws {
        let script = HelperInstallScript.appleScript(
            shellScript: HelperInstallScript.shellScript(installCommands()),
            prompt: "FunFan 需要安装「风扇控制组件」——带 \"引号\" 与 \\ 反斜杠的说明"
        )

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("funfan-osa-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("install.applescript")
        let outputURL = directory.appendingPathComponent("install.scpt")
        try script.write(to: sourceURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
        process.arguments = ["-o", outputURL.path, sourceURL.path]
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()

        let detail = String(
            data: errors.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, "AppleScript 编译失败：\(detail)")
    }

    /// 真拿 `/bin/bash -n` 过一遍语法。
    ///
    /// 这段脚本最终是以 root 执行的：拼错一个引号，用户看到的是「安装失败」，
    /// 而权限已经动过了。语法检查是这里唯一不需要真机的强证据。
    func testGeneratedScriptsParseUnderBash() throws {
        let cases: [(String, [String])] = [
            ("install", installCommands()),
            // 真实安装脚本是「清理旧 label + 安装」的拼接，两个都要过语法检查
            ("install-with-legacy-cleanup",
             HelperInstallScript.legacyCleanupCommands(
                label: HelperConstants.Legacy.machServiceName,
                binaryPath: HelperConstants.Legacy.installedBinaryPath,
                plistPath: HelperConstants.Legacy.installedPlistPath
             ) + installCommands()),
            ("uninstall", HelperInstallScript.uninstallCommands(
                label: label, binaryPath: binary, plistPath: plist
            )),
        ]

        for (name, commands) in cases {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("funfan-\(name)-\(UUID().uuidString).sh")
            try HelperInstallScript.shellScript(commands).write(to: url, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: url) }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-n", url.path]
            let errors = Pipe()
            process.standardError = errors
            try process.run()
            process.waitUntilExit()

            let detail = String(
                data: errors.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            XCTAssertEqual(process.terminationStatus, 0, "\(name) 脚本语法错误：\(detail)")
        }
    }

    // MARK: - 转义

    func testQuotedSurvivesSpacesAndQuotes() {
        XCTAssertEqual(HelperInstallScript.quoted("/tmp/a b"), "'/tmp/a b'")
        XCTAssertEqual(HelperInstallScript.quoted("/tmp/it's"), "'/tmp/it'\\''s'")
        // $ 与反引号在单引号内不再被解释
        XCTAssertEqual(HelperInstallScript.quoted("/tmp/$HOME`id`"), "'/tmp/$HOME`id`'")
    }

    func testEscapeForAppleScriptHandlesBackslashQuoteNewline() {
        let escaped = HelperInstallScript.escapeForAppleScript("a\\b\"c\nd")
        XCTAssertEqual(escaped, #"a\\b\"c\nd"#)
    }

    /// 换行必须先保成 \n 字面量，且不能被反斜杠转义二次处理。
    func testAppleScriptEmbedsMultiLineScriptAsSingleLine() {
        let script = HelperInstallScript.appleScript(
            shellScript: HelperInstallScript.shellScript(["echo a", "echo b"]),
            prompt: "安装风扇控制组件"
        )
        XCTAssertFalse(script.contains("\n"), "AppleScript 字面量不能跨行")
        XCTAssertTrue(script.contains("set -e\\necho a\\necho b"))
        XCTAssertTrue(script.contains("with administrator privileges"))
        XCTAssertTrue(script.contains("with prompt \"安装风扇控制组件\""))
    }
}
