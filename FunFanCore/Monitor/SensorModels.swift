import Foundation

/// 温度/转速等传感器的语义类别。
public enum SensorCategory: String, Codable, CaseIterable, Sendable {
    case cpu
    case gpu
    case memory
    case battery
    case ambient
    case ssd
    case other
}

/// CPU 内部子簇（Apple Silicon：P 性能核 / E 能效核 / M5 Super 簇）。
public enum CPUSubcluster: String, Codable, Sendable {
    case performance
    case efficiency
    case superCluster
    case unknown
}

    /// 单个传感器的描述（键名 + 友好名 + 归类）。
    public struct SensorDescriptor: Equatable, Sendable {
        public let key: String
        public let name: String
        public let category: SensorCategory
        public let subcluster: CPUSubcluster?

        public init(
            key: String,
            name: String,
            category: SensorCategory,
            subcluster: CPUSubcluster? = nil
        ) {
            self.key = key
            self.name = name
            self.category = category
            self.subcluster = subcluster
        }
    }

/// 某传感器的实时读数。
public struct SensorReading: Equatable, Sendable {
    public let descriptor: SensorDescriptor
    public let celsius: Double

    public init(descriptor: SensorDescriptor, celsius: Double) {
        self.descriptor = descriptor
        self.celsius = celsius
    }
}

/// 某一类温度在「这台机器上」的可用性。
///
/// 存在的理由：`average(for:) == nil` 有两种截然不同的成因，混在一起显示成「—」
/// 会让人以为功能坏了：
/// - 这台机器**没有**该类传感器（永久，例如 Mac mini M4 的 180 个温度键里
///   一个 `TA*` 都没有，环境温度格永远读不到值）；
/// - 刚启动 / 刚唤醒**还没采到**样本（瞬时，下一帧就有）。
public enum SensorAvailability: Equatable, Sendable {
    /// 该类传感器有读数（值为均温），可以是 0 个以上传感器的平均。
    case available(Double)
    /// 该类传感器存在，但本次快照没给出可用读数（唤醒瞬间、单帧丢读）。
    case pending
    /// 这台机器没有暴露该类传感器。
    case unsupported
}

/// 一次采样的完整快照，提供按类别聚合能力。
public struct SensorSnapshot: Equatable, Sendable {    public let readings: [SensorReading]
    public let timestamp: Date

    public init(readings: [SensorReading], timestamp: Date) {
        self.readings = readings
        self.timestamp = timestamp
    }

    public func readings(in category: SensorCategory) -> [SensorReading] {
        readings.filter { $0.descriptor.category == category }
    }

    public func average(for category: SensorCategory) -> Double? {
        let values = readings(in: category).map(\.celsius)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    public func averageCPU() -> Double? { average(for: .cpu) }
    public func averageGPU() -> Double? { average(for: .gpu) }

    /// 某类别在本帧里的可用性——区分「这台机器没有」与「暂时没读数」。
    ///
    /// 关键点：**不能只凭本帧读数判断「没有」**。`SMCTemperatureProvider` 会把
    /// 读失败和越界值整条丢掉，睡眠唤醒那一帧完全可能出现「键存在但没读数」；
    /// 若判成 `unsupported`，界面会在唤醒瞬间闪一下「无传感器」再跳回数值。
    /// 所以「这台机器有没有」必须由键表回答，即参数 `sensorCount`。
    ///
    /// - Parameters:
    ///   - category: 待判定的类别。
    ///   - sensorCount: 该类别在本机键表里的传感器个数；`nil` 表示键表尚未枚举
    ///     （例如 SMC 刚打开、枚举失败），此时不下「没有」的结论。
    public func availability(
        for category: SensorCategory,
        sensorCount: Int?
    ) -> SensorAvailability {
        if let value = average(for: category) { return .available(value) }
        switch sensorCount {
        case .none: return .pending
        case .some(0): return .unsupported
        case .some: return .pending      // 有键，只是这一帧没读到
        }
    }

    /// 某 CPU 子簇（P/E/Super）的平均温度——包含该簇全部传感器，反映簇整体热度。
    public func average(subcluster: CPUSubcluster) -> Double? {
        let values = readings
            .filter { $0.descriptor.subcluster == subcluster }
            .map(\.celsius)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}
