import XCTest
@testable import FunFanCore

/// 宿主消失自退场（T20）：daemon 检测到宿主 App 被删后自我注销。
///
/// 平台背景：macOS 没有「App 被卸载」回调，App 侧做不到；唯一能自己动手的是
/// 还活着的 helper——它检测宿主消失后清理自己。核心逻辑（路径推导、缺席
/// 计数、清理步骤序列）放 FunFanCore 可单测，daemon 侧只做薄壳执行。
final class HelperSelfCleanupTests: XCTestCase {

    // MARK: - 宿主 App 包路径推导

    func testHostBundlePathFromInAppExecutable() {
        XCTAssertEqual(
            HelperSelfCleanup.hostAppBundlePath(
                executablePath: "/Applications/FunFan.app/Contents/MacOS/FunFanHelper"
            ),
            "/Applications/FunFan.app"
        )
    }

    func testHostBundlePathWithSpaces() {
        XCTAssertEqual(
            HelperSelfCleanup.hostAppBundlePath(
                executablePath: "/Volumes/My Disk/Apps/FunFan.app/Contents/MacOS/FunFanHelper"
            ),
            "/Volumes/My Disk/Apps/FunFan.app"
        )
    }

    func testHostBundlePathNilForBareBinary() {
        // 脚本直装版：二进制在 PrivilegedHelperTools，不在任何 App 包里
        XCTAssertNil(
            HelperSelfCleanup.hostAppBundlePath(
                executablePath: "/Library/PrivilegedHelperTools/cn.lovexiaov.fun.fan.helper"
            )
        )
    }

    func testHostBundlePathNilForLookalikePath() {
        // 目录名带 .app 但不是 App 包结构，不能拿去当宿主判据
        XCTAssertNil(
            HelperSelfCleanup.hostAppBundlePath(
                executablePath: "/tmp/FunFan.app.backup/Contents/MacOS/FunFanHelper"
            )
        )
        XCTAssertNil(
            HelperSelfCleanup.hostAppBundlePath(
                executablePath: "/tmp/not-an-app/Contents/MacOS/FunFanHelper"
            )
        )
    }

    func testHostBundlePathNilForShortPath() {
        XCTAssertNil(HelperSelfCleanup.hostAppBundlePath(executablePath: "/FunFanHelper"))
        XCTAssertNil(HelperSelfCleanup.hostAppBundlePath(executablePath: ""))
    }

    // MARK: - 连续缺席计数

    func testMissesBelowThresholdDoNotTrigger() {
        var state = HostWatchState()
        XCTAssertFalse(state.record(hostPresent: false, threshold: 3))
        XCTAssertFalse(state.record(hostPresent: false, threshold: 3))
        XCTAssertEqual(state.consecutiveMisses, 2)
    }

    func testMissesReachingThresholdTrigger() {
        var state = HostWatchState()
        _ = state.record(hostPresent: false, threshold: 3)
        _ = state.record(hostPresent: false, threshold: 3)
        XCTAssertTrue(state.record(hostPresent: false, threshold: 3))
    }

    func testPresenceResetsCounter() {
        var state = HostWatchState()
        _ = state.record(hostPresent: false, threshold: 3)
        _ = state.record(hostPresent: false, threshold: 3)
        XCTAssertFalse(state.record(hostPresent: true, threshold: 3))
        XCTAssertEqual(state.consecutiveMisses, 0)
        // 重置后要重新数满
        XCTAssertFalse(state.record(hostPresent: false, threshold: 3))
    }

    func testCounterKeepsCountingPastThreshold() {
        var state = HostWatchState()
        for _ in 0..<5 { _ = state.record(hostPresent: false, threshold: 3) }
        XCTAssertEqual(state.consecutiveMisses, 5)
    }

    // MARK: - 清理步骤序列

    private let label = "cn.lovexiaov.fun.fan.helper"

    func testScriptVariantPlanDeletesOwnFilesThenBootsOut() {
        let plan = HelperSelfCleanup.plan(
            variant: .script(
                binaryPath: "/Library/PrivilegedHelperTools/\(label)",
                plistPath: "/Library/LaunchDaemons/\(label).plist",
                logPath: "/var/log/\(label).log"
            ),
            label: label
        )

        // 顺序即语义：文件先删（进程还在跑，unlink 不影响运行中的自己），
        // bootout 最后——它会给我们发 SIGTERM，之后没机会再删东西。
        XCTAssertEqual(plan.steps, [
            .deleteFile("/Library/LaunchDaemons/\(label).plist"),
            .deleteFile("/Library/PrivilegedHelperTools/\(label)"),
            .deleteFile("/var/log/\(label).log"),
            .bootout(label: label),
        ])
    }

    func testAppEmbeddedPlanCleansPlistBothLogLocationsAndBootsOut() {
        // App 包内安装有两条注册路径：SMAppService（打包 plist 的日志落点是
        // 旧域名 com.funfan.helper.log，且没有 /Library/LaunchDaemons plist）
        // 和管理员授权直装（HelperConstants 路径，plist 指向 App 包内二进制）。
        // 自清时 plist 与两处日志都试删，不猜当时走的是哪条。
        let plan = HelperSelfCleanup.plan(
            variant: .appEmbedded(
                plistPath: "/Library/LaunchDaemons/\(label).plist",
                logPaths: [
                    "/var/log/cn.lovexiaov.fun.fan.helper.log",
                    "/var/log/com.funfan.helper.log",
                ]
            ),
            label: label
        )

        // 二进制随 App 包一起没了，无从删起；plist 可能存在（授权直装）也可能
        // 不存在（SMAppService），删不存在的路径交给执行侧静默跳过
        XCTAssertEqual(plan.steps, [
            .deleteFile("/Library/LaunchDaemons/\(label).plist"),
            .deleteFile("/var/log/cn.lovexiaov.fun.fan.helper.log"),
            .deleteFile("/var/log/com.funfan.helper.log"),
            .bootout(label: label),
        ])
    }

    // MARK: - 执行参数

    func testBootoutLaunchctlArguments() {
        XCTAssertEqual(
            HelperSelfCleanup.bootoutArguments(label: label),
            ["/bin/launchctl", "bootout", "system/\(label)"]
        )
    }
}
