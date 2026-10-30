import Foundation

/// 温度传感器目录：键名 → 语义归类。
///
/// 策略（与 Spec §4.1 一致）：
/// 1. 首选内置逐代密钥表（示例覆盖 M1–M5 常见键）；
/// 2. 未收录者按两字符前缀回退；
/// 3. 仍无法归类的 4 字符 `T*` 键归为 `.other`；非温度键返回 nil。
public enum SensorCatalog {

    private struct Entry {
        let name: String
        let category: SensorCategory
        let subcluster: CPUSubcluster?
    }

    /// 内置逐代密钥表（持续补充）。键必须 4 字符。
    private static let table: [String: Entry] = [
        "Tp01": Entry(name: "P-Core 0", category: .cpu, subcluster: .performance),
        "Tp09": Entry(name: "P-Core 1", category: .cpu, subcluster: .performance),
        "Tp0O": Entry(name: "Super Cluster 0", category: .cpu, subcluster: .superCluster),
        "Tf04": Entry(name: "P-Core 0", category: .cpu, subcluster: .performance),
        "Tf09": Entry(name: "P-Core 1", category: .cpu, subcluster: .performance),
        "Te05": Entry(name: "E-Core 0", category: .cpu, subcluster: .efficiency),
        "Tg0G": Entry(name: "GPU Cluster 0", category: .gpu, subcluster: nil),
        "Tg05": Entry(name: "GPU Cluster 0", category: .gpu, subcluster: nil),
        "Tg0H": Entry(name: "GPU Cluster 1", category: .gpu, subcluster: nil),
        "TB0T": Entry(name: "Battery", category: .battery, subcluster: nil),
        "Ts0P": Entry(name: "SSD", category: .ssd, subcluster: nil),
        "TA0P": Entry(name: "Ambient", category: .ambient, subcluster: nil),
        "Tm0P": Entry(name: "Memory", category: .memory, subcluster: nil),
    ]

    /// 归类单个键。非温度键返回 nil。
    public static func descriptor(for key: String) -> SensorDescriptor? {
        guard key.count == 4, key.hasPrefix("T") else { return nil }

        if let entry = table[key] {
            return SensorDescriptor(
                key: key,
                name: entry.name,
                category: entry.category,
                subcluster: entry.subcluster,
                isCoreLevel: true
            )
        }

        switch String(key.prefix(2)) {
        case "Tp", "Tf":
            return SensorDescriptor(key: key, name: key, category: .cpu, subcluster: .performance)
        case "Te":
            return SensorDescriptor(key: key, name: key, category: .cpu, subcluster: .efficiency)
        case "Tg":
            return SensorDescriptor(key: key, name: key, category: .gpu, subcluster: nil)
        case "Tm":
            return SensorDescriptor(key: key, name: key, category: .memory, subcluster: nil)
        case "TB":
            return SensorDescriptor(key: key, name: key, category: .battery, subcluster: nil)
        case "TA":
            return SensorDescriptor(key: key, name: key, category: .ambient, subcluster: nil)
        case "Ts":
            return SensorDescriptor(key: key, name: key, category: .ssd, subcluster: nil)
        default:
            return SensorDescriptor(key: key, name: key, category: .other, subcluster: nil)
        }
    }

    /// 从「全部键名」中筛出温度键（`T` 开头的 4 字符键），去重并按 key 排序。
    ///
    /// 这是全键枚举（`SMCKeyEnumeration`）之后的第一步过滤：SMC 里有大量非温度键
    /// （风扇 `F*`、电源 `P*`、灯 `L*` 等），必须先剔除再归类。
    public static func temperatureKeys(fromAllKeys keys: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for key in keys where isTemperatureKey(key) {
            if seen.insert(key).inserted {
                result.append(key)
            }
        }
        return result.sorted()
    }

    /// 是否为候选温度键：4 字符且以 `T` 开头。
    public static func isTemperatureKey(_ key: String) -> Bool {
        key.count == 4 && key.hasPrefix("T")
    }

    /// 从键名列表构建去重、按 key 排序的传感器描述（自动过滤非温度键）。
    public static func descriptors(forKeys keys: [String]) -> [SensorDescriptor] {
        var seen = Set<String>()
        var result: [SensorDescriptor] = []
        for key in keys {
            guard seen.insert(key).inserted else { continue }
            if let descriptor = descriptor(for: key) {
                result.append(descriptor)
            }
        }
        return result.sorted { $0.key < $1.key }
    }
}
