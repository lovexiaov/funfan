import Foundation

/// 电池/电量状态快照。
public struct BatteryState: Equatable, Sendable {
    public let present: Bool
    public let percentage: Double?        // 0–100
    public let health: Double?            // 0–100
    public let cycleCount: Int?
    public let amperage: Double?          // A，放电为负
    public let voltage: Double?           // V
    public let powerWatts: Double?        // V × A
    public let isCharging: Bool
    public let externalConnected: Bool
    public let temperatureCelsius: Double?
    public let designCapacity: Double?
    public let maxCapacity: Double?
    public let currentCapacity: Double?

    public init(
        present: Bool,
        percentage: Double?,
        health: Double?,
        cycleCount: Int?,
        amperage: Double?,
        voltage: Double?,
        powerWatts: Double?,
        isCharging: Bool,
        externalConnected: Bool,
        temperatureCelsius: Double?,
        designCapacity: Double?,
        maxCapacity: Double?,
        currentCapacity: Double?
    ) {
        self.present = present
        self.percentage = percentage
        self.health = health
        self.cycleCount = cycleCount
        self.amperage = amperage
        self.voltage = voltage
        self.powerWatts = powerWatts
        self.isCharging = isCharging
        self.externalConnected = externalConnected
        self.temperatureCelsius = temperatureCelsius
        self.designCapacity = designCapacity
        self.maxCapacity = maxCapacity
        self.currentCapacity = currentCapacity
    }

    /// 无电池机型（台式机）降级值。
    public static let absent = BatteryState(
        present: false,
        percentage: nil,
        health: nil,
        cycleCount: nil,
        amperage: nil,
        voltage: nil,
        powerWatts: nil,
        isCharging: false,
        externalConnected: false,
        temperatureCelsius: nil,
        designCapacity: nil,
        maxCapacity: nil,
        currentCapacity: nil
    )
}

/// 电量派生计算（纯函数，便于单测）。
public enum BatteryMath {

    /// 电量百分比 = current / max × 100。
    public static func percentage(current: Double?, max: Double?) -> Double? {
        guard let current, let max, max > 0 else { return nil }
        return current / max * 100.0
    }

    /// 健康度 = maxCapacity / designCapacity × 100。
    public static func health(max: Double?, design: Double?) -> Double? {
        guard let max, let design, design > 0 else { return nil }
        return max / design * 100.0
    }

    /// 瞬时功率（W）= 电压(V) × 电流(A)；符号表示充/放。
    public static func power(voltage: Double?, amperage: Double?) -> Double? {
        guard let voltage, let amperage else { return nil }
        return voltage * amperage
    }

    /// Apple Silicon 用 AppleRawMaxCapacity，Intel 用 MaxCapacity；raw 优先。
    public static func resolveMaxCapacity(raw: Double?, legacy: Double?) -> Double? {
        raw ?? legacy
    }
}
