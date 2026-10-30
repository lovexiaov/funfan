import SwiftUI

// 自建基础控件。
//
// 为什么不用原生 `Picker(.segmented)` / `Toggle(.switch)`：
// 1. 它们是 AppKit 宿主控件，无法被 `ImageRenderer` 离屏渲染，设计走查拿不到真实像素；
// 2. 原生控件的圆角、高亮色、按下态不完全受我们控制，与既有令牌（accent #46C8FF）存在偏差。
// 自建后：视觉完全受控、可截图校验、并补齐 VoiceOver 语义。

/// 策略分段控件（替代 `Picker(.segmented)`）。
struct StrategySegmented: View {

    @Binding var selection: ControlStore.Strategy
    var isDisabled: Bool = false

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
                                .fill(isSelected ? Theme.accent.opacity(0.20) : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(isSelected ? Theme.accent.opacity(0.45) : Color.clear, lineWidth: 0.5)
                        )
                        .foregroundStyle(
                            !isDisabled ? (isSelected ? Theme.accent : Color.secondary)
                                        : Color.secondary.opacity(0.45)
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
                .fill(Color.primary.opacity(isDisabled ? 0.04 : 0.07))
        )
        .opacity(isDisabled ? 0.75 : 1)
    }
}

/// 开关（替代 `Toggle(.switch)`）。26×15 轨道，带 150 ms 缓动。
struct FunFanToggle: View {

    @Binding var isOn: Bool
    var label: String?
    var size: CGFloat = 26

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 7) {
                if let label {
                    Text(label)
                        .font(.system(size: 11))
                        .foregroundStyle(.primary)
                }
                ZStack {
                    Capsule()
                        .fill(isOn ? Theme.accent : Color.secondary.opacity(0.32))
                        .frame(width: size, height: size * 0.58)
                    Circle()
                        .fill(Color.white)
                        .frame(width: size * 0.42, height: size * 0.42)
                        .shadow(color: .black.opacity(0.12), radius: 1, x: 0, y: 0.5)
                        .offset(x: isOn ? size * 0.24 : -size * 0.24)
                }
                .animation(.easeOut(duration: 0.15), value: isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 胶囊半高即圆角半径，环才是胶囊形状而不是矩形
        .funfanFocusRing(cornerRadius: size * 0.29, outset: 3)
        // 注：`.accessibilityAddTraits(.isToggle)` 需 macOS 14+，本项目部署目标为 13，
        // 故用 label + value + hint 组合表达同样的开关语义。
        .accessibilityLabel(label ?? "开关")
        .accessibilityValue(isOn ? "开" : "关")
        .accessibilityHint("点击切换")
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

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 10, weight: .medium))
                }
                Text(title)
                    .font(.system(size: 11))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(isEnabled ? 0.09 : 0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.primary.opacity(isEnabled ? 0.14 : 0.06), lineWidth: 0.5)
            )
            .foregroundStyle(isEnabled ? Color.primary : Color.secondary.opacity(0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .funfanFocusRing(cornerRadius: 6)
        .disabled(!isEnabled)
        .accessibilityLabel(title)
    }
}

extension ControlStore.Strategy {
    var help: String {
        switch self {
        case .automatic: return "完全交给 macOS 控制风扇"
        case .fixed: return "固定在一个转速"
        case .curve: return "按温度曲线连续调速（永远不会低于安全下限）"
        case .rules: return "按温度规则自动提速（不会低于系统默认下限）"
        }
    }
}
