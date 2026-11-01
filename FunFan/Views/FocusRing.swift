import SwiftUI
import FunFanCore

// 自绘控件的键盘焦点环。
//
// 为什么需要这一层：本项目所有可交互控件都是自绘的（原因见 `Components.swift`
// 文件头——原生控件无法离屏渲染、样式不受控）。自绘的同时也就失去了原生控件的
// 焦点外观，系统只能给整块 view 套一个**直角矩形**焦点环。
//
// 什么时候会看到它：系统设置 → 辅助功能 → 键盘 → 全键盘控制 打开后
// （`defaults read -g AppleKeyboardUIMode` 返回 2），每个窗口/浮层第一次出现时
// 焦点落到第一个可聚焦控件上，那个直角框就一直挂在界面上——套在圆角胶囊、
// 圆角卡片外面明显错位，看起来像渲染缺陷。
//
// 处理原则：**默认隐藏，设置里可打开**（`FunFan.focusRingVisible`，默认关）。
// 这是用户拍板的产品决策（2026-11-01）：焦点环只服务全键盘用户，普通鼠标用户
// 看到按钮上常驻的蓝框只会当成渲染缺陷，宁可默认不画，也不让大多数人困惑。
// 代价是全键盘用户开箱看不到焦点提示——设置里一行开关可以打开，键盘导航本身
// 始终不被关闭。离屏走查（`--force-focus`）不受偏好影响，永远强制画出。

extension View {
    /// 给自绘控件画符合自身形状的键盘焦点环。
    ///
    /// - Parameters:
    ///   - cornerRadius: 控件视觉形状的圆角，应与它背景的 `RoundedRectangle` 一致。
    ///   - outset: 环相对控件 frame 向外让出的距离。纯文字按钮给大一点，
    ///     免得环贴着字形显得局促；并排的分段控件给小一点，避免相邻环挤在一起。
    func funfanFocusRing(cornerRadius: CGFloat, outset: CGFloat = 2.5) -> some View {
        modifier(FunFanFocusRing(cornerRadius: cornerRadius, outset: outset))
    }
}

private struct FunFanFocusRing: ViewModifier {

    let cornerRadius: CGFloat
    let outset: CGFloat

    /// 只做观测，**不改变可聚焦性**：控件能不能被 Tab 到仍由系统的全键盘控制决定。
    @FocusState private var isFocused: Bool
    @Environment(\.forceFocusRing) private var forced
    @Environment(\.palette) private var palette

    /// 用户偏好（默认关）。走 `@AppStorage` 而不是注入 `SettingsStore`：
    /// 焦点环散落在 Popover / 规则窗口 / 曲线窗口 / 设置窗口多个视图树里，
    /// 逐层传 Store 太重；AppStorage 监听同一个 UserDefaults 键，
    /// 设置页改开关后所有窗口的环立即同步。
    @AppStorage(DisplayPreferences.focusRingVisibleKey) private var visible =
        DisplayPreferences.defaultFocusRingVisible

    func body(content: Content) -> some View {
        content
            .focused($isFocused)
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius + outset, style: .continuous)
                    // 焦点环是图形，走 accentFill（浅色下用深一点的蓝才够 3:1）
                    .strokeBorder(palette.accentFill, lineWidth: 2)
                    .padding(-outset)
                    // 走查强制（forced）优先于用户偏好——`--force-focus` 的目的
                    // 就是检验环的形状与外扩，偏好关着也得画出来。
                    .opacity(forced || (isFocused && visible) ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .modifier(NativeFocusEffect())
    }
}

private struct ForceFocusRingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// 仅供 `FunFan --render <target> <out.png> --force-focus` 离屏走查使用。
    ///
    /// `ImageRenderer` 不参与响应者链，因此拿不到真实键盘焦点。没有这个开关，
    /// 焦点环的形状、外扩距离与是否遮住内容就只能靠肉眼在真机上确认。
    var forceFocusRing: Bool {
        get { self[ForceFocusRingKey.self] }
        set { self[ForceFocusRingKey.self] = newValue }
    }
}

/// macOS 14 起才有 `focusEffectDisabled()`；13 上保持系统默认行为。
private struct NativeFocusEffect: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.focusEffectDisabled()
        } else {
            content
        }
    }
}
