import Foundation

/// 曲线的磁盘持久化（JSON）。
///
/// 与 `RulePersistence` 同一套原则：
/// - **坏文件不崩**：缺失 / 损坏 / 控制点不足以构成曲线 → 当作「没有曲线」，回落到预设；
/// - **读的时候也清洗**：温度、转速夹到物理合理区间，手改 JSON 写不出荒谬转速；
/// - **原子写**：临时文件 + replace，断电不会留下半截 JSON。
public struct CurvePersistence {

    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// 默认位置：`~/Library/Application Support/FunFan/curve.json`
    public static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("FunFan", isDirectory: true)
            .appendingPathComponent("curve.json")
    }

    // MARK: - 读写

    /// 读取曲线；文件缺失/损坏/清洗后不成形时返回 nil（调用方回落预设）。
    public func load() -> FanCurve? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        guard let decoded = try? JSONDecoder().decode(FanCurve.self, from: data) else { return nil }
        return Self.sanitize(decoded)
    }

    public func save(_ curve: FanCurve) throws {
        guard let cleaned = Self.sanitize(curve) else { return }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(cleaned)

        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let temporary = fileURL.deletingLastPathComponent()
            .appendingPathComponent("curve.json.\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: .atomic)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: fileURL)
        }
    }

    // MARK: - 清洗

    /// 控制点温度区间（℃）：低于 20 或高于 110 都是明显错误输入。
    public static let celsiusRange: ClosedRange<Double> = 20...110
    /// 转速上限保护（防止手改 JSON 写出荒谬值；真实上限仍由 `SafetyPolicy` 管）。
    public static let rpmRange: ClosedRange<Double> = 0...12_000
    /// 一条曲线最多的控制点数：再多也画不清、拖不动。
    public static let maxPoints = 12
    /// 两个控制点的最小温度间隔（℃）：重合会让插值出现除零。
    public static let minGapCelsius = 0.5

    /// 清洗曲线：夹值 → 排序 → 去重合 → 截断。返回 nil 表示「不足以构成曲线」。
    public static func sanitize(_ curve: FanCurve) -> FanCurve? {
        var points = curve.points.compactMap { point -> CurvePoint? in
            guard point.celsius.isFinite, point.rpm.isFinite else { return nil }
            return CurvePoint(
                celsius: min(max(point.celsius, celsiusRange.lowerBound), celsiusRange.upperBound),
                rpm: min(max(point.rpm, rpmRange.lowerBound), rpmRange.upperBound)
            )
        }
        points.sort { $0.celsius < $1.celsius }

        // 温度过于接近的点只保留后一个（用户刚拖出来的那个更接近意图）
        var deduped: [CurvePoint] = []
        for point in points {
            if let last = deduped.last, point.celsius - last.celsius < minGapCelsius {
                deduped[deduped.count - 1] = point
            } else {
                deduped.append(point)
            }
        }

        guard deduped.count >= 2 else { return nil }

        if deduped.count > maxPoints {
            // 保留前 11 个 + 最后一个：首尾是曲线的语义锚点，不能丢
            let head = Array(deduped.prefix(maxPoints - 1))
            let tail = deduped.suffix(1)
            deduped = head + tail
        }

        return FanCurve(points: deduped)
    }
}
