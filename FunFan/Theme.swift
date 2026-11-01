import SwiftUI

/// 设计令牌。取值与 `docs/ui-prototype/funfan-design-v2.html` 的 CSS 变量一一对应，
/// 复审依据见 `docs/ui-review-2026-11-01.md`。
///
/// **为什么按外观分叉成两套值，而不是一套动态色**
///
/// 1. 同一个色值服务不了两种外观：原来四个语义色（accent / cool / warm / hot）是
///    按 `#1C1C1E` 深底调的，浅色下实测只有 1.28–2.52:1（正文需 4.5），全部失效；
/// 2. 也不用 `Assets.xcassets` 的 Color Set 或 `NSColor` 动态色：那两条靠
///    `NSAppearance.current` 解析，而 `NSAppearance.current` 在离屏渲染
///    （`FunFan --render`，本项目唯一的视觉验收手段）里拿不到真实外观，
///    等于让「浅色模式」重新变成看不见的东西；
/// 3. 所以这里用 `colorScheme` 显式解析出一套具体色值，经 `@Environment` 注入。
///    视图只认 `palette`，不碰 `NSColor`，走查与真机看到的是同一套。
///
/// 约定：
/// - `accentText` 只给**文字**（需 4.5:1），`accentFill` 给**图形**（环弧/曲线/焦点环，需 3:1）；
/// - `cool/warm/hot` 是**温度轴**，只出现在温度指示物上；
/// - `attention/error` 是**界面轴**，只给提示容器与错误文案。
///   两条轴分开，避免「CPU 62℃」和「免责声明」共用一个黄色。
struct Palette {

    // 文字三档
    let textPrimary: Color
    let textSecondary: Color
    let textTertiary: Color

    // 强调色：文字与图形分档
    let accentText: Color
    let accentFill: Color
    let accentWash: Color

    // 温度轴
    let cool: Color
    let warm: Color
    let hot: Color

    // 界面轴
    let attention: Color
    let attentionWash: Color
    let error: Color
    let errorWash: Color

    // 表面与分隔
    let panelFill: Color
    let cardFill: Color
    let cardStroke: Color
    let insetFill: Color
    let divider: Color

    // 控件
    let track: Color
    let segTrack: Color
    let buttonFill: Color
    let buttonStroke: Color
    /// 开关圆钮：浅色下白钮掉在浅轨道上会糊，改用一个恒定的高对比白
    let knobFill: Color

    /// 按温度取**指示物**颜色。数值本身一律 `textPrimary`，颜色只辅助指示物。
    func temperature(_ celsius: Double?) -> Color {
        guard let celsius else { return textTertiary }
        if celsius >= Theme.hotThreshold { return hot }
        if celsius >= Theme.warnThreshold { return warm }
        return cool
    }

    static func resolve(_ scheme: ColorScheme) -> Palette {
        scheme == .dark ? .dark : .light
    }

    // MARK: - 深色

    static let dark = Palette(
        textPrimary: Color(hex: 0xF5F5F7),
        textSecondary: Color(hex: 0xA1A1A6),
        textTertiary: Color(hex: 0x96969B),

        accentText: Color(hex: 0x46C8FF),
        accentFill: Color(hex: 0x46C8FF),
        accentWash: Color(hex: 0x46C8FF).opacity(0.16),

        cool: Color(hex: 0x4CD988),
        warm: Color(hex: 0xFFBD4B),
        hot: Color(hex: 0xFF6B6B),

        attention: Color(hex: 0xFFBD4B),
        attentionWash: Color(hex: 0xFFBD4B).opacity(0.12),
        error: Color(hex: 0xFF6B6B),
        errorWash: Color(hex: 0xFF6B6B).opacity(0.12),

        panelFill: Color(hex: 0x1C1C1E),
        cardFill: Color(hex: 0x2A2A2E),
        cardStroke: Color.white.opacity(0.08),
        insetFill: Color(hex: 0x141416),
        divider: Color.white.opacity(0.09),

        track: Color.white.opacity(0.10),
        segTrack: Color.white.opacity(0.07),
        buttonFill: Color.white.opacity(0.09),
        buttonStroke: Color.white.opacity(0.14),
        knobFill: Color.white
    )

    // MARK: - 浅色

    static let light = Palette(
        textPrimary: Color(hex: 0x1D1D1F),
        textSecondary: Color(hex: 0x5A5A5A),
        textTertiary: Color(hex: 0x676767),

        accentText: Color(hex: 0x0A5F80),
        accentFill: Color(hex: 0x0B84B8),
        accentWash: Color(hex: 0x0B84B8).opacity(0.12),

        cool: Color(hex: 0x136B37),
        warm: Color(hex: 0x7A4A00),
        hot: Color(hex: 0xB3261E),

        attention: Color(hex: 0x7A4A00),
        attentionWash: Color(hex: 0x7A4A00).opacity(0.09),
        error: Color(hex: 0xB3261E),
        errorWash: Color(hex: 0xB3261E).opacity(0.08),

        panelFill: Color(hex: 0xECECEC),
        cardFill: Color.white,
        cardStroke: Color.black.opacity(0.07),
        insetFill: Color(hex: 0xF4F4F5),
        divider: Color.black.opacity(0.09),

        track: Color.black.opacity(0.08),
        segTrack: Color.black.opacity(0.06),
        buttonFill: Color(hex: 0xF4F4F5),
        buttonStroke: Color.black.opacity(0.13),
        knobFill: Color.white
    )
}

// MARK: - 注入

private struct PaletteKey: EnvironmentKey {
    /// 兜底取深色：所有根视图都会显式注入，这里只防「某个视图被单独实例化」。
    static let defaultValue = Palette.dark
}

extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

private struct FunFanTheme: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content.environment(\.palette, Palette.resolve(scheme))
    }
}

extension View {
    /// 根视图上调用一次：把当前 `colorScheme` 解析成一套色令牌注入下层。
    ///
    /// 必须加在**窗口/弹窗的根视图**上（`NSHostingController` 的 rootView、
    /// `--render` 的 content），子视图才有 `palette` 可读。
    func funfanTheme() -> some View { modifier(FunFanTheme()) }
}

// MARK: - 阈值与排版

enum Theme {

    /// 温度三态阈值（固定值，已确认决策 H3）。
    static let warnThreshold: Double = 60
    static let hotThreshold: Double = 75

    /// 字号刻度。
    ///
    /// 复审发现原来散着 13 个档位（8/9/10/11/12/13/14/15/19/20/22/24/26），
    /// 110 个文本节点里 92 个 ≤ 11pt、24 个 ≤ 9pt —— 「越重要越小」。
    /// 收敛成四档，`meta` 是元信息下限，不再出现 8–10pt。
    enum Typo {
        /// 窗口标题
        static let title = Font.system(size: 15, weight: .semibold)
        /// 正文、设置行标题、规则名
        static let body = Font.system(size: 12)
        static let bodyStrong = Font.system(size: 12, weight: .medium)
        /// 说明文字、标签、坐标轴、元信息
        static let meta = Font.system(size: 11)
        static let metaStrong = Font.system(size: 11, weight: .medium)
        /// 大号数值（RPM）
        static let value = Font.system(size: 19, weight: .medium).monospacedDigit()
        /// 小号数值（温度、转速、百分比）
        static let smallValue = Font.system(size: 13, weight: .medium).monospacedDigit()
        /// 与 `meta` 同字号但等宽的读数（探测点、坐标轴）
        static let metaValue = Font.system(size: 11).monospacedDigit()
        static let metaValueStrong = Font.system(size: 11, weight: .medium).monospacedDigit()
    }
}

// MARK: - 十六进制

extension Color {
    /// `Color(hex: 0x46C8FF)`：直接用设计稿里的十六进制，避免手抄 0–1 浮点出错。
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}
