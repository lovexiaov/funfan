import Foundation
import IOKit

/// `AppleSmartBattery` 注册表属性解析（纯函数）。
///
/// 与 `IOPS*` 的分工：IOPS 给「电量% / 是否充电 / 是否接电源」，
/// 本解析器补齐「健康度 / 循环次数 / 电流 / 电压 / 功率 / 温度」。
///
/// 单位约定（与 ioreg 实际一致）：
/// - `Amperage` 为 **mA**，放电为负；
/// - `Voltage` 为 **mV**；
/// - `Temperature` 为 **0.1 K**（部分机型为 K 或 ℃，见 `temperatureCelsius(fromRaw:)`）。
public enum BatteryDetailParser {

    /// 解析 AppleSmartBattery 属性字典。无电池或关键字段缺失时返回 `.absent`。
    public static func parse(_ properties: [String: Any]) -> BatteryState {
        let current = number(properties["AppleRawCurrentCapacity"]) ?? number(properties["CurrentCapacity"])
        let maxCapacity = BatteryMath.resolveMaxCapacity(
            raw: number(properties["AppleRawMaxCapacity"]),
            legacy: number(properties["MaxCapacity"])
        )
        let design = number(properties["DesignCapacity"])
        let cycleCount = number(properties["CycleCount"]).map { Int($0) }

        // 台式机的 AppleSmartBattery 节点可能存在但容量全 0（真机实测），
        // 因此「有正容量」才判定为有电池；仅凭节点存在或 CycleCount 会误报。
        guard (maxCapacity ?? 0) > 0 || (design ?? 0) > 0 else {
            return .absent
        }

        let amperage = number(properties["Amperage"]).map { $0 / 1000.0 }   // mA → A
        let voltage = number(properties["Voltage"]).map { $0 / 1000.0 }     // mV → V

        return BatteryState(
            present: true,
            percentage: BatteryMath.percentage(current: current, max: maxCapacity),
            health: BatteryMath.health(max: maxCapacity, design: design),
            cycleCount: cycleCount,
            amperage: amperage,
            voltage: voltage,
            powerWatts: BatteryMath.power(voltage: voltage, amperage: amperage),
            isCharging: boolean(properties["IsCharging"]),
            externalConnected: boolean(properties["ExternalConnected"]),
            temperatureCelsius: temperatureCelsius(fromRaw: number(properties["Temperature"])),
            designCapacity: design,
            maxCapacity: maxCapacity,
            currentCapacity: current
        )
    }

    /// 温度单位启发式（真机存在 0.1 K / K / ℃ 三种形态）。
    ///
    /// 判定顺序：`> 1000` 视为 0.1 K；`> 100` 视为 K；否则视为已经是 ℃。
    /// 最终统一做「5–120℃」合理性校验，异常值一律返回 nil（避免 UI 出现 -240℃）。
    public static func temperatureCelsius(fromRaw raw: Double?) -> Double? {
        guard let raw, raw > 0 else { return nil }

        let celsius: Double
        if raw > 1000 {
            celsius = raw / 10.0 - 273.15
        } else if raw > 100 {
            celsius = raw - 273.15
        } else {
            celsius = raw
        }

        guard celsius >= 5, celsius <= 120 else { return nil }
        return celsius
    }

    // MARK: - 取值辅助

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: return number.doubleValue
        case let int as Int: return Double(int)
        case let double as Double: return double
        default: return nil
        }
    }

    private static func boolean(_ value: Any?) -> Bool {
        switch value {
        case let number as NSNumber: return number.boolValue
        case let bool as Bool: return bool
        default: return false
        }
    }
}

/// 从 IORegistry 读取 `AppleSmartBattery` 属性（真实系统）。
///
/// 无电池机型（Mac mini / Studio / MacBook Air 之外的台式机）返回空字典，上层降级为 `.absent`。
public enum AppleSmartBatteryReader {

    public static func properties() -> [String: Any] {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return [:] }
        defer { IOObjectRelease(service) }

        var unmanaged: Unmanaged<CFMutableDictionary>?
        let kr = IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0)
        guard kr == KERN_SUCCESS, let cfProperties = unmanaged?.takeRetainedValue() else {
            return [:]
        }
        return cfProperties as? [String: Any] ?? [:]
    }
}
