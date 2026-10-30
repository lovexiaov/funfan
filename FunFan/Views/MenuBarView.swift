import SwiftUI
import FunFanCore

/// 菜单栏 Popover 主界面。
struct MenuBarView: View {

    @ObservedObject var monitor: MonitorStore
    @ObservedObject var control: ControlStore
    @ObservedObject var diagnostics: DiagnosticsStore
    @ObservedObject var installer: HelperInstaller
    var onOpenRules: () -> Void
    var onOpenCurve: () -> Void
    var onOpenSettings: () -> Void
    var onQuit: () -> Void

    @State private var showCores: Bool

    /// `initialShowCores` 只给离屏渲染走查用（`--render popover-cores`），
    /// 正常运行时展开状态由用户点击决定。
    init(
        monitor: MonitorStore,
        control: ControlStore,
        diagnostics: DiagnosticsStore,
        installer: HelperInstaller,
        initialShowCores: Bool = false,
        onOpenRules: @escaping () -> Void,
        onOpenCurve: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.monitor = monitor
        self.control = control
        self.diagnostics = diagnostics
        self.installer = installer
        self.onOpenRules = onOpenRules
        self.onOpenCurve = onOpenCurve
        self.onOpenSettings = onOpenSettings
        self.onQuit = onQuit
        _showCores = State(initialValue: initialShowCores)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !control.conflict.isEmpty {
                conflictBanner
            }
            fanSection
            temperatureSection
            if monitor.battery.present {
                batterySection
            }
            controlSection
            footer
        }
        .padding(14)
        .frame(width: 320)
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "fanblades.fill")
                .foregroundStyle(Theme.accent)
            Text("FunFan")
                .font(Theme.titleFont)
            Spacer()
            if let date = monitor.lastSample {
                Text(date, style: .relative)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            // 只有图标，环要比字形让出去更多才不至于像个紧箍
            .funfanFocusRing(cornerRadius: 5, outset: 4)
            .foregroundStyle(.secondary)
            .help("设置")
            .accessibilityLabel("设置")
        }
    }

    // MARK: - 冲突提示

    /// 第三方控制提示条。
    ///
    /// 文案刻意分开两句：第一句说**谁**（识别得到才说名字），
    /// 第二句说**我们做了什么**（暂停接管），避免用户以为是自己配错了。
    private var conflictBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.warm)
                Text(control.conflictSource.map { "\($0) 正在控制风扇" } ?? "其他程序正在控制风扇")
                    .font(.system(size: 11, weight: .medium))
                Spacer(minLength: 0)
            }

            Text(control.conflict.map(\.summary).joined(separator: "；")
                 + "。FunFan 已暂停接管，避免两个程序互相覆盖转速。退出对方软件后点「重新检测」。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                FunFanButton(title: "重新检测", systemImage: "arrow.clockwise") {
                    control.redetectConflict()
                }
                FunFanButton(title: "仍要接管", systemImage: "hand.raised") {
                    control.takeOverAnyway()
                }
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.warm.opacity(0.10))
        )
    }

    // MARK: - 风扇

    private var fanSection: some View {
        HStack(spacing: 16) {
            FanRing(
                actual: monitor.primaryFan?.actualRpm ?? 0,
                limits: monitor.primaryFan?.limits
            )

            VStack(alignment: .leading, spacing: 6) {
                if let fan = monitor.primaryFan {
                    // 自动模式下 `F0Tg` 留着上一次的残留值，显示出来会被理解成
                    // 「还在按这个目标跑」。目标是手动模式才成立的概念，自动时留空。
                    detailRow("目标", fan.isManual ? String(format: "%.0f RPM", fan.targetRpm) : "—")
                    detailRow("区间", String(format: "%.0f–%.0f", fan.minRpm, fan.normalizedMaxForUI))
                    detailRow("模式", fan.isManual ? "手动" : "系统自动")
                    if monitor.fans.count > 1 {
                        detailRow("风扇数", "\(monitor.fans.count)")
                    }
                } else {
                    Text("未检测到风扇")
                        .font(Theme.labelFont)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(cardBackground)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .leading)
            Text(value)
                .font(Theme.smallValueFont)
        }
    }

    // MARK: - 温度

    private var temperatureSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("硬件温度")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(monitor.sensorCount) 个传感器")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                tempChip("CPU 均温", monitor.cpuAverage)
                tempChip("GPU 均温", monitor.gpuAverage)
                tempChip("SSD", monitor.ssdAverage)
                tempChip("环境", monitor.ambientAverage)
            }

            if !monitor.coreGroups.isEmpty {
                coreDisclosure
                if showCores {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(monitor.coreGroups) { group in
                            coreGroupRow(group)
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
    }

    /// 自绘展开行。
    ///
    /// 原来用 `DisclosureGroup`，在 NSPopover 里点击不生效：它内部的展开箭头
    /// 走的是 AppKit 宿主控件那条路，popover 这种非激活窗口里事件经常被吞掉，
    /// 只有三角本身的极小命中区偶尔灵。改成一个铺满整行的 Button（`.plain`
    /// 样式 + `contentShape`），点哪儿都算，命中区从几个点变成整行。
    private var coreDisclosure: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                showCores.toggle()
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .rotationEffect(.degrees(showCores ? 90 : 0))
                Text(showCores ? "收起各核心温度" : "展开各核心温度")
                    .font(.system(size: 10))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.accent)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .funfanFocusRing(cornerRadius: 6, outset: 2)
        .accessibilityLabel(showCores ? "收起各核心温度" : "展开各核心温度")
        .help(showCores ? "收起逐核温度" : "展开每个 CPU 核心的温度")
    }

    private func tempChip(_ label: String, _ value: Double?) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Theme.color(forCelsius: value))
                .frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(value.map { String(format: "%.0f°", $0) } ?? "—")
                .font(Theme.smallValueFont)
                .foregroundStyle(Theme.color(forCelsius: value))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(cardBackground)
    }

    private func coreGroupRow(_ group: CoreGroup) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(group.title)
                    .font(.system(size: 10, weight: .medium))
                Spacer()
                Text(String(format: "%.1f°", group.average))
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.color(forCelsius: group.average))
            }
            if group.confirmedCores.isEmpty {
                Text("（仅簇均温，未逐核确认）")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(Array(group.confirmedCores.enumerated()), id: \.offset) { _, core in
                    HStack {
                        Text(core.name)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.1f°", core.celsius))
                            .font(.system(size: 9).monospacedDigit())
                            .foregroundStyle(Theme.color(forCelsius: core.celsius))
                    }
                }
            }
        }
        .padding(.leading, 4)
    }

    // MARK: - 电量

    private var batterySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("电池")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if monitor.battery.isCharging {
                    Label("充电中", systemImage: "bolt.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.cool)
                } else if monitor.battery.externalConnected {
                    Text("外接电源")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 14) {
                if let pct = monitor.battery.percentage {
                    Text(String(format: "%.0f%%", pct))
                        .font(Theme.valueFont)
                }
                if let health = monitor.battery.health {
                    smallStat("健康", String(format: "%.0f%%", health))
                }
                if let cycles = monitor.battery.cycleCount {
                    smallStat("循环", "\(cycles)")
                }
                if let watts = monitor.battery.powerWatts, abs(watts) > 0.05 {
                    smallStat("功率", String(format: "%.1fW", abs(watts)))
                }
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .background(cardBackground)
    }

    private func smallStat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 11, weight: .medium).monospacedDigit())
        }
    }

    // MARK: - 控制

    private var controlSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            StrategySegmented(
                selection: $control.strategy,
                isDisabled: !control.helperStatus.isReady
            )

            if control.strategy == .fixed && control.helperStatus.isReady {
                HStack(spacing: 8) {
                    Slider(
                        value: $control.fixedRpm,
                        in: control.limits.minRpm...control.limits.normalizedMax,
                        step: 50
                    ) { editing in
                        if !editing { control.apply() }
                    }
                    Text(String(format: "%.0f", control.fixedRpm))
                        .font(Theme.smallValueFont)
                        .frame(width: 44, alignment: .trailing)
                }
            }

            if control.strategy == .rules {
                rulesStatus
            }

            if control.strategy == .curve {
                curveStatus
            }

            if let message = control.message {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(control.helperStatus.isReady ? .secondary : Theme.warm)
            }

            if !control.helperStatus.isReady {
                helperPrompt
            }
        }
    }

    /// 未安装后台组件时的引导。
    ///
    /// 以前这里只是一行灰字「跑 sudo bash scripts/install-helper.sh」——
    /// 等于把最容易劝退的一步丢回给用户。现在给一个按钮，点了就装：
    /// 能走系统登记就系统登记（一次授权），走不通就弹一次管理员密码直装。
    private var helperPrompt: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.warm)
                Text("只能监控，还不能控制风扇")
                    .font(.system(size: 11, weight: .medium))
                Spacer(minLength: 0)
            }

            Text(installer.note
                 ?? "控制风扇需要安装一个后台组件（只装一次）。它只做一件事：代表 FunFan 写转速，FunFan 退出就立刻交还系统。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                FunFanButton(
                    title: installer.isBusy ? "安装中…" : "一键启用",
                    systemImage: "lock.shield",
                    isEnabled: !installer.isBusy && HelperInstaller.canInstallAnyhow
                ) {
                    installer.install()
                }
                FunFanButton(title: "设置…", systemImage: "gearshape") {
                    onOpenSettings()
                }
            }

            if let error = installer.error {
                Text(error)
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.hot)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    /// 规则模式摘要：一眼看出「现在有没有在替我调风扇」。
    private var rulesStatus: some View {
        HStack(spacing: 8) {
            if let rpm = control.automatedRpm {
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 6, height: 6)
                Text(String(format: "规则接管中 · %.0f RPM", rpm))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.accent)
            } else {
                Circle()
                    .fill(Color.secondary.opacity(0.5))
                    .frame(width: 6, height: 6)
                Text("规则监控中 · 未触发")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Button("编辑规则…") { onOpenRules() }
                .buttonStyle(.plain)
                .funfanFocusRing(cornerRadius: 5, outset: 3)
                .font(.system(size: 10))
                .foregroundStyle(Theme.accent)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(cardBackground)
    }

    /// 曲线模式摘要：曲线一定会给目标，所以只需说明「现在在按曲线跑」。
    private var curveStatus: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(control.automatedRpm != nil ? Theme.accent : Color.secondary.opacity(0.5))
                .frame(width: 6, height: 6)

            if let rpm = control.automatedRpm {
                Text(String(format: "曲线接管中 · %.0f RPM", rpm))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.accent)
            } else {
                Text("曲线待采样 · 首帧后接管")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Button("编辑曲线…") { onOpenCurve() }
                .buttonStyle(.plain)
                .funfanFocusRing(cornerRadius: 5, outset: 3)
                .font(.system(size: 10))
                .foregroundStyle(Theme.accent)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(cardBackground)
    }

    // MARK: - 底部

    private var footer: some View {
        HStack(spacing: 8) {
            Text(diagnostics.lastMessage ?? String(format: "采样 %.0f ms", monitor.sampleCostMs))
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Button("诊断") { diagnostics.copyReport() }
                .buttonStyle(.plain)
                .funfanFocusRing(cornerRadius: 5, outset: 2)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .help("复制完整诊断信息到剪贴板（机型/系统/SMC 能力逐项实测 + 排查建议）")
            Button("退出") { onQuit() }
                .buttonStyle(.plain)
                .funfanFocusRing(cornerRadius: 5, outset: 2)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.primary.opacity(0.05))
    }
}

// MARK: - 风扇环

struct FanRing: View {
    let actual: Double
    let limits: FanLimits?

    private var fraction: Double {
        guard let limits, limits.normalizedMax > limits.minRpm else { return 0 }
        let ratio = (actual - limits.minRpm) / (limits.normalizedMax - limits.minRpm)
        return min(max(ratio, 0), 1)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.10), lineWidth: 8)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(
                    Theme.accent,
                    style: StrokeStyle(lineWidth: 8, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.4), value: fraction)

            VStack(spacing: 1) {
                Text(actual > 0 ? String(format: "%.0f", actual) : "—")
                    .font(.system(size: 19, weight: .medium).monospacedDigit())
                Text("RPM")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 92, height: 92)
    }
}

// MARK: - 小扩展

extension FanState {
    /// UI 侧统一用归一化上界，避免机型返回 min>max 时显示错乱。
    var normalizedMaxForUI: Double { max(maxRpm, minRpm) }
}
