import XCTest
@testable import FunFanCore

/// 仓库里所有 shell 脚本的语法回归。
///
/// 为什么值得一条测试：`scripts/*.sh` 不进编译，拼错一个未闭合的引号在
/// `swift build` 里完全看不出来，要等到真正发布那条路径才炸——而发布脚本
/// 恰恰是最不能临场调试的东西（它会对用户机器上的 `/Library` 动手）。
/// `bash -n` 只做语法分析、不执行任何一行，代价是毫秒级。
final class ScriptSyntaxTests: XCTestCase {

    /// `Tests/FunFanCoreTests/ScriptSyntaxTests.swift` → 仓库根
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FunFanCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // 仓库根
    }

    private func scripts() throws -> [URL] {
        let directory = repoRoot.appendingPathComponent("scripts", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw XCTSkip("找不到 scripts/ 目录：\(directory.path)")
        }
        let items = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        return items.filter { $0.pathExtension == "sh" }.sorted { $0.path < $1.path }
    }

    func testAllScriptsParse() throws {
        let all = try scripts()
        XCTAssertFalse(all.isEmpty, "scripts/ 里一个 .sh 都没有？")

        for script in all {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-n", script.path]
            let pipe = Pipe()
            process.standardError = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            let detail = String(data: data, encoding: .utf8) ?? ""
            XCTAssertEqual(
                process.terminationStatus, 0,
                "\(script.lastPathComponent) 语法错误：\(detail)"
            )
        }
    }

    /// 发布脚本必须可执行，否则 `make publish` 会以「Permission denied」结束，
    /// 看起来像构建失败，实际只是少了 chmod。
    func testScriptsAreExecutable() throws {
        for script in try scripts() {
            XCTAssertTrue(
                FileManager.default.isExecutableFile(atPath: script.path),
                "\(script.lastPathComponent) 没有可执行位（chmod +x）"
            )
        }
    }

    /// `$变量` 后面不能直接跟中文（`$DMG（$SIZE）` 这种）。
    ///
    /// 为什么值得一条测试：macOS 自带的 bash 是 3.2，变量名解析走 `isalnum()`，
    /// 在 UTF-8 locale 下会把多字节字符的首字节（比如全角括号的第一个字节 0xEF）
    /// 当成变量名的一部分。于是 `$DMG（` 被解析成名为 `DMG\xEF` 的变量——C locale
    /// 下一切正常，用户和 CI 的 UTF-8 环境里直接 `unbound variable` 退出。
    /// agent 沙箱恰好是 C locale，本机跑不出这个问题，是 CI 的 macOS 15 runner
    /// 让它现形的（`make-dmg.sh: line 67: DMG\xef: unbound variable`）。
    /// 修法只有一种：写成 `${DMG}`。这条测试守住「只许花括号」。
    func testVariableNeverGluedToMultibyteChar() throws {
        var offenders: [String] = []

        for script in try scripts() {
            let text = try String(contentsOf: script, encoding: .utf8)
            for (index, line) in text.components(separatedBy: .newlines).enumerated() {
                let scalars = Array(line.unicodeScalars)
                var inSingleQuote = false
                var inDoubleQuote = false
                var i = 0

                // 单引号里 `$VAR` 是字面量，不参与展开，不能误判
                while i < scalars.count {
                    let scalar = scalars[i]
                    if scalar == "'", !inDoubleQuote { inSingleQuote.toggle(); i += 1; continue }
                    if scalar == "\"", !inSingleQuote { inDoubleQuote.toggle(); i += 1; continue }

                    guard scalar == "$", !inSingleQuote else { i += 1; continue }

                    var j = i + 1
                    guard j < scalars.count, Self.isNameStart(scalars[j]) else { i += 1; continue }
                    while j < scalars.count, Self.isNameChar(scalars[j]) { j += 1 }

                    if j < scalars.count, scalars[j].value > 0x7F {
                        let name = String(String.UnicodeScalarView(scalars[(i + 1)..<j]))
                        offenders.append(
                            "\(script.lastPathComponent):\(index + 1)  $\(name) 后面紧跟「\(scalars[j])」，应写成 ${\(name)}"
                        )
                    }
                    i = j
                }
            }
        }

        XCTAssertTrue(
            offenders.isEmpty,
            "变量名后紧跟中文会被 bash 3.2 吞掉首字节：\n" + offenders.joined(separator: "\n")
        )
    }

    private static func isNameStart(_ scalar: Unicode.Scalar) -> Bool {
        (scalar >= "a" && scalar <= "z") || (scalar >= "A" && scalar <= "Z") || scalar == "_"
    }

    private static func isNameChar(_ scalar: Unicode.Scalar) -> Bool {
        isNameStart(scalar) || (scalar >= "0" && scalar <= "9")
    }
}
