import Foundation

/// 展示偏好：与风扇控制无关的「界面长什么样」。
///
/// 与 `ControlPreferences` 分开存的原因：控制偏好决定「重启后风扇怎么跑」，
/// 展示偏好只影响观感，生命周期和风险等级都不同，混在一个文件里会让人
/// 误以为改展示项也会影响风扇行为。
///
/// 键名带 `FunFan.` 前缀，与 `SettingsStore` / `ControlPreferences` 同一命名空间。
public struct DisplayPreferences {

    /// 键盘焦点环（自绘控件 Tab 聚焦时的蓝色描边）。
    public static let focusRingVisibleKey = "FunFan.focusRingVisible"

    /// 默认关闭：焦点环只服务全键盘用户（Tab 导航时提示焦点在哪），
    /// 普通鼠标用户看到按钮上常驻的蓝框只会当成渲染缺陷。
    /// 这是用户明确拍板的产品决策（2026-11-01），之前「永不隐藏」的可访问性
    /// 取舍改为「默认隐藏 + 设置里可打开」。
    public static let defaultFocusRingVisible = false

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 键盘焦点环是否显示。`@AppStorage` / `SettingsStore` 共用这个键。
    public var focusRingVisible: Bool {
        get {
            guard defaults.object(forKey: Self.focusRingVisibleKey) != nil else {
                return Self.defaultFocusRingVisible
            }
            return defaults.bool(forKey: Self.focusRingVisibleKey)
        }
        nonmutating set {
            defaults.set(newValue, forKey: Self.focusRingVisibleKey)
        }
    }
}
