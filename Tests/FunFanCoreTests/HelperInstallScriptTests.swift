import XCTest
@testable import FunFanCore

final class HelperInstallScriptTests: XCTestCase {

    private let label = "com.funfan.helper"
    private let binary = "/Library/PrivilegedHelperTools/com.funfan.helper"
    private let plist = "/Library/LaunchDaemons/com.funfan.helper.plist"

    private func installCommands() -> [String] {
        HelperInstallScript.installCommands(
            helperSource: "/Applications/FunFan.app/Contents/MacOS/FunFanHelper",
            plistSource: "/tmp/abc/com.funfan.helper.plist",
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
        XCTAssertTrue(joined.contains("bootstrap system '/Library/LaunchDaemons/com.funfan.helper.plist'"))
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
        XCTAssertTrue(joined.contains("bootout system/com.funfan.helper"))
        XCTAssertTrue(joined.contains(binary))
        XCTAssertTrue(joined.contains(plist))
        XCTAssertTrue(joined.contains("rm -f"))
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
