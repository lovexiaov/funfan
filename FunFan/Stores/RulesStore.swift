import Foundation
import Combine
import FunFanCore

/// 规则的 UI 侧数据源：增删改 + 立即持久化 + 供控制层线程安全读取。
///
/// 首次启动（文件不存在）会写入两条保守模板规则，让「规则」页不是空白，
/// 但**默认不启用规则策略**——是否接管风扇始终由用户显式选择。
final class RulesStore: ObservableObject {

    @Published private(set) var rules: [FanRule] = []

    private let persistence: RulePersistence
    private let lock = NSLock()
    private var cache: [FanRule] = []

    init(persistence: RulePersistence = RulePersistence(fileURL: RulePersistence.defaultFileURL())) {
        self.persistence = persistence
        reload()
    }

    // MARK: - 读取

    private func reload() {
        let existing = persistence.load()
        if existing.isEmpty {
            rules = RulePersistence.sampleRules
            try? persistence.save(rules)
        } else {
            rules = existing
        }
        updateCache()
    }

    /// 控制层（后台队列）读取用，避免跨线程读 `@Published`。
    func currentRules() -> [FanRule] {
        lock.lock()
        defer { lock.unlock() }
        return cache
    }

    func rule(id: UUID) -> FanRule? {
        rules.first { $0.id == id }
    }

    // MARK: - 修改

    func add() {
        var draft = FanRule(
            name: "新规则",
            subject: .category(.cpu),
            metric: .peak,
            comparator: .greaterThanOrEqual,
            thresholdCelsius: 75,
            action: .setPercent(60),
            hysteresisCelsius: 3
        )
        draft.enabled = false   // 新规则默认不启用，避免误接管
        rules.append(draft)
        persist()
    }

    func update(_ rule: FanRule) {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[index] = rule
        persist()
    }

    func remove(id: UUID) {
        rules.removeAll { $0.id == id }
        persist()
    }

    func setEnabled(_ enabled: Bool, id: UUID) {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[index].enabled = enabled
        persist()
    }

    func restoreSamples() {
        rules = RulePersistence.sampleRules
        persist()
    }

    // MARK: - 持久化

    private func persist() {
        // 写盘前先清洗（阈值/迟滞/百分比夹到安全区间）
        let cleaned = persistence.sanitize(rules)
        if cleaned != rules {
            rules = cleaned
        }
        updateCache()
        do {
            try persistence.save(cleaned)
        } catch {
            // 写盘失败不该让 UI 崩溃；内存态仍然生效，下次修改会重试
            NSLog("FunFan: 规则保存失败 \(error)")
        }
    }

    private func updateCache() {
        let value = rules
        lock.lock()
        cache = value
        lock.unlock()
    }
}

// MARK: - 展示文案

extension FanRule {

    /// 条件摘要，如「CPU 最热 ≥ 75°C」。
    var conditionText: String {
        let subjectText: String
        switch subject {
        case .key(let key):
            subjectText = key
        case .category(let category):
            switch (category, metric) {
            case (.cpu, .peak): subjectText = "CPU 最热"
            case (.gpu, .peak): subjectText = "GPU 最热"
            case (_, .peak): subjectText = "\(category.displayName) 最热"
            default: subjectText = "\(category.displayName) 均温"
            }
        }

        let symbol: String
        switch comparator {
        case .greaterThanOrEqual: symbol = "≥"
        case .greaterThan: symbol = ">"
        case .lessThanOrEqual: symbol = "≤"
        case .lessThan: symbol = "<"
        }

        return String(format: "%@ %@ %.0f°C", subjectText, symbol, thresholdCelsius)
    }

    /// 动作摘要，如「→ 60%（2940 RPM）」。
    func actionText(limits: FanLimits) -> String {
        switch action {
        case .setPercent(let percent):
            let rpm = limits.normalizedMax * percent / 100
            return String(format: "→ %.0f%%（%.0f RPM）", percent, rpm)
        case .setRpm(let rpm):
            return String(format: "→ %.0f RPM", rpm)
        }
    }

    var actionKind: RuleActionKind {
        switch action {
        case .setPercent: return .percent
        case .setRpm: return .rpm
        }
    }
}

enum RuleActionKind: String, CaseIterable, Identifiable {
    case percent
    case rpm

    var id: String { rawValue }
    var label: String { self == .percent ? "按最大转速百分比" : "指定 RPM" }
}

extension SensorCategory {
    var displayName: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .ssd: return "SSD"
        case .memory: return "内存"
        case .battery: return "电池"
        case .ambient: return "环境"
        case .other: return "其他"
        }
    }
}
