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

    @Environment(\.palette) private var palette
    @Environment(\.renderFlattensScroll) private var flattenScroll

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
                .foregroundStyle(palette.accentFill)
            Text("FunFan")
                .font(Theme.Typo.title)
                .foregroundStyle(palette.textPrimary)
            Spacer()
            if let date = monitor.lastSample {
                Text(date, style: .relative)
                    .font(Theme.Typo.meta)
                    .foregroundStyle(palette.textTertiary)
            }
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            // 只有图标，环要比字形让出去更多才不至于像个紧箍
            .funfanFocusRing(cornerRadius: 5, outset: 4)
            .foregroundStyle(palette.textSecondary)
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
                    .font(.system(size: 11))
                    .foregroundStyle(palette.attention)
                Text(control.conflictSource.map { "\($0) 正在控制风扇" } ?? "其他程序正在控制风扇")
                    .font(Theme.Typo.metaStrong)
                    .foregroundStyle(palette.textPrimary)
                Spacer(minLength: 0)
            }

            Text(control.conflict.map(\.summary).joined(separator: "；")
                 + "。FunFan 已暂停接管，避免两个程序互相覆盖转速。退出对方软件后点「重新检测」。")
                .font(Theme.Typo.meta)
                .foregroundStyle(palette.textSecondary)
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
                .fill(palette.attentionWash)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(palette.attention.opacity(0.28), lineWidth: 0.5)
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
                        .font(Theme.Typo.meta)
                        .foregroundStyle(palette.textSecondary)
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
                .font(Theme.Typo.meta)
                .foregroundStyle(palette.textSecondary)
                .frame(width: 32, alignment: .leading)
            Text(value)
                .font(Theme.Typo.smallValue)
                .foregroundStyle(palette.textPrimary)
        }
    }

    // MARK: - 温度

    private var temperatureSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("硬件温度")
                    .font(Theme.Typo.metaStrong)
                    .foregroundStyle(palette.textSecondary)
                Spacer()
                Text("\(monitor.sensorCount) 个传感器")
                    .font(Theme.Typo.meta)
                    .foregroundStyle(palette.textTertiary)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                tempChip("CPU 均温", monitor.cpuAverage)
                tempChip("GPU 均温", monitor.gpuAverage)
                tempChip("SSD", monitor.ssdAverage)
                tempChip("环境", monitor.ambientAverage,
                         unsupported: monitor.ambientAvailability == .unsupported)
            }

            /// 芯片真实拓扑卡：核心数来自系统接口（sysctl / IORegistry），是权威值，
            /// 直接回答「为什么展开的核数和实际情况对不上」——这里永远是真值。
            if let topo = monitor.chipTopology {
                chipTopologyCard(topo)
            }

            if !monitor.coreGroups.isEmpty {
                coreDisclosure
                if showCores {
                    expandedThermalDetail
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
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(showCores ? 90 : 0))
                Text(showCores ? "收起各核心温度" : "展开各核心温度")
                    .font(Theme.Typo.meta)
                Spacer(minLength: 0)
            }
            .foregroundStyle(palette.accentText)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .funfanFocusRing(cornerRadius: 6, outset: 2)
        .accessibilityLabel(showCores ? "收起核心温度" : "展开核心温度")
        .help(showCores ? "收起核心布局与温度探测点" : "展开核心布局与各簇温度探测点")
    }

    /// 温度格。
    ///
    /// 数值一律 `textPrimary`：原来四格全绿时，颜色既没有区分度又把主数据降级了。
    /// 状态交给左侧指示物（形态 + 颜色双通道）。
    ///
    /// `unsupported` 专门给「这台机器压根没有该类传感器」用（本机 Mac mini M4
    /// 的 `TA*` 环境键就是这种情况）。以前那种一律显示 `—` 的做法会让人以为
    /// 是读失败、等下就好，实际上永远不会有值。
    private func tempChip(
        _ label: String,
        _ value: Double?,
        unsupported: Bool = false
    ) -> some View {
        HStack(spacing: 7) {
            TemperatureIndicator(level: .init(value), color: palette.temperature(value))
            Text(label)
                .font(Theme.Typo.meta)
                .foregroundStyle(palette.textSecondary)
            Spacer(minLength: 0)
            if let value {
                Text(String(format: "%.0f°", value))
                    .font(Theme.Typo.smallValue)
                    .foregroundStyle(palette.textPrimary)
            } else if unsupported {
                Text("无传感器")
                    .font(Theme.Typo.meta)
                    .foregroundStyle(palette.textTertiary)
            } else {
                Text("—")
                    .font(Theme.Typo.smallValue)
                    .foregroundStyle(palette.textTertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(cardBackground)
        .help(if: unsupported, "这台机器没有暴露\(label)温度传感器（SMC 里没有对应键），不是读取失败")
    }

    /// 展开后的全部温度细节：**限高滚动**，避免 75 个探测点把 popover 撑成
    /// 几十行高。上面是「真实核心布局矩阵」（一一对应到每个物理核），下面是各簇
    /// 探测点的紧凑网格（两列）。
    @ViewBuilder
    private var expandedThermalDetail: some View {
        if flattenScroll {
            // 仅走查用（`--render ... --flat`）：ScrollView 的内容离屏渲染不出来，
            // 摊平后才能检查排版是否真的放得下。
            thermalDetailContent
        } else {
            ScrollView(.vertical, showsIndicators: true) {
                thermalDetailContent
            }
            .frame(maxHeight: 280)
        }
    }

    private var thermalDetailContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let topo = monitor.chipTopology {
                coreMatrixCard(topo)
            }
            ForEach(monitor.coreGroups) { group in
                probeClusterBlock(group)
            }
        }
        .padding(.top, 2)
    }

    /// 真实核心布局：方块数 = 系统接口读到的 P/E/GPU 核数，**一一对应每个物理核**
    /// （P0…P3 / E0…E5 / G0…G9）。SMC 不提供逐核温度，方块按所在簇的均温着色
    /// （簇均温由该簇全部探测点算出），并在底部注明，避免再次被误读成逐核读数。
    private func coreMatrixCard(_ topo: ChipTopology) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("核心布局（真实核数）")
                .font(Theme.Typo.meta)
                .foregroundStyle(palette.textTertiary)

            coreRow("性能核", count: topo.performanceCores, prefix: "P",
                    average: monitor.coreGroups.first(where: { $0.id == "cpu-performance" })?.average)
            if topo.efficiencyCores > 0 {
                coreRow("能效核", count: topo.efficiencyCores, prefix: "E",
                        average: monitor.coreGroups.first(where: { $0.id == "cpu-efficiency" })?.average)
            }
            if topo.gpuCores > 0 {
                coreRow("GPU 核", count: topo.gpuCores, prefix: "G",
                        average: monitor.coreGroups.first(where: { $0.id == "gpu" })?.average)
            }

            Text("SMC 无逐核读数，方块按所在簇均温着色")
                .font(Theme.Typo.meta)
                .foregroundStyle(palette.textTertiary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    private func coreRow(_ label: String, count: Int, prefix: String, average: Double?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                TemperatureIndicator(level: .init(average), color: palette.temperature(average), size: 6)
                Text(label)
                    .font(Theme.Typo.meta)
                    .foregroundStyle(palette.textSecondary)
                if let average {
                    Text(String(format: "%.1f°", average))
                        .font(Theme.Typo.metaValue)
                        .foregroundStyle(palette.textPrimary)
                }
                Spacer(minLength: 0)
            }
            // 10 列等宽：三行方块同宽、永不因滚动条占位而换行（曾用 adaptive 时
            // GPU 行的第 10 个方块被挤到下一行）。
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 10), spacing: 4) {
                ForEach(0..<count, id: \.self) { i in
                    coreTile("\(prefix)\(i)", color: palette.temperature(average))
                }
            }
        }
    }

    private func coreTile(_ title: String, color: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(color.opacity(0.18))
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(color.opacity(0.45), lineWidth: 0.5)
                )
            Text(title)
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(color)
        }
        .frame(height: 20)
    }

    /// 单个簇的探测点：紧凑两列网格（替代原来逐条整行），从视觉上收拢「散」的感觉。
    /// 仍明确标注探测点数量 ≠ 核数，避免再次被误读成逐核。
    private func probeClusterBlock(_ group: CoreGroup) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                TemperatureIndicator(level: .init(group.average), color: palette.temperature(group.average), size: 6)
                Text(group.title)
                    .font(Theme.Typo.metaStrong)
                    .foregroundStyle(palette.textPrimary)
                Spacer()
                Text(String(format: "%.1f°", group.average))
                    .font(Theme.Typo.metaValue)
                    .foregroundStyle(palette.textPrimary)
            }
            Text("\(group.sensorCount) 个探测点（非逐核）")
                .font(Theme.Typo.meta)
                .foregroundStyle(palette.textTertiary)
            if group.sensors.isEmpty {
                Text("（无传感器）")
                    .font(Theme.Typo.meta)
                    .foregroundStyle(palette.textTertiary)
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 4) {
                    ForEach(Array(group.sensors.enumerated()), id: \.offset) { _, sensor in
                        probeChip(sensor.key, sensor.celsius)
                    }
                }
            }
        }
        .padding(.leading, 4)
    }

    /// 单个探测点。
    ///
    /// 指示点负责颜色（5pt 的小色块已经不承担可读性），数值改成 `textPrimary`——
    /// 75 个点如果全部着温度色，展开区会变成一片绿/琥珀的「彩色文本墙」，
    /// 反而看不出哪个点真的偏高。
    private func probeChip(_ key: String, _ value: Double) -> some View {
        HStack(spacing: 5) {
            // 用带形态的指示物（点 / 环 / 三角）而不是纯色点：浅色下 warm 是深棕、
            // cool 是深绿，色相都偏深，单靠颜色在 75 个点的网格里几乎分不出来。
            TemperatureIndicator(level: .init(value), color: palette.temperature(value), size: 6)
            Text(key)
                .font(Theme.Typo.metaValue)
                .foregroundStyle(palette.textSecondary)
            Spacer(minLength: 0)
            Text(String(format: "%.1f°", value))
                .font(Theme.Typo.metaValue)
                .foregroundStyle(palette.textPrimary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(cardBackground)
    }

    /// 芯片真实拓扑卡：核心数来自系统接口（sysctl / IORegistry），是权威值。
    /// 下面温度区只列 SMC 探测点，数量不等于这里的核数——两处一起看才不矛盾。
    private func chipTopologyCard(_ topo: ChipTopology) -> some View {
        HStack(alignment: .center, spacing: 6) {
            Text(topo.chipName)
                .font(Theme.Typo.metaStrong)
                .foregroundStyle(palette.textPrimary)
            Spacer()
            Text("\(topo.performanceCores)P + \(topo.efficiencyCores)E · \(topo.gpuCores) 核 GPU")
                .font(Theme.Typo.meta)
                .foregroundStyle(palette.textSecondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(cardBackground)
    }

    // MARK: - 电量

    private var batterySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("电池")
                    .font(Theme.Typo.metaStrong)
                    .foregroundStyle(palette.textSecondary)
                Spacer()
                // 「充电中」不再借用温度轴的绿色：状态由图标（bolt）承担，
                // 颜色留给真正的温度指标，界面轴才不会和温度轴混在一起。
                if monitor.battery.isCharging {
                    Label("充电中", systemImage: "bolt.fill")
                        .font(Theme.Typo.meta)
                        .foregroundStyle(palette.textSecondary)
                } else if monitor.battery.externalConnected {
                    Text("外接电源")
                        .font(Theme.Typo.meta)
                        .foregroundStyle(palette.textSecondary)
                }
            }

            HStack(spacing: 14) {
                if let pct = monitor.battery.percentage {
                    Text(String(format: "%.0f%%", pct))
                        .font(Theme.Typo.value)
                        .foregroundStyle(palette.textPrimary)
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
                .font(Theme.Typo.meta)
                .foregroundStyle(palette.textTertiary)
            Text(value)
                .font(Theme.Typo.metaValueStrong)
                .foregroundStyle(palette.textPrimary)
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
                        .font(Theme.Typo.smallValue)
                        .foregroundStyle(palette.textPrimary)
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
                    .font(Theme.Typo.meta)
                    .foregroundStyle(control.helperStatus.isReady ? palette.textSecondary : palette.attention)
                    .fixedSize(horizontal: false, vertical: true)
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
                    .font(.system(size: 11))
                    .foregroundStyle(palette.attention)
                // 这是**阻断性**说明（没装组件就完全控制不了风扇），
                // 原来用 11pt 比正文 12pt 还小，属于「越重要越小」。
                Text("只能监控，还不能控制风扇")
                    .font(Theme.Typo.bodyStrong)
                    .foregroundStyle(palette.textPrimary)
                Spacer(minLength: 0)
            }

            Text(installer.note
                 ?? "控制风扇需要安装一个后台组件（只装一次）。它只做一件事：代表 FunFan 写转速，FunFan 退出就立刻交还系统。")
                .font(Theme.Typo.meta)
                .foregroundStyle(palette.textSecondary)
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
                    .font(Theme.Typo.meta)
                    .foregroundStyle(palette.error)
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
                    .fill(palette.accentFill)
                    .frame(width: 6, height: 6)
                Text(String(format: "规则接管中 · %.0f RPM", rpm))
                    .font(Theme.Typo.bodyStrong)
                    .foregroundStyle(palette.accentText)
            } else {
                Circle()
                    .strokeBorder(palette.textTertiary, lineWidth: 1)
                    .frame(width: 6, height: 6)
                Text("规则监控中 · 未触发")
                    .font(Theme.Typo.body)
                    .foregroundStyle(palette.textSecondary)
            }

            Spacer(minLength: 0)

            Button("编辑规则…") { onOpenRules() }
                .buttonStyle(.plain)
                .funfanFocusRing(cornerRadius: 5, outset: 3)
                .font(Theme.Typo.meta)
                .foregroundStyle(palette.accentText)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(cardBackground)
    }

    /// 曲线模式摘要：曲线一定会给目标，所以只需说明「现在在按曲线跑」。
    private var curveStatus: some View {
        HStack(spacing: 8) {
            if control.automatedRpm != nil {
                Circle()
                    .fill(palette.accentFill)
                    .frame(width: 6, height: 6)
            } else {
                Circle()
                    .strokeBorder(palette.textTertiary, lineWidth: 1)
                    .frame(width: 6, height: 6)
            }

            if let rpm = control.automatedRpm {
                Text(String(format: "曲线接管中 · %.0f RPM", rpm))
                    .font(Theme.Typo.bodyStrong)
                    .foregroundStyle(palette.accentText)
            } else {
                Text("曲线待采样 · 首帧后接管")
                    .font(Theme.Typo.body)
                    .foregroundStyle(palette.textSecondary)
            }

            Spacer(minLength: 0)

            Button("编辑曲线…") { onOpenCurve() }
                .buttonStyle(.plain)
                .funfanFocusRing(cornerRadius: 5, outset: 3)
                .font(Theme.Typo.meta)
                .foregroundStyle(palette.accentText)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(cardBackground)
    }

    // MARK: - 底部

    private var footer: some View {
        HStack(spacing: 8) {
            Text(diagnostics.lastMessage ?? String(format: "采样 %.0f ms", monitor.sampleCostMs))
                .font(Theme.Typo.meta)
                .foregroundStyle(palette.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Button("诊断") { diagnostics.copyReport() }
                .buttonStyle(.plain)
                .funfanFocusRing(cornerRadius: 5, outset: 2)
                .font(Theme.Typo.meta)
                .foregroundStyle(palette.textSecondary)
                .help("复制完整诊断信息到剪贴板（机型/系统/SMC 能力逐项实测 + 排查建议）")
            Button("退出") { onQuit() }
                .buttonStyle(.plain)
                .funfanFocusRing(cornerRadius: 5, outset: 2)
                .font(Theme.Typo.meta)
                .foregroundStyle(palette.textSecondary)
        }
    }

    /// 卡片：浅色下白底 + 描边，边界由描边承担。
    ///
    /// 原来只有 `primary.opacity(0.05)` 一层填充，浅色时卡片与背景只差 1.10:1，
    /// 看起来像「脏了的底色」而不是一张卡。
    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(palette.cardFill)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(palette.cardStroke, lineWidth: 0.5)
            )
    }
}

// MARK: - 风扇环

struct FanRing: View {
    let actual: Double
    let limits: FanLimits?

    @Environment(\.palette) private var palette

    private var fraction: Double {
        guard let limits, limits.normalizedMax > limits.minRpm else { return 0 }
        let ratio = (actual - limits.minRpm) / (limits.normalizedMax - limits.minRpm)
        return min(max(ratio, 0), 1)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(palette.track, lineWidth: 8)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(
                    palette.accentFill,
                    style: StrokeStyle(lineWidth: 8, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.4), value: fraction)

            VStack(spacing: 1) {
                Text(actual > 0 ? String(format: "%.0f", actual) : "—")
                    .font(Theme.Typo.value)
                    .foregroundStyle(palette.textPrimary)
                Text("RPM")
                    .font(Theme.Typo.meta)
                    .foregroundStyle(palette.textSecondary)
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
