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
}
