import XCTest
@testable import FunFanCore

/// `scripts/gen-release-notes.sh` 的输出契约。
///
/// 为什么值得一条测试：这份文案现在被两条完全不同的发布路径消费——
/// 本机 `scripts/release.sh`（能签名/公证）和 CI（只能 adhoc）。两边看到的是
/// 同一份文本，一旦有人改了措辞却漏了一条路径，用户会同时读到「需要放行」和
/// 「不需要放行」两种说法。文案本身没法靠编译器守，就靠这几条断言。
final class ReleaseNotesScriptTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FunFanCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // 仓库根
    }

    private struct RunResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private func runNotes(_ arguments: [String]) throws -> RunResult {
        let script = repoRoot.appendingPathComponent("scripts/gen-release-notes.sh")
        guard FileManager.default.fileExists(atPath: script.path) else {
            throw XCTSkip("找不到 \(script.path)")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path] + arguments
        process.currentDirectoryURL = repoRoot

        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return RunResult(
            status: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }

    /// 未公证包：必须写清「会拦一次」和解除隔离的命令，否则用户下下来只会看到「已损坏」。
    func testUnsignedNotesExplainGatekeeper() throws {
        let result = try runNotes(["--version", "9.9.9"])
        XCTAssertEqual(result.status, 0, result.stderr)

        let text = result.stdout
        XCTAssertTrue(text.contains("FunFan-9.9.9.dmg"), "安装步骤里的文件名要用真实版本号")
        XCTAssertTrue(text.contains("### 安装"))
        XCTAssertTrue(text.contains("### 变更"))
        XCTAssertTrue(text.contains("### 校验"))
        XCTAssertTrue(text.contains("shasum -a 256 -c SHA256SUMS.txt"))
        XCTAssertTrue(text.contains("仍要打开"), "未公证包必须写清 Gatekeeper 的放行步骤")
        XCTAssertTrue(text.contains("xattr -dr com.apple.quarantine"), "必须给出命令行退路")
        XCTAssertTrue(text.contains("没有经过公证"), "必须明确标注未公证")
        XCTAssertTrue(text.contains("macOS 13"), "系统要求不能漏")
    }

    /// 已公证包反过来：不能再出现放行步骤，否则用户会以为自己下错了包。
    func testNotarizedNotesDropGatekeeperSteps() throws {
        let result = try runNotes(["--version", "9.9.9", "--notarized"])
        XCTAssertEqual(result.status, 0, result.stderr)

        let text = result.stdout
        XCTAssertTrue(text.contains("菜单栏出现风扇图标即完成"))
        XCTAssertFalse(text.contains("仍要打开"), "已公证的包不该让用户去点「仍要打开」")
        XCTAssertFalse(text.contains("xattr -dr com.apple.quarantine"))
        XCTAssertFalse(text.contains("没有经过公证"))
    }

    /// 版本号缺失时必须失败退出，而不是输出一份占位着 `FunFan-.dmg` 的说明。
    func testMissingVersionFails() throws {
        let result = try runNotes(["--version", ""])
        XCTAssertEqual(result.status, 2, "没版本号要用退出码 2 明说，不能猜")
        XCTAssertTrue(result.stderr.contains("版本号"))
    }
}
