import SwiftUI
import FunFanCore

/// 规则窗口：总开关 + 规则列表 + 编辑器。
///
/// 设计原则：
/// - **总开关置顶**——用户必须能一眼看出「规则现在是否在接管风扇」；
/// - 每条规则一行，条件与动作并列，触发中的规则用主色高亮；
/// - 编辑用 sheet，避免列表与表单同屏拥挤。
struct RulesView: View {

    @ObservedObject var rules: RulesStore
    @ObservedObject var control: ControlStore

    @Environment(\.palette) private var palette
    @Environment(\.renderFlattensScroll) private var flattenScroll
    @State private var editing: FanRule?

    private var isRulesActive: Binding<Bool> {
        Binding(
            get: { control.strategy == .rules },
            set: { control.strategy = $0 ? .rules : .automatic }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(palette.divider)
            list
            Divider().overlay(palette.divider)
            footer
        }
        .frame(minWidth: 540, minHeight: 420)
        .background(palette.panelFill)
        // 内容顶部对齐：不写这行，规则很少时整块会被居中，窗口上方出现一大片空白
        // （看起来像「列表没加载出来」）。
        .frame(maxHeight: .infinity, alignment: .top)
        .sheet(item: $editing) { rule in
            RuleEditorView(
                rule: rule,
                limits: control.limits,
                onSave: { updated in
                    rules.update(updated)
                    editing = nil
                },
                onCancel: { editing = nil }
            )
        }
    }

    // MARK: - 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("自动调速规则")
                    .font(Theme.Typo.title)
                    .foregroundStyle(palette.textPrimary)
                Spacer()
                // 原来是 `.controlSize(.small)` 的原生按钮，与页面里其他自绘控件
                // 不是一套外观（也渲染不进离屏走查图）。
                FunFanButton(title: "添加规则", systemImage: "plus") {
                    rules.add()
                    if let last = rules.rules.last { editing = last }
                }
            }

            HStack(spacing: 12) {
                FunFanToggle(
                    isOn: isRulesActive,
                    label: "规则接管风扇",
                    isEnabled: control.helperStatus.isReady
                )

                if control.strategy == .rules {
                    if let rpm = control.automatedRpm {
                        Label(String(format: "接管中 %.0f RPM", rpm), systemImage: "bolt.fill")
                            .font(Theme.Typo.meta)
                            .foregroundStyle(palette.accentText)
                    } else {
                        Label("监控中，未触发", systemImage: "eye")
                            .font(Theme.Typo.meta)
                            .foregroundStyle(palette.textSecondary)
                    }
                }

                Spacer()

                if !control.helperStatus.isReady {
                    Text("需先安装特权 helper")
                        .font(Theme.Typo.meta)
                        .foregroundStyle(palette.attention)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    // MARK: - 列表

    /// 规则列表。
    ///
    /// 走查时（`--flat`）换成普通 VStack：`ImageRenderer` 不渲染 ScrollView 的内容，
    /// 否则拍出来永远是空白，行高、对齐、按钮命中区全都验不了。
    @ViewBuilder
    private var list: some View {
        if flattenScroll {
            listContent
        } else {
            ScrollView { listContent }
        }
    }

    private var listContent: some View {
        Group {
            if rules.rules.isEmpty {
                emptyState
            } else {
                // 用 VStack 而非 LazyVStack：规则数量级很小（通常 < 20 条），
                // 且惰性容器在离屏渲染（设计走查）时不会填充内容。
                VStack(spacing: 8) {
                    ForEach(rules.rules) { rule in
                        row(rule)
                    }
                }
                .padding(16)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 26))
                .foregroundStyle(palette.textTertiary)
            Text("还没有规则")
                .font(Theme.Typo.bodyStrong)
                .foregroundStyle(palette.textPrimary)
            Text("例如「CPU 最热 ≥ 75℃ → 60% 转速」")
                .font(Theme.Typo.meta)
                .foregroundStyle(palette.textSecondary)
            FunFanButton(title: "恢复示例规则", systemImage: "arrow.counterclockwise") {
                rules.restoreSamples()
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    private func row(_ rule: FanRule) -> some View {
        let triggered = control.strategy == .rules && control.triggeredRuleIDs.contains(rule.id)

        return HStack(spacing: 12) {
            FunFanToggle(
                isOn: Binding(
                    get: { rule.enabled },
                    set: { rules.setEnabled($0, id: rule.id) }
                ),
                size: 22
            )
            .frame(width: 26, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(rule.name)
                        .font(Theme.Typo.bodyStrong)
                        .foregroundStyle(rule.enabled ? palette.textPrimary : palette.textSecondary)
                    if triggered {
                        Text("触发中")
                            .font(Theme.Typo.metaStrong)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(palette.accentWash, in: Capsule())
                            .foregroundStyle(palette.accentText)
                    }
                }
                HStack(spacing: 6) {
                    Text(rule.conditionText)
                        .font(Theme.Typo.metaValue)
                        .foregroundStyle(palette.textSecondary)
                    // 这里原来还画了一个 `arrow.right` 图标，而 `actionText` 本身
                    // 就以「→」开头，渲染出来是「→ → 60%」。去掉图标。
                    Text(rule.actionText(limits: control.limits))
                        .font(Theme.Typo.metaValue)
                        .foregroundStyle(palette.textSecondary)
                    Text("迟滞 \(String(format: "%.0f", rule.hysteresisCelsius))°")
                        .font(Theme.Typo.meta)
                        .foregroundStyle(palette.textTertiary)
                }
            }

            Spacer(minLength: 0)

            IconButton(systemImage: "slider.horizontal.3", help: "编辑") {
                editing = rule
            }

            IconButton(systemImage: "trash", help: "删除", isDestructive: true) {
                rules.remove(id: rule.id)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        // 关闭的规则原来整行 `opacity(0.62)`：文字一起被压灰，条件那一行掉到
        // 3:1 以下。现在改为「底换成内凹色 + 标题降级」，正文保持原对比度——
        // 一眼能看出这条没启用，同时仍然读得清它写了什么。
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(rule.enabled ? palette.cardFill : palette.insetFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(triggered ? palette.accentFill.opacity(0.5) : palette.cardStroke, lineWidth: 1)
        )
    }

    // MARK: - 底部

    private var footer: some View {
        HStack(spacing: 10) {
            // 原来写的是 `**最大**` 想靠 markdown 加粗，但 11pt 下几乎看不出，
            // 星号还会在某些渲染路径里漏出来。改成直接说清楚。
            Text("多条规则同时触发时取转速最高的那条；任何规则都会被安全下限抬升，不会低于系统最小值。")
                .font(Theme.Typo.meta)
                .foregroundStyle(palette.textTertiary)
            Spacer()
            if control.strategy == .rules, let message = control.message {
                Text(message)
                    .font(Theme.Typo.meta)
                    .foregroundStyle(palette.textSecondary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }
}

// MARK: - 编辑器

struct RuleEditorView: View {

    @State private var draft: FanRule
    let limits: FanLimits
    var onSave: (FanRule) -> Void
    var onCancel: () -> Void

    @Environment(\.palette) private var palette

    init(rule: FanRule, limits: FanLimits, onSave: @escaping (FanRule) -> Void, onCancel: @escaping () -> Void) {
        _draft = State(initialValue: rule)
        self.limits = limits
        self.onSave = onSave
        self.onCancel = onCancel
    }

    private var category: Binding<SensorCategory> {
        Binding(
            get: {
                if case .category(let category) = draft.subject { return category }
                return .cpu
            },
            set: { draft.subject = .category($0) }
        )
    }

    private var metric: Binding<Metric> {
        Binding(get: { draft.metric }, set: { draft.metric = $0 })
    }

    private var actionKind: Binding<RuleActionKind> {
        Binding(
            get: {
                switch draft.action {
                case .setPercent: return .percent
                case .setRpm: return .rpm
                }
            },
            set: { kind in
                switch kind {
                case .percent:
                    draft.action = .setPercent(60)
                case .rpm:
                    draft.action = .setRpm((limits.minRpm + limits.normalizedMax) / 2)
                }
            }
        )
    }

    private var actionPercent: Binding<Double> {
        Binding(
            get: {
                if case .setPercent(let value) = draft.action { return value }
                return 60
            },
            set: { draft.action = .setPercent($0) }
        )
    }

    private var actionRpm: Binding<Double> {
        Binding(
            get: {
                if case .setRpm(let value) = draft.action { return value }
                return (limits.minRpm + limits.normalizedMax) / 2
            },
            set: { draft.action = .setRpm($0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("编辑规则")
                .font(Theme.Typo.title)
                .foregroundStyle(palette.textPrimary)

            TextField("规则名称", text: $draft.name)
                .textFieldStyle(.roundedBorder)

            VStack(alignment: .leading, spacing: 6) {
                Text("触发条件")
                    .font(Theme.Typo.metaStrong)
                    .foregroundStyle(palette.textSecondary)

                HStack(spacing: 8) {
                    Picker("", selection: category) {
                        ForEach(SensorCategory.allCases, id: \.self) { category in
                            Text(category.displayName).tag(category)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 92)

                    Picker("", selection: metric) {
                        Text("最热").tag(Metric.peak)
                        Text("均温").tag(Metric.average)
                    }
                    .labelsHidden()
                    .frame(width: 84)

                    Picker("", selection: $draft.comparator) {
                        Text("≥").tag(RuleComparator.greaterThanOrEqual)
                        Text(">").tag(RuleComparator.greaterThan)
                        Text("≤").tag(RuleComparator.lessThanOrEqual)
                        Text("<").tag(RuleComparator.lessThan)
                    }
                    .labelsHidden()
                    .frame(width: 64)

                    TextField("", value: $draft.thresholdCelsius, format: .number.precision(.fractionLength(0)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 58)
                    Text("°C")
                        .font(Theme.Typo.meta)
                        .foregroundStyle(palette.textSecondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("动作")
                    .font(Theme.Typo.metaStrong)
                    .foregroundStyle(palette.textSecondary)

                HStack(spacing: 8) {
                    Picker("", selection: actionKind) {
                        ForEach(RuleActionKind.allCases) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 168)

                    if actionKind.wrappedValue == .percent {
                        Slider(value: actionPercent, in: 10...100, step: 5)
                        Text(String(format: "%.0f%%", actionPercent.wrappedValue))
                            .font(Theme.Typo.metaValueStrong)
                            .foregroundStyle(palette.textPrimary)
                            .frame(width: 40, alignment: .trailing)
                    } else {
                        Slider(value: actionRpm, in: limits.minRpm...limits.normalizedMax, step: 50)
                        Text(String(format: "%.0f", actionRpm.wrappedValue))
                            .font(Theme.Typo.metaValueStrong)
                            .foregroundStyle(palette.textPrimary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }

            HStack(spacing: 8) {
                Text("迟滞")
                    .font(Theme.Typo.metaStrong)
                    .foregroundStyle(palette.textSecondary)
                Stepper(
                    value: $draft.hysteresisCelsius,
                    in: 0...20,
                    step: 1
                ) {
                    Text(String(format: "%.0f °C", draft.hysteresisCelsius))
                        .font(Theme.Typo.metaValue)
                        .foregroundStyle(palette.textPrimary)
                }
                Spacer()
                Text("回落到 \(String(format: "%.0f", draft.thresholdCelsius - draft.hysteresisCelsius))°C 才解除")
                    .font(Theme.Typo.meta)
                    .foregroundStyle(palette.textTertiary)
            }

            previewCard

            HStack {
                Button("取消") { onCancel() }
                Spacer()
                Button("保存") { onSave(draft) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 460)
    }

    private var previewCard: some View {
        let triggered = draft
        let rpmText = triggered.actionText(limits: limits)
        return VStack(alignment: .leading, spacing: 4) {
            Text("预览")
                .font(Theme.Typo.meta)
                .foregroundStyle(palette.textTertiary)
            Text("当 \(triggered.conditionText) 时 \(rpmText)")
                .font(Theme.Typo.body)
                .foregroundStyle(palette.textPrimary)
            Text("实际转速仍会被安全下限抬升，绝不会低于系统最小 \(String(format: "%.0f", limits.minRpm)) RPM。")
                .font(Theme.Typo.meta)
                .foregroundStyle(palette.textSecondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(palette.insetFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(palette.cardStroke, lineWidth: 0.5)
        )
    }
}
