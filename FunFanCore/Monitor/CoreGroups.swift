import Foundation

/// 按簇聚合后的温度组，供 UI 展开显示。
///
/// 关键修正（修复「展开 CPU/GPU 个数和实际对不上」）：
/// `sensors` 是该簇**全部 SMC 温度探测点**（用真实键名 `descriptor.key`，
/// 例如 `Tp01`、`Tp0W`），**不是核心**。
/// Apple Silicon 一个物理核簇会暴露多个探测点，拿探测点数量当核数必然对不上；
/// 真实核心数请取 `ChipTopology`（来自 sysctl / IORegistry）。
public struct CoreGroup: Identifiable, Equatable {
    public let id: String
    public let title: String
    /// 该组全部探测点的均温。
    public let average: Double
    /// 该簇全部 SMC 温度探测点（真实键名 + 读数）。数量 ≠ 核心数。
    public let sensors: [(key: String, celsius: Double)]

    public var sensorCount: Int { sensors.count }

    public static func == (lhs: CoreGroup, rhs: CoreGroup) -> Bool {
        lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.average == rhs.average
            && lhs.sensors.count == rhs.sensors.count
            && lhs.sensors.elementsEqual(rhs.sensors, by: { $0.key == $1.key && $0.celsius == $1.celsius })
    }
}

extension SensorSnapshot {

    /// 按「CPU 的 P/E/Super 簇 + GPU」聚合成可展开的分组。
    ///
    /// 每个簇列出其**全部** SMC 探测点（含前缀回退发现的），用真实键名，
    /// 不再伪装成「核心」。核心数由 `ChipTopology` 单独提供，不要从这里推断。
    public func coreGroups() -> [CoreGroup] {
        var groups: [CoreGroup] = []

        for subcluster in [CPUSubcluster.performance, .efficiency, .superCluster] {
            let all = readings.filter { $0.descriptor.subcluster == subcluster }
            guard !all.isEmpty, let average = average(subcluster: subcluster) else { continue }
            let sensors = all.map { (key: $0.descriptor.key, celsius: $0.celsius) }
            groups.append(CoreGroup(
                id: "cpu-\(subcluster.rawValue)",
                title: "CPU · \(subcluster.rawValue)",
                average: average,
                sensors: sensors
            ))
        }

        let gpuReadings = readings(in: .gpu)
        if !gpuReadings.isEmpty, let gpuAverage = averageGPU() {
            let sensors = gpuReadings.map { (key: $0.descriptor.key, celsius: $0.celsius) }
            groups.append(CoreGroup(id: "gpu", title: "GPU", average: gpuAverage, sensors: sensors))
        }

        return groups
    }
}
