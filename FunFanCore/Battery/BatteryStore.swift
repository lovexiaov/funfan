import Foundation
import IOKit
import IOKit.ps

/// 电池数据提供者抽象，便于单测注入假实现。
public protocol BatteryProvider {
    func read() -> BatteryState
}

/// 电池存储：持有最近一次快照，`refresh()` 拉取。
public final class BatteryStore {
    private let provider: BatteryProvider
    public private(set) var state: BatteryState

    public init(provider: BatteryProvider = SystemBatteryProvider()) {
        self.provider = provider
        self.state = .absent
    }

    @discardableResult
    public func refresh() -> BatteryState {
        state = provider.read()
        return state
    }
}

/// 真实系统电池读取。
///
/// 数据源分工：
/// - `IOPS*`：电量% / 充电状态 / 供电状态（免 root、沙箱友好）；
/// - `AppleSmartBattery`：健康度 / 循环次数 / 电压电流 / 温度（同源免 root）。
///
/// 无电池机型返回 `.absent`，上层据此隐藏电池卡（优雅降级）。
public struct SystemBatteryProvider: BatteryProvider {

    public init() {}

    public func read() -> BatteryState {
        let details = BatteryDetailParser.parse(AppleSmartBatteryReader.properties())

        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else {
            return details
        }

        for source in sources {
            guard let raw = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue(),
                  let desc = raw as? [String: Any]
            else { continue }
            return Self.merge(ioPS: desc, details: details)
        }
        return details
    }

    /// IOPS 优先提供百分比与供电状态，AppleSmartBattery 补齐明细。
    private static func merge(ioPS desc: [String: Any], details: BatteryState) -> BatteryState {
        let present = (desc[kIOPSIsPresentKey] as? NSNumber)?.boolValue ?? details.present
        guard present else { return .absent }

        let current = (desc[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue
        let maxCapacity = (desc[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue
        let charging = (desc[kIOPSIsChargingKey] as? NSNumber)?.boolValue ?? details.isCharging
        let external = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue

        // IOPS 的 CurrentCapacity 即「已换算的百分比」（0–100）；缺失时回退到容量比。
        let percentage = current ?? details.percentage

        return BatteryState(
            present: true,
            percentage: percentage,
            health: details.health,
            cycleCount: details.cycleCount,
            amperage: details.amperage,
            voltage: details.voltage,
            powerWatts: details.powerWatts,
            isCharging: charging,
            externalConnected: external,
            temperatureCelsius: details.temperatureCelsius,
            designCapacity: details.designCapacity,
            maxCapacity: details.maxCapacity ?? maxCapacity,
            currentCapacity: details.currentCapacity
        )
    }
}
