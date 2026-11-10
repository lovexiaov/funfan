import Foundation

/// 规则作用对象（从哪个传感器取值）。
public enum SensorSubject: Codable, Equatable, Sendable {
    /// 单个 SMC 键，如 `"Tp01"`。
    case key(String)
    /// 整个语义类别，如 `.cpu`。
    case category(SensorCategory)
}

/// 取值方式。时间维度平滑由 `SensorMonitor` 的滑动均值负责，这里只做**空间**聚合。
public enum Metric: String, Codable, CaseIterable, Sendable {
    /// 单值（类别则取均温）。
    case instant
    /// 类别内的均温（与 `instant` 对类别等价，保留语义以便 UI 区分）。
    case average
    /// 类别内最热的那个传感器。
    case peak
}

/// 比较方式。
public enum RuleComparator: String, Codable, CaseIterable, Sendable {
    case greaterThanOrEqual
    case greaterThan
    case lessThanOrEqual
    case lessThan

    /// 是否为「高温方向」比较（决定迟滞死区加在阈值哪一侧）。
    public var isRising: Bool {
        switch self {
        case .greaterThanOrEqual, .greaterThan: return true
        case .lessThanOrEqual, .lessThan: return false
        }
    }
}

/// 触发后的动作。
public enum RuleAction: Codable, Equatable, Sendable {
    /// 直接指定 RPM。
    case setRpm(Double)
    /// 按 `F0Mx` 的百分比指定（0–100）。
    case setPercent(Double)
}

/// 一条自动调速规则（Codable，可持久化为 JSON）。
public struct FanRule: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var enabled: Bool
    public var subject: SensorSubject
    public var metric: Metric
    public var comparator: RuleComparator
    public var thresholdCelsius: Double
    public var action: RuleAction
    /// 迟滞死区（℃）：进入需越过阈值，退出需回落 `阈值 − 迟滞`（高温方向）。
    public var hysteresisCelsius: Double

    public init(
        id: UUID = UUID(),
        name: String,
        enabled: Bool = true,
        subject: SensorSubject,
        metric: Metric = .instant,
        comparator: RuleComparator,
        thresholdCelsius: Double,
        action: RuleAction,
        hysteresisCelsius: Double = 2
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.subject = subject
        self.metric = metric
        self.comparator = comparator
        self.thresholdCelsius = thresholdCelsius
        self.action = action
        self.hysteresisCelsius = hysteresisCelsius
    }

    /// 解析本规则的目标转速（未 clamp）。
    public func resolvedRpm(limits: FanLimits) -> Double {
        switch action {
        case .setRpm(let rpm):
            return rpm
        case .setPercent(let percent):
            return limits.normalizedMax * (percent / 100.0)
        }
    }

    /// 计算本规则在当前快照下的取值；传感器缺失返回 nil。
    public func value(in snapshot: SensorSnapshot) -> Double? {
        switch subject {
        case .key(let key):
            return snapshot.readings.first { $0.descriptor.key == key }?.celsius

        case .category(let category):
            let items = snapshot.readings(in: category)
            guard !items.isEmpty else { return nil }
            switch metric {
            case .peak:
                return items.map(\.celsius).max()
            case .instant, .average:
                return items.map(\.celsius).reduce(0, +) / Double(items.count)
            }
        }
    }

    /// 阈值比较（不含迟滞，用于「进入」判定）。
    public func passes(value: Double) -> Bool {
        switch comparator {
        case .greaterThanOrEqual: return value >= thresholdCelsius
        case .greaterThan: return value > thresholdCelsius
        case .lessThanOrEqual: return value <= thresholdCelsius
        case .lessThan: return value < thresholdCelsius
        }
    }

    /// 是否应解除触发（含迟滞死区）。
    public func shouldRelease(value: Double) -> Bool {
        let deadband = max(0, hysteresisCelsius)
        switch comparator {
        case .greaterThanOrEqual, .greaterThan:
            return value < thresholdCelsius - deadband
        case .lessThanOrEqual, .lessThan:
            return value > thresholdCelsius + deadband
        }
    }
}

/// 一次规则评估的结果。
public struct RuleEvaluation: Equatable, Sendable {
    /// 所有触发规则中的**最大**目标转速（已过 `SafetyPolicy` clamp）；无触发为 nil。
    public let commandedRpm: Double?
    /// 本次处于触发状态的规则 ID（按规则顺序）。
    public let triggeredRuleIDs: [UUID]
    /// 用于安全下限的芯片温度（口径由 `aggregation` 决定）。
    public let dieCelsius: Double?

    public init(commandedRpm: Double?, triggeredRuleIDs: [UUID], dieCelsius: Double?) {
        self.commandedRpm = commandedRpm
        self.triggeredRuleIDs = triggeredRuleIDs
        self.dieCelsius = dieCelsius
    }

    public var isTriggering: Bool { commandedRpm != nil }
}

/// 规则引擎：离散阈值动作 + 迟滞 + 冲突取最大 + 安全下限。
///
/// 契约：
/// - 只持有「哪些规则已触发」这一份状态，其余全由输入决定 → 可重放、可单测；
/// - 多条规则同时触发时取**最大 RPM**（最激进散热优先），绝不取平均/最小；
/// - 输出已经过 `SafetyPolicy.clamp`，调用方可直接下发。
public struct RuleEngine {

    /// 已触发规则集合（迟滞状态的载体）。
    private var armedRuleIDs: Set<UUID> = []

    public init() {}

    public func isTriggered(_ ruleID: UUID) -> Bool {
        armedRuleIDs.contains(ruleID)
    }

    /// 清空迟滞状态（切换策略、睡眠唤醒、用户手动接管后调用）。
    public mutating func reset() {
        armedRuleIDs.removeAll()
    }

    /// 评估一轮规则。
    ///
    /// - Parameter aggregation: 「芯片温度」用哪个口径（最高温 / 均温）。它只影响
    ///   `dieCelsius` 与安全下限；每条规则触发与否仍由规则自己的 `subject` + `metric` 决定。
    public mutating func evaluate(
        snapshot: SensorSnapshot,
        rules: [FanRule],
        limits: FanLimits,
        aggregation: TemperatureAggregation = .peak,
        profile: SafetyProfile = .default
    ) -> RuleEvaluation {
        let dieCelsius = snapshot.controlCelsius(aggregation)

        var triggeredIDs: [UUID] = []
        var candidates: [Double] = []
        var armed: Set<UUID> = []

        for rule in rules {
            guard rule.enabled else { continue }

            guard let value = rule.value(in: snapshot) else {
                // 传感器缺失（SMC 读失败/机型无此键）：不触发，并清除历史状态
                continue
            }

            let nowArmed: Bool
            if armedRuleIDs.contains(rule.id) {
                nowArmed = !rule.shouldRelease(value: value)
            } else {
                nowArmed = rule.passes(value: value)
            }

            guard nowArmed else { continue }

            armed.insert(rule.id)
            triggeredIDs.append(rule.id)
            candidates.append(rule.resolvedRpm(limits: limits))
        }

        armedRuleIDs = armed

        guard let maxRpm = candidates.max(), let die = dieCelsius else {
            return RuleEvaluation(commandedRpm: nil, triggeredRuleIDs: triggeredIDs, dieCelsius: dieCelsius)
        }

        let clamped = SafetyPolicy.clamp(maxRpm, dieCelsius: die, limits: limits, profile: profile)
        return RuleEvaluation(commandedRpm: clamped, triggeredRuleIDs: triggeredIDs, dieCelsius: die)
    }
}
