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

    /// 是否为「内置密钥表确认的独立传感器」（CPU 逐核 / GPU 逐簇 / SSD 等具体部件）。
    ///
    /// 前缀回退发现的键（如 `Tp0W`、`Te0V`）只保证**类别**，不代表一个核——
    /// 同一物理核常暴露多个探测点，把它们当「核」会虚构出几十个假核心。
    /// 因此这些键 `isCoreLevel == false`，UI 只在簇/类别层级聚合展示。
    public let isCoreLevel: Bool

    public init(
        key: String,
        name: String,
        category: SensorCategory,
        subcluster: CPUSubcluster? = nil,
        isCoreLevel: Bool = false
    ) {
        self.key = key
        self.name = name
        self.category = category
        self.subcluster = subcluster
        self.isCoreLevel = isCoreLevel
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

/// 一次采样的完整快照，提供按类别聚合能力。
public struct SensorSnapshot: Equatable, Sendable {
    public let readings: [SensorReading]
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

    /// 仅「逐核确认」的读数（对应 UI「展开各核心」，不含前缀推断的聚合成员）。
    public func coreLevelReadings(in category: SensorCategory) -> [SensorReading] {
        readings(in: category).filter { $0.descriptor.isCoreLevel }
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
