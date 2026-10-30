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
            Divider().opacity(0.4)
            list
            Divider().opacity(0.4)
            footer
        }
        .frame(minWidth: 540, minHeight: 420)
        .background(Color(nsColor: .windowBackgroundColor))
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
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button {
                    rules.add()
                    if let last = rules.rules.last { editing = last }
                } label: {
                    Label("添加规则", systemImage: "plus")
                }
                .controlSize(.small)
            }

            HStack(spacing: 12) {
                FunFanToggle(isOn: isRulesActive, label: "规则接管风扇")
                    .allowsHitTesting(control.helperStatus.isReady)
                    .opacity(control.helperStatus.isReady ? 1 : 0.5)

                if control.strategy == .rules {
                    if let rpm = control.automatedRpm {
                        Label(String(format: "接管中 %.0f RPM", rpm), systemImage: "bolt.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.accent)
                    } else {
                        Label("监控中，未触发", systemImage: "eye")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if !control.helperStatus.isReady {
                    Text("需先安装特权 helper")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.warm)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    // MARK: - 列表

    private var list: some View {
        ScrollView {
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
                .foregroundStyle(.tertiary)
            Text("还没有规则")
                .font(.system(size: 12, weight: .medium))
            Text("例如「CPU 最热 ≥ 75℃ → 60% 转速」")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Button("恢复示例规则") { rules.restoreSamples() }
                .controlSize(.small)
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
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(rule.enabled ? .primary : .secondary)
                    if triggered {
                        Text("触发中")
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Theme.accent.opacity(0.18), in: Capsule())
                            .foregroundStyle(Theme.accent)
                    }
                }
                HStack(spacing: 6) {
                    Text(rule.conditionText)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                    Text(rule.actionText(limits: control.limits))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text("迟滞 \(String(format: "%.0f", rule.hysteresisCelsius))°")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 0)

            Button {
                editing = rule
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(.borderless)
            .help("编辑")

            Button {
                rules.remove(id: rule.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("删除")
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(triggered ? 0.09 : 0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(triggered ? Theme.accent.opacity(0.5) : .clear, lineWidth: 1)
        )
        .opacity(rule.enabled ? 1 : 0.62)
    }

    // MARK: - 底部

    private var footer: some View {
        HStack(spacing: 10) {
            Text("多条规则同时触发时取**最大**转速；任何规则都会被安全下限抬升，不会低于系统最小值。")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer()
            if control.strategy == .rules, let message = control.message {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
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
                .font(.system(size: 14, weight: .semibold))

            TextField("规则名称", text: $draft.name)
                .textFieldStyle(.roundedBorder)

            VStack(alignment: .leading, spacing: 6) {
                Text("触发条件")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

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
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("动作")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

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
                            .font(.system(size: 11).monospacedDigit())
                            .frame(width: 40, alignment: .trailing)
                    } else {
                        Slider(value: actionRpm, in: limits.minRpm...limits.normalizedMax, step: 50)
                        Text(String(format: "%.0f", actionRpm.wrappedValue))
                            .font(.system(size: 11).monospacedDigit())
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }

            HStack(spacing: 8) {
                Text("迟滞")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Stepper(
                    value: $draft.hysteresisCelsius,
                    in: 0...20,
                    step: 1
                ) {
                    Text(String(format: "%.0f °C", draft.hysteresisCelsius))
                        .font(.system(size: 11).monospacedDigit())
                }
                Spacer()
                Text("回落到 \(String(format: "%.0f", draft.thresholdCelsius - draft.hysteresisCelsius))°C 才解除")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
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
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Text("当 \(triggered.conditionText) 时 \(rpmText)")
                .font(.system(size: 11))
            Text("实际转速仍会被安全下限抬升，绝不会低于系统最小 \(String(format: "%.0f", limits.minRpm)) RPM。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }
}
