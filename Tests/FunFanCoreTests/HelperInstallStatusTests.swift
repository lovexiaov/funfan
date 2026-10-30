import XCTest
@testable import FunFanCore

/// 特权组件注册状态的映射与文案。
final class HelperInstallStatusTests: XCTestCase {

    func testMapsSMAppServiceRawValues() {
        // 原始值取自 SMAppService.Status 的声明顺序，改错会让界面显示错状态。
        XCTAssertEqual(HelperInstallStatus(rawStatus: 0), .notRegistered)
        XCTAssertEqual(HelperInstallStatus(rawStatus: 1), .enabled)
        XCTAssertEqual(HelperInstallStatus(rawStatus: 2), .requiresApproval)
        XCTAssertEqual(HelperInstallStatus(rawStatus: 3), .notFound)
    }

    func testUnknownRawValueIsPreserved() {
        // 新系统加新状态时不能崩、也不能假装是「已安装」。
        XCTAssertEqual(HelperInstallStatus(rawStatus: 99), .unknown(rawStatus: 99))
        XCTAssertFalse(HelperInstallStatus(rawStatus: 99).isInstalled)
    }

    func testOnlyEnabledCountsAsInstalled() {
        XCTAssertTrue(HelperInstallStatus.enabled.isInstalled)
        XCTAssertFalse(HelperInstallStatus.notRegistered.isInstalled)
        XCTAssertFalse(HelperInstallStatus.requiresApproval.isInstalled,
                       "待批准时 daemon 还没被允许启动，不能算已安装")
        XCTAssertFalse(HelperInstallStatus.notFound.isInstalled)
    }

    func testApprovalStateNeedsUserAction() {
        XCTAssertTrue(HelperInstallStatus.requiresApproval.needsUserApproval)
        XCTAssertFalse(HelperInstallStatus.enabled.needsUserApproval)
    }

    func testGuidanceIsPresentExceptWhenEnabled() {
        // 除了「已安装」，每个状态都得告诉用户下一步干什么，
        // 否则界面只剩一个说不清的红点。
        XCTAssertNil(HelperInstallStatus.enabled.guidance)
        XCTAssertNotNil(HelperInstallStatus.notRegistered.guidance)
        XCTAssertNotNil(HelperInstallStatus.requiresApproval.guidance)
        XCTAssertNotNil(HelperInstallStatus.notFound.guidance)
        XCTAssertNotNil(HelperInstallStatus.unknown(rawStatus: 42).guidance)
    }

    func testGuidanceMentionsSystemSettingsForApproval() {
        let text = HelperInstallStatus.requiresApproval.guidance ?? ""
        XCTAssertTrue(text.contains("登录项与扩展"), "批准路径要写清楚：\(text)")
    }
}
