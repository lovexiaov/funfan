import SwiftUI
import FunFanCore

// 自建基础控件。
//
// 为什么不用原生 `Picker(.segmented)` / `Toggle(.switch)`：
// 1. 它们是 AppKit 宿主控件，无法被 `ImageRenderer` 离屏渲染，设计走查拿不到真实像素；
// 2. 原生控件的圆角、高亮色、按下态不完全受我们控制，与令牌存在偏差。
// 自建后：视觉完全受控、可截图校验、并补齐 VoiceOver 语义。

/// 策略分段控件（替代 `Picker(.segmented)`）。
struct StrategySegmented: View {

    @Binding var selection: ControlStore.Strategy
    var isDisabled: Bool = false

    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 3) {
            ForEach(ControlStore.Strategy.allCases) { item in
                let isSelected = selection == item

                Button {
                    selection = item
                } label: {
                    Text(item.label)
                        .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(isSelected ? palette.accentWash : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(isSelected ? palette.accentFill.opacity(0.45) : Color.clear, lineWidth: 0.5)
                        )
                        // 禁用态不再整体压 alpha（会连同文字一起掉到 3:1 以下），
                        // 改成明确的灰阶：仍然读得清，但看得出不可点。
                        .foregroundStyle(
                            isDisabled ? palette.textTertiary
                                       : (isSelected ? palette.accentText : palette.textSecondary)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .funfanFocusRing(cornerRadius: 6, outset: 1.5)
                .disabled(isDisabled)
                .accessibilityLabel("调速策略 \(item.label)")
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                .help(item.help)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(palette.segTrack)
        )
    }
}

/// 开关（替代 `Toggle(.switch)`）。26×15 轨道，带 150 ms 缓动。
struct FunFanToggle: View {

    @Binding var isOn: Bool
    var label: String?
    var size: CGFloat = 26
    /// 不可用时只是把轨道与文字降一档灰（仍然可读），不像以前整块 `opacity(0.45)`。
    var isEnabled: Bool = true

    @Environment(\.palette) private var palette

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 7) {
                if let label {
                    Text(label)
                        .font(Theme.Typo.meta)
                        .foregroundStyle(isEnabled ? palette.textPrimary : palette.textTertiary)
                }
                ZStack {
                    // 轨道走图形档（accentFill）；关闭态用中性轨道而不是
                    // `secondary.opacity(0.32)` —— 后者在浅色底上几乎看不见。
                    Capsule()
                        .fill(isOn ? palette.accentFill.opacity(isEnabled ? 1 : 0.4) : palette.track)
                        .frame(width: size, height: size * 0.58)
                    Circle()
                        .fill(palette.knobFill)
                        .frame(width: size * 0.42, height: size * 0.42)
                        .shadow(color: .black.opacity(0.18), radius: 1, x: 0, y: 0.5)
                        .offset(x: isOn ? size * 0.24 : -size * 0.24)
                }
                .overlay(
                    Capsule()
                        .strokeBorder(palette.cardStroke, lineWidth: 0.5)
                )
                .animation(.easeOut(duration: 0.15), value: isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        // 胶囊半高即圆角半径，环才是胶囊形状而不是矩形
        .funfanFocusRing(cornerRadius: size * 0.29, outset: 3)
        // 注：`.accessibilityAddTraits(.isToggle)` 需 macOS 14+，本项目部署目标为 13，
        // 故用 label + value + hint 组合表达同样的开关语义。
        .accessibilityLabel(label ?? "开关")
        .accessibilityValue(isOn ? "开" : "关")
        .accessibilityHint("点击切换")
    }
}

// MARK: - 通用分段选择

/// 等宽分段选择，可绑定任意 `Hashable` 选项。
///
/// 与 `StrategySegmented` 视觉一致，区别是它绑定具体类型（策略枚举带 help、
/// 带禁用逻辑）；这个给设置页的「外观」这类简单三态用。
struct SegmentedPicker<Option: Hashable>: View {

    let options: [Option]
    let title: (Option) -> String
    @Binding var selection: Option

    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let isSelected = selection == option
                Button {
                    selection = option
                } label: {
                    Text(title(option))
                        .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(isSelected ? palette.accentWash : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(isSelected ? palette.accentFill.opacity(0.45) : Color.clear, lineWidth: 0.5)
                        )
                        .foregroundStyle(isSelected ? palette.accentText : palette.textSecondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .funfanFocusRing(cornerRadius: 6, outset: 1.5)
                .accessibilityLabel(title(option))
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(palette.segTrack)
        )
    }
}

// MARK: - 温度指示物

/// 温度状态指示物。
///
/// 复审发现两个问题，这里一起解决：
/// 1. **「一切正常」原来是四个绿点 + 四个绿字** —— 颜色信息量为 0，还把主数据
///    （数值）降级成彩色文本。现在数值恒为 `textPrimary`，状态只由这个指示物表达；
/// 2. 只靠颜色区分状态对色觉障碍用户不成立，所以三档在**形态**上也不同：
///    正常 = 实心点 / 偏高 = 点 + 外环 / 过热 = 三角。
struct TemperatureIndicator: View {

    enum Level: Equatable {
        case normal, warm, hot, unavailable

        init(_ celsius: Double?) {
            guard let celsius else { self = .unavailable; return }
            if celsius >= Theme.hotThreshold { self = .hot }
            else if celsius >= Theme.warnThreshold { self = .warm }
            else { self = .normal }
        }
    }

    let level: Level
    let color: Color
    var size: CGFloat = 7

    var body: some View {
        ZStack {
            switch level {
            case .normal:
                Circle().fill(color)
            case .warm:
                Circle()
                    .strokeBorder(color, lineWidth: 1.5)
                    .padding(size * 0.18)
                Circle()
                    .fill(color)
                    .padding(size * 0.36)
            case .hot:
                Triangle()
                    .fill(color)
            case .unavailable:
                Circle()
                    .strokeBorder(color, lineWidth: 1)
            }
        }
        .frame(width: size, height: size)
    }

    private struct Triangle: Shape {
        func path(in rect: CGRect) -> Path {
            Path { path in
                path.move(to: CGPoint(x: rect.midX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
                path.closeSubpath()
            }
        }
    }
}

// MARK: - 文案辅助

/// 小号按钮（替代 `.bordered` + `.controlSize(.small)`）。
///
/// 原生 bordered 按钮是 AppKit 宿主控件：`ImageRenderer` 离屏渲染时只能画出一块
/// 黄底禁止符，设计走查拿不到真实布局（和 `StrategySegmented` / `FunFanToggle`
/// 当初被自建是同一个原因）。自绘后视觉与截图都可控。
struct FunFanButton: View {

    let title: String
    var systemImage: String?
    var isEnabled: Bool = true
    var action: () -> Void

    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 10, weight: .medium))
                }
                Text(title)
                    .font(Theme.Typo.meta)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(palette.buttonFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(palette.buttonStroke, lineWidth: 0.5)
            )
            .foregroundStyle(isEnabled ? palette.textPrimary : palette.textTertiary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .funfanFocusRing(cornerRadius: 6)
        .disabled(!isEnabled)
        .accessibilityLabel(title)
    }
}

// MARK: - 图标按钮

/// 纯图标按钮。
///
/// 替代 `.buttonStyle(.borderless)` 的原生按钮：一来它同样是 AppKit 宿主控件
/// （离屏走查渲染不出来），二来原生 borderless 的**命中区只有字形那么大**，
/// 列表行右侧的编辑/删除图标实际只有 12×12，很容易点空。
/// 这里固定 24×24 命中区 + hover 底色，视觉上也与自绘控件统一。
struct IconButton: View {

    let systemImage: String
    var help: String
    var isDestructive: Bool = false
    var action: () -> Void

    @Environment(\.palette) private var palette
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHovering ? palette.buttonFill : Color.clear)
                )
                .foregroundStyle(isDestructive && isHovering ? palette.error : palette.textSecondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .funfanFocusRing(cornerRadius: 6, outset: 1.5)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

extension ControlStrategy {
    var help: String {
        switch self {
        case .automatic: return "完全交给 macOS 控制风扇"
        case .fixed: return "固定在一个转速"
        case .curve: return "按温度曲线连续调速（永远不会低于安全下限）"
        case .rules: return "按温度规则自动提速（不会低于系统默认下限）"
        }
    }
}

/// 调速依据的文案。
///
/// 放在 App 而不是 `FunFanCore`：Core 只认 `.peak` / `.average` 两个口径，
/// 中文措辞属于界面，改文案不该动到引擎。
extension TemperatureAggregation {
    /// 设置页里的选项名。
    var settingLabel: String {
        switch self {
        case .peak: return "最高温度"
        case .average: return "平均温度"
        }
    }

    /// 读数处的短标签（曲线编辑器顶部的温度 chip）。
    var shortLabel: String {
        switch self {
        case .peak: return "最热"
        case .average: return "均温"
        }
    }
}

extension View {
    /// 只在条件成立时挂 `help`。
    ///
    /// 为什么需要：SwiftUI 没有条件修饰符，直接写 `.help(cond ? "..." : "")`
    /// 会给「无提示」的视图留下一个空 tooltip 占位（鼠标悬停时闪一下空白）。
    @ViewBuilder
    func help(if condition: Bool, _ text: String) -> some View {
        if condition {
            self.help(text)
        } else {
            self
        }
    }
}
