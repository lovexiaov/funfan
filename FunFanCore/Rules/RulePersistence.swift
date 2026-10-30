import Foundation

/// 规则的磁盘持久化（JSON）。
///
/// 设计要点：
/// - **坏文件不崩**：缺失/损坏/版本不符一律当作「无规则」，绝不因为配置文件坏了就起不来；
/// - **读的时候也清洗**：阈值/迟滞/百分比全部夹到物理合理区间，避免手改 JSON 写出危险转速；
/// - **原子写**：先写临时文件再替换，避免断电留下半截 JSON。
public struct RulePersistence {

    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// 默认位置：`~/Library/Application Support/FunFan/rules.json`
    public static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("FunFan", isDirectory: true)
            .appendingPathComponent("rules.json")
    }

    // MARK: - 读写

    public func load() -> [FanRule] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        guard let decoded = try? JSONDecoder().decode([FanRule].self, from: data) else { return [] }
        return sanitize(decoded)
    }

    public func save(_ rules: [FanRule]) throws {
        let cleaned = sanitize(rules)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(cleaned)

        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // 原子写：临时文件 + replace
        let temporary = fileURL.deletingLastPathComponent()
            .appendingPathComponent("rules.json.\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: .atomic)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: fileURL)
        }
    }

    // MARK: - 清洗

    /// 阈值可用的物理区间（℃）。低于 0 或高于 120 都是明显错误输入。
    public static let thresholdRange: ClosedRange<Double> = 0...120
    /// 迟滞死区上限（℃）：再大就等于「永不解除」。
    public static let hysteresisRange: ClosedRange<Double> = 0...30
    /// RPM 的绝对上限保护（防止手改 JSON 写出荒谬值）。
    public static let rpmRange: ClosedRange<Double> = 0...12_000

    /// 清洗规则集：夹值、去重、补名。**不改变 `enabled`**（用户的启停选择必须保留）。
    public func sanitize(_ rules: [FanRule]) -> [FanRule] {
        var seen = Set<UUID>()
        var output: [FanRule] = []

        for var rule in rules {
            guard seen.insert(rule.id).inserted else { continue }

            rule.thresholdCelsius = clamp(rule.thresholdCelsius, to: Self.thresholdRange)
            rule.hysteresisCelsius = clamp(rule.hysteresisCelsius, to: Self.hysteresisRange)

            switch rule.action {
            case .setRpm(let rpm):
                rule.action = .setRpm(clamp(rpm, to: Self.rpmRange))
            case .setPercent(let percent):
                rule.action = .setPercent(clamp(percent, to: 0...100))
            }

            let trimmed = rule.name.trimmingCharacters(in: .whitespacesAndNewlines)
            rule.name = trimmed.isEmpty ? "未命名规则" : trimmed

            output.append(rule)
        }

        return output
    }

    private func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        guard value.isFinite else { return range.lowerBound }
        return Swift.min(Swift.max(value, range.lowerBound), range.upperBound)
    }

    // MARK: - 首次启动模板

    /// 首次启动的示例规则：保守阈值，只做「压不住才提速」，不会长期占用手动控制。
    public static var sampleRules: [FanRule] {
        [
            FanRule(
                name: "CPU 高温提速",
                subject: .category(.cpu),
                metric: .peak,
                comparator: .greaterThanOrEqual,
                thresholdCelsius: 75,
                action: .setPercent(60),
                hysteresisCelsius: 4
            ),
            FanRule(
                name: "GPU 高温提速",
                subject: .category(.gpu),
                metric: .peak,
                comparator: .greaterThanOrEqual,
                thresholdCelsius: 80,
                action: .setPercent(75),
                hysteresisCelsius: 4
            ),
        ]
    }
}
