import SwiftUI
import FunFanCore

/// 曲线编辑窗口：拖拽折线 + 安全下限可视化 + 预设。
///
/// 三个刻意的设计选择：
/// 1. **斜纹区是「你画不到的地方」**：安全下限随温度线性抬升，画在曲线下方，
///    用户拖到里面会被弹回去。与其在文字里解释「不会低于安全值」，不如画出来。
///    这里刻意**不用红色**——红色在本 App 里只表示「真的热了」（≥75℃），
///    安全下限是正常机制而不是危险信号，用红色会被误读成「这块区域很危险」。
/// 2. **顶部同时显示「曲线给的」与「实际下发的」**：两者不一致时说明安全下限接管了，
///    这是用户最需要知道的一件事，也是消除「我明明画了 30% 怎么还在转」的疑惑。
/// 3. **步进 0.5℃ / 10 RPM**：比这更细的差别 SMC 侧体现不出来，只会让数字乱跳。
struct CurveEditorView: View {

    @ObservedObject var store: CurveStore
    @ObservedObject var control: ControlStore
    @ObservedObject var monitor: MonitorStore

    @Environment(\.palette) private var palette

    @State private var draggingIndex: Int?
    @State private var selectedIndex: Int?

    /// 绘图温度范围：比清洗区间（20–110）收一点，留出拖动余量。
    private let tempRange: ClosedRange<Double> = 25...105
    private let plotHeight: CGFloat = 240

    private var limits: FanLimits { control.limits }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(palette.divider)
            canvasSection
            Divider().overlay(palette.divider)
            presetsRow
            Divider().overlay(palette.divider)
            footer
        }
        .frame(minWidth: 620, minHeight: 520)
        .background(palette.panelFill)
    }

    // MARK: - 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("温度曲线")
                    .font(Theme.Typo.title)
                    .foregroundStyle(palette.textPrimary)
                if let preset = store.preset {
                    Text(preset.label)
                        .font(Theme.Typo.metaStrong)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(palette.accentWash, in: Capsule())
                        .foregroundStyle(palette.accentText)
                } else {
                    Text("自定义")
                        .font(Theme.Typo.metaStrong)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(palette.insetFill, in: Capsule())
                        .foregroundStyle(palette.textSecondary)
                }
                Spacer()
                liveSummary
            }

            Text("拖动控制点改变映射；斜纹区域是安全下限，曲线拖不进去。")
                .font(Theme.Typo.meta)
                .foregroundStyle(palette.textTertiary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    /// 「曲线给的」vs「实际下发的」——不一致就说明安全下限在接管。
    private var liveSummary: some View {
        HStack(spacing: 10) {
            if let die = monitor.hottestCelsius {
                HStack(spacing: 4) {
                    TemperatureIndicator(level: .init(die), color: palette.temperature(die), size: 6)
                    statChip("最热", String(format: "%.0f℃", die), color: palette.textPrimary)
                }
            }
            if let die = monitor.hottestCelsius, let curveRpm = store.curve.rpm(at: die) {
                statChip("曲线", String(format: "%.0f", curveRpm), color: palette.textPrimary)
            }
            if let commanded = control.automatedRpm {
                statChip("下发", String(format: "%.0f", commanded), color: palette.accentText)
            }
        }
    }

    private func statChip(_ label: String, _ value: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(Theme.Typo.meta)
                .foregroundStyle(palette.textTertiary)
            Text(value)
                .font(Theme.Typo.metaValueStrong)
                .foregroundStyle(color)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(palette.insetFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    // MARK: - 画布

    private var canvasSection: some View {
        GeometryReader { geometry in
            let rect = plotRect(in: geometry.size)

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(palette.insetFill)

                grid(in: rect)
                safetyBand(in: rect)
                curveBand(in: rect)
                curveStroke(in: rect)
                currentMarker(in: rect)
                handles(in: rect)
                axisLabels(in: rect, size: geometry.size)
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(in: rect))
        }
        .frame(height: plotHeight + 26)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    /// 绘图区（留出左侧刻度与底部温度标签的空间）。
    private func plotRect(in size: CGSize) -> CGRect {
        CGRect(
            x: 48,
            y: 10,
            width: max(size.width - 48 - 16, 10),
            height: max(size.height - 10 - 26, 10)
        )
    }

    private func xPos(_ celsius: Double, in rect: CGRect) -> CGFloat {
        let span = tempRange.upperBound - tempRange.lowerBound
        let ratio = (celsius - tempRange.lowerBound) / span
        return rect.minX + rect.width * CGFloat(min(max(ratio, 0), 1))
    }

    private func yPos(_ rpm: Double, in rect: CGRect) -> CGFloat {
        let low = limits.minRpm
        let span = max(limits.normalizedMax - low, 1)
        let ratio = (rpm - low) / span
        return rect.maxY - rect.height * CGFloat(min(max(ratio, 0), 1))
    }

    private func celsiusValue(atX x: CGFloat, in rect: CGRect) -> Double {
        let ratio = Double((x - rect.minX) / max(rect.width, 1))
        return tempRange.lowerBound + (tempRange.upperBound - tempRange.lowerBound) * min(max(ratio, 0), 1)
    }

    private func rpmValue(atY y: CGFloat, in rect: CGRect) -> Double {
        let ratio = Double((rect.maxY - y) / max(rect.height, 1))
        return limits.minRpm + (limits.normalizedMax - limits.minRpm) * min(max(ratio, 0), 1)
    }

    // MARK: 画布元素

    private func grid(in rect: CGRect) -> some View {
        Path { path in
            // 温度竖线：每 10℃
            var celsius = 30.0
            while celsius <= 100 {
                let x = xPos(celsius, in: rect)
                path.move(to: CGPoint(x: x, y: rect.minY))
                path.addLine(to: CGPoint(x: x, y: rect.maxY))
                celsius += 10
            }
            // 转速横线：4 等分
            for step in 0...4 {
                let rpm = limits.minRpm + (limits.normalizedMax - limits.minRpm) * Double(step) / 4
                let y = yPos(rpm, in: rect)
                path.move(to: CGPoint(x: rect.minX, y: y))
                path.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
        }
        .stroke(palette.divider, lineWidth: 0.5)
    }

    /// 安全下限区域：画不出曲线的地方。
    ///
    /// 用**中性斜纹**而不是红色色块。原来的红色半透明带会被读成「这块区域很危险」，
    /// 但安全下限其实是保护机制；更要紧的是红色在本 App 里已经表示「≥75℃ 过热」，
    /// 两者同色会让用户在最需要分辨的时候分不清。
    private func safetyBand(in rect: CGRect) -> some View {
        let region = floorPath(in: rect, closeToBottom: true)
        return ZStack(alignment: .topLeading) {
            region.fill(palette.textPrimary.opacity(0.045))
            hatch(in: rect)
                .stroke(palette.textTertiary.opacity(0.30), lineWidth: 1)
                .mask(region.fill(Color.black))
            floorPath(in: rect, closeToBottom: false)
                .stroke(
                    palette.textTertiary.opacity(0.65),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                )
        }
    }

    /// 45° 斜纹，裁剪到安全下限区域内（作为「不可用区域」的通用视觉语言，
    /// 与红/橙无关，色觉障碍用户也能看出这是「另一类区域」）。
    private func hatch(in rect: CGRect, spacing: CGFloat = 7) -> Path {
        var path = Path()
        var x = rect.minX - rect.height
        while x < rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += spacing
        }
        return path
    }

    private func floorPath(in rect: CGRect, closeToBottom: Bool) -> Path {
        var path = Path()
        let samples = 60
        for index in 0...samples {
            let span = tempRange.upperBound - tempRange.lowerBound
            let celsius = tempRange.lowerBound + span * Double(index) / Double(samples)
            let floor = SafetyPolicy.floorRpm(dieCelsius: celsius, limits: limits)
            let point = CGPoint(x: xPos(celsius, in: rect), y: yPos(floor, in: rect))
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        if closeToBottom {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }

    private func curveBand(in rect: CGRect) -> some View {
        guard let first = store.curve.points.first, let last = store.curve.points.last else {
            return AnyView(EmptyView())
        }
        var path = Path()
        path.move(to: CGPoint(x: xPos(first.celsius, in: rect), y: yPos(first.rpm, in: rect)))
        for point in store.curve.points.dropFirst() {
            path.addLine(to: CGPoint(x: xPos(point.celsius, in: rect), y: yPos(point.rpm, in: rect)))
        }
        path.addLine(to: CGPoint(x: xPos(last.celsius, in: rect), y: rect.maxY))
        path.addLine(to: CGPoint(x: xPos(first.celsius, in: rect), y: rect.maxY))
        path.closeSubpath()
        return AnyView(path.fill(palette.accentFill.opacity(0.14)))
    }

    private func curveStroke(in rect: CGRect) -> some View {
        var path = Path()
        for (index, point) in store.curve.points.enumerated() {
            let location = CGPoint(x: xPos(point.celsius, in: rect), y: yPos(point.rpm, in: rect))
            if index == 0 { path.move(to: location) } else { path.addLine(to: location) }
        }
        return path.stroke(
            palette.accentFill,
            style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
        )
    }

    /// 当前温度标记：中性虚线 + 曲线上一个点。
    ///
    /// 原来用琥珀色——和顶部「最热」数值的琥珀色重复，两条线（温度线、安全边界）
    /// 又都是彩色，画布上三四种颜色互相抢。现在只有曲线本身带色。
    @ViewBuilder
    private func currentMarker(in rect: CGRect) -> some View {
        if let die = monitor.hottestCelsius, tempRange.contains(die) {
            let x = xPos(die, in: rect)
            Path { path in
                path.move(to: CGPoint(x: x, y: rect.minY))
                path.addLine(to: CGPoint(x: x, y: rect.maxY))
            }
            .stroke(palette.textSecondary.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

            if let rpm = store.curve.rpm(at: die) {
                Circle()
                    .fill(palette.accentFill)
                    .frame(width: 7, height: 7)
                    .position(x: x, y: yPos(rpm, in: rect))
            }
        }
    }

    private func handles(in rect: CGRect) -> some View {
        ForEach(Array(store.curve.points.enumerated()), id: \.offset) { index, point in
            let isActive = draggingIndex == index || selectedIndex == index
            Circle()
                .fill(palette.cardFill)
                .overlay(
                    Circle().strokeBorder(palette.accentFill, lineWidth: isActive ? 2.5 : 2)
                )
                .frame(width: isActive ? 13 : 10, height: isActive ? 13 : 10)
                .shadow(color: palette.accentFill.opacity(isActive ? 0.45 : 0), radius: 4)
                .position(x: xPos(point.celsius, in: rect), y: yPos(point.rpm, in: rect))
                .animation(.easeOut(duration: 0.12), value: isActive)
                .accessibilityLabel("控制点 \(Int(point.celsius))℃ \(Int(point.rpm)) 转")
        }
    }

    /// 坐标轴刻度。
    ///
    /// 字号从 8pt 抬到 11pt：8pt 是复审里最小的文字，而它承担的是「读数」——
    /// 越需要看清的东西越小，是这次要修的核心问题之一。
    private func axisLabels(in rect: CGRect, size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            // 转速刻度（左）
            ForEach(0...4, id: \.self) { step in
                let rpm = limits.minRpm + (limits.normalizedMax - limits.minRpm) * Double(step) / 4
                Text(String(format: "%.0f", rpm))
                    .font(Theme.Typo.metaValue)
                    .foregroundStyle(palette.textTertiary)
                    .frame(width: 42, alignment: .trailing)
                    .position(x: 25, y: yPos(rpm, in: rect))
            }
            // 温度刻度（下）
            ForEach([30, 50, 70, 90], id: \.self) { celsius in
                Text("\(celsius)°")
                    .font(Theme.Typo.metaValue)
                    .foregroundStyle(palette.textTertiary)
                    .position(x: xPos(Double(celsius), in: rect), y: size.height - 12)
            }
        }
    }

    // MARK: 交互

    private func dragGesture(in rect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if draggingIndex == nil {
                    draggingIndex = nearestHandle(to: value.startLocation, in: rect)
                    selectedIndex = draggingIndex
                }
                guard let index = draggingIndex else { return }
                store.movePoint(
                    index: index,
                    celsius: celsiusValue(atX: value.location.x, in: rect),
                    rpm: rpmValue(atY: value.location.y, in: rect)
                )
            }
            .onEnded { _ in
                draggingIndex = nil
            }
    }

    /// 命中半径 22pt：手指/触控板都能稳定抓到一个点，又不会误抓相邻点。
    private func nearestHandle(to location: CGPoint, in rect: CGRect) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for (index, point) in store.curve.points.enumerated() {
            let center = CGPoint(x: xPos(point.celsius, in: rect), y: yPos(point.rpm, in: rect))
            let distance = hypot(center.x - location.x, center.y - location.y)
            guard distance <= 22 else { continue }
            if best == nil || distance < best!.distance {
                best = (index, distance)
            }
        }
        return best?.index
    }

    // MARK: - 预设

    private var presetsRow: some View {
        HStack(spacing: 8) {
            Text("预设")
                .font(Theme.Typo.meta)
                .foregroundStyle(palette.textSecondary)

            ForEach(CurvePreset.allCases) { preset in
                Button {
                    store.apply(preset, limits: limits)
                    selectedIndex = nil
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(preset.label)
                            .font(.system(size: 12, weight: store.preset == preset ? .semibold : .regular))
                            .foregroundStyle(palette.textPrimary)
                        Text(preset.detail)
                            .font(Theme.Typo.meta)
                            .foregroundStyle(palette.textSecondary)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(store.preset == preset ? palette.accentWash : palette.insetFill)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(store.preset == preset ? palette.accentFill.opacity(0.5) : palette.cardStroke, lineWidth: 0.8)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .funfanFocusRing(cornerRadius: 7, outset: 2)
                .help(preset.detail)
            }

            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    // MARK: - 底部

    private var footer: some View {
        HStack(spacing: 10) {
            FunFanButton(
                title: "在当前温度加点",
                systemImage: "plus.circle",
                isEnabled: store.curve.points.count < CurvePersistence.maxPoints && monitor.hottestCelsius != nil
            ) {
                let celsius = monitor.hottestCelsius ?? 60
                let rpm = store.curve.rpm(at: celsius) ?? limits.minRpm
                if store.addPoint(celsius: celsius, rpm: rpm) {
                    selectedIndex = nil
                }
            }
            .help(monitor.hottestCelsius == nil ? "还没有温度采样" : "在最高温处插入一个控制点")

            FunFanButton(
                title: "删除选中点",
                systemImage: "minus.circle",
                isEnabled: selectedIndex != nil && store.curve.points.count > 2
            ) {
                if let index = selectedIndex, store.removePoint(index: index) {
                    selectedIndex = nil
                }
            }

            Spacer()

            Text("\(store.curve.points.count) 个控制点")
                .font(Theme.Typo.meta)
                .foregroundStyle(palette.textTertiary)

            FunFanButton(title: "恢复均衡") {
                store.resetToBalanced()
                selectedIndex = nil
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }
}
