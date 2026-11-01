import XCTest
@testable import FunFanCore

/// 键盘焦点环偏好：默认关闭（用户决策），读写落 UserDefaults。
///
/// 背景：焦点环只服务全键盘用户（Tab 导航时提示焦点在哪），普通鼠标用户
/// 看到按钮上常驻的蓝框只会当成渲染缺陷，所以默认关、设置里可开。
final class DisplayPreferencesTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "DisplayPreferencesTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// 干净环境（从未设置过）→ 默认关闭。
    func testDefaultIsOff() {
        let prefs = DisplayPreferences(defaults: defaults)
        XCTAssertFalse(prefs.focusRingVisible, "焦点环必须默认关闭")
    }

    /// 打开后读写往返一致，且真正落到 defaults（App 重启后仍在）。
    func testRoundTrip() {
        let prefs = DisplayPreferences(defaults: defaults)

        prefs.focusRingVisible = true
        XCTAssertTrue(prefs.focusRingVisible)
        XCTAssertTrue(DisplayPreferences(defaults: defaults).focusRingVisible,
                      "新实例（模拟重启）要能读回同一值")

        prefs.focusRingVisible = false
        XCTAssertFalse(prefs.focusRingVisible)
    }

    /// 显式写过 false 之后也是 false——与「从未写过」的默认值区分开，
    /// 这里只验证结果一致，两者都读出关闭。
    func testExplicitFalseReadsFalse() {
        let prefs = DisplayPreferences(defaults: defaults)
        prefs.focusRingVisible = true
        prefs.focusRingVisible = false
        XCTAssertFalse(DisplayPreferences(defaults: defaults).focusRingVisible)
    }
}
