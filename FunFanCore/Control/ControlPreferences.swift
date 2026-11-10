import Foundation

/// 控制策略与固定转速的持久化。
///
/// 只存「用户明确选过的东西」：策略 + 固定转速。它们决定重启后风扇怎么跑，
/// 不存的话每次启动都会悄悄退回「自动 / 2000 RPM」——用户以为设置丢了。
///
/// 键名带 `FunFan.` 前缀，与 `SettingsStore.showsTemperatureKey` 同一命名空间。
/// 规则与曲线不走这里，它们在 `~/Library/Application Support/FunFan/*.json`。
public struct ControlPreferences {

    public static let strategyKey = "FunFan.controlStrategy"
    public static let fixedRpmKey = "FunFan.fixedRpm"
    public static let temperatureAggregationKey = "FunFan.temperatureAggregation"
    public static let defaultFixedRpm: Double = 2000

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 上次选择的策略；没存过或值无法识别时回落「自动」。
    ///
    /// 无法识别（旧版本写过别的值、或用户手改了 plist）时不报错也不猜：
    /// 唯一的正确行为是回到最安全的自动，而不是拿一个来路不明的策略去接管风扇。
    public var strategy: ControlStrategy {
        get {
            guard let raw = defaults.string(forKey: Self.strategyKey),
                  let value = ControlStrategy(rawValue: raw) else {
                return .automatic
            }
            return value
        }
        nonmutating set {
            defaults.set(newValue.rawValue, forKey: Self.strategyKey)
        }
    }

    /// 调速依据温度的口径（最高温 / 均温）。
    ///
    /// 无法识别（旧版本写过别的值、手改 plist）时回落「最高温」——那是
    /// 更保守的一侧：宁可多转，也不会因为读不懂配置而让风扇少转。
    public var temperatureAggregation: TemperatureAggregation {
        get {
            guard let raw = defaults.string(forKey: Self.temperatureAggregationKey),
                  let value = TemperatureAggregation(rawValue: raw) else {
                return .peak
            }
            return value
        }
        nonmutating set {
            defaults.set(newValue.rawValue, forKey: Self.temperatureAggregationKey)
        }
    }

    /// 固定策略下的目标转速。
    ///
    /// 这里**不做**转速区间 clamp：真实区间要等 helper 连上才知道（不同机型
    /// 1000–4900 到 1200–6800 不等），`ControlStore.bootstrap` 拿到 `FanLimits`
    /// 后会再收敛一次。这里只挡住「明显不是转速」的脏值（NaN / 0 / 负数）。
    public var fixedRpm: Double {
        get {
            guard let number = defaults.object(forKey: Self.fixedRpmKey) as? NSNumber else {
                return Self.defaultFixedRpm
            }
            let value = number.doubleValue
            guard value.isFinite, value > 0 else { return Self.defaultFixedRpm }
            return value
        }
        nonmutating set {
            defaults.set(newValue, forKey: Self.fixedRpmKey)
        }
    }
}
