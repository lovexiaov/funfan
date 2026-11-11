import XCTest
@testable import FunFanCore

/// 更新检查的偏好：自动检查开关、上次检查时间、被忽略的版本。
///
/// 默认值是产品决策，不是随手写的：
/// **默认关闭自动检查**。App 的免责声明写着「不收集任何数据」，而自动检查会向
/// GitHub 发请求（带着 IP 和本机版本号）。默认替用户联网与这句话冲突，
/// 所以做成「默认手动、想自动就明示打开」。
final class UpdatePreferencesTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "UpdatePreferencesTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private var prefs: UpdatePreferences { UpdatePreferences(defaults: defaults) }

    func testAutoCheckIsOffByDefault() {
        XCTAssertFalse(UpdatePreferences.defaultAutoCheck)
        XCTAssertFalse(prefs.autoCheckEnabled)
    }

    func testAutoCheckPersists() {
        prefs.autoCheckEnabled = true
        XCTAssertTrue(prefs.autoCheckEnabled)
    }

    func testLastCheckedAtStartsNil() {
        XCTAssertNil(prefs.lastCheckedAt)
    }

    func testLastCheckedAtPersists() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        prefs.lastCheckedAt = now
        XCTAssertEqual(prefs.lastCheckedAt?.timeIntervalSince1970, now.timeIntervalSince1970)
    }

    func testSkippedVersionPersistsAndClears() {
        XCTAssertNil(prefs.skippedVersion)
        prefs.skippedVersion = "1.0.0-alpha.8"
        XCTAssertEqual(prefs.skippedVersion, "1.0.0-alpha.8")
        prefs.skippedVersion = nil
        XCTAssertNil(prefs.skippedVersion)
    }

    // MARK: - 自动检查的节流

    func testShouldNotAutoCheckWhenDisabled() {
        let now = Date()
        prefs.autoCheckEnabled = false
        prefs.lastCheckedAt = nil
        XCTAssertFalse(prefs.shouldAutoCheck(now: now))
    }

    func testShouldAutoCheckWhenNeverChecked() {
        prefs.autoCheckEnabled = true
        XCTAssertTrue(prefs.shouldAutoCheck(now: Date()))
    }

    func testShouldNotAutoCheckWithinOneDay() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        prefs.autoCheckEnabled = true
        prefs.lastCheckedAt = now.addingTimeInterval(-2 * 3600)
        XCTAssertFalse(prefs.shouldAutoCheck(now: now))
    }

    func testShouldAutoCheckAfterOneDay() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        prefs.autoCheckEnabled = true
        prefs.lastCheckedAt = now.addingTimeInterval(-25 * 3600)
        XCTAssertTrue(prefs.shouldAutoCheck(now: now))
    }

    /// 系统时间被往回调（或时区/手动改表）时，`lastCheckedAt` 会落在「未来」。
    /// 此时不能算「过期」——否则每次启动都联网，节流形同虚设。
    func testFutureTimestampDoesNotTriggerCheck() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        prefs.autoCheckEnabled = true
        prefs.lastCheckedAt = now.addingTimeInterval(6 * 3600)
        XCTAssertFalse(prefs.shouldAutoCheck(now: now))
    }

    func testIntervalIsOneDay() {
        XCTAssertEqual(UpdatePreferences.autoCheckInterval, 24 * 60 * 60)
    }

    // MARK: - 失败后的短退避

    /// 两个源都不可用时，别让「每次启动顺手查一次」变成每次启动都失败一次。
    /// 用户开着自动检查时最明显：一个网络故障窗口内反复看到同一句错误。
    func testAutoCheckBacksOffShortlyAfterFailure() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        prefs.autoCheckEnabled = true
        prefs.lastAutoCheckFailedAt = now.addingTimeInterval(-5 * 60)
        XCTAssertFalse(prefs.shouldAutoCheck(now: now))
    }

    func testAutoCheckRetriesAfterBackoff() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        prefs.autoCheckEnabled = true
        prefs.lastAutoCheckFailedAt = now.addingTimeInterval(-31 * 60)
        XCTAssertTrue(prefs.shouldAutoCheck(now: now))
    }

    /// 成功一次后清掉退避，回到原来的 24h 节流——清退避不等于「马上再查」。
    func testClearingFailureRestoresDailyThrottle() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        prefs.autoCheckEnabled = true
        prefs.lastCheckedAt = now.addingTimeInterval(-2 * 3600)
        prefs.lastAutoCheckFailedAt = now.addingTimeInterval(-5 * 60)
        prefs.lastAutoCheckFailedAt = nil
        XCTAssertFalse(prefs.shouldAutoCheck(now: now))
    }

    func testFutureFailureTimestampDoesNotTriggerCheck() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        prefs.autoCheckEnabled = true
        prefs.lastAutoCheckFailedAt = now.addingTimeInterval(6 * 3600)
        XCTAssertFalse(prefs.shouldAutoCheck(now: now))
    }

    func testFailedAtPersistsAndClears() {
        XCTAssertNil(prefs.lastAutoCheckFailedAt)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        prefs.lastAutoCheckFailedAt = now
        XCTAssertEqual(prefs.lastAutoCheckFailedAt?.timeIntervalSince1970, now.timeIntervalSince1970)
        prefs.lastAutoCheckFailedAt = nil
        XCTAssertNil(prefs.lastAutoCheckFailedAt)
    }

    func testBackoffIntervalIsThirtyMinutes() {
        XCTAssertEqual(UpdatePreferences.autoCheckRetryInterval, 30 * 60)
    }

    func testKeysAreNamespaced() {
        XCTAssertEqual(UpdatePreferences.autoCheckKey, "FunFan.updateAutoCheck")
        XCTAssertEqual(UpdatePreferences.lastCheckedAtKey, "FunFan.updateLastCheckedAt")
        XCTAssertEqual(UpdatePreferences.autoCheckFailedAtKey, "FunFan.updateAutoCheckFailedAt")
        XCTAssertEqual(UpdatePreferences.skippedVersionKey, "FunFan.updateSkippedVersion")
    }
}
