import Foundation

/// 风扇转速上下限（来自 SMC `F0Mn` / `F0Mx`，运行时读取）。
public struct FanLimits: Equatable, Sendable {
    /// 系统允许的最小转速（`F0Mn`）。
    public let minRpm: Double
    /// 系统允许的最大转速（`F0Mx`）。
    public let maxRpm: Double

    public init(minRpm: Double, maxRpm: Double) {
        self.minRpm = minRpm
        self.maxRpm = maxRpm
    }

    /// 归一化上界：机型返回异常（min > max）时取大者，避免算出越界值。
    public var normalizedMax: Double { Swift.max(maxRpm, minRpm) }

    /// 上下限是否可用于控制（必须为正且有限）。
    public var isUsable: Bool {
        minRpm.isFinite && maxRpm.isFinite && minRpm > 0 && maxRpm > 0
    }
}

/// 安全下限的温度锚点配置。
public struct SafetyProfile: Equatable, Sendable {
    /// 低于此温度，下限即系统最小转速（不干预散热）。
    public var floorStartCelsius: Double
    /// 达到此温度，下限升到系统最大转速（全力散热）。
    public var floorEndCelsius: Double

    public init(floorStartCelsius: Double = 60, floorEndCelsius: Double = 95) {
        self.floorStartCelsius = floorStartCelsius
        self.floorEndCelsius = floorEndCelsius
    }

    public static let `default` = SafetyProfile()
}

/// 安全策略：把「任何策略输出」收敛到安全区间。
///
/// 核心不变量（Spec §7 Boundaries）：
/// 1. `commanded >= floor(dieTemp)`——只允许比系统更激进，绝不允许更怠速；
/// 2. `commanded >= F0Mn` 且 `<= F0Mx`；
/// 3. 绝不返回 0 RPM（0 会让风扇停转，硬件风险）；
/// 4. 传感器读数异常（NaN/∞）时退回系统下限，而不是把风扇拉满。
public enum SafetyPolicy {

    /// 基于核心温度动态计算的安全下限（线性映射）。
    ///
    /// `dieCelsius <= start` → 系统最小；`>= end` → 系统最大；中间线性插值。
    public static func floorRpm(
        dieCelsius: Double,
        limits: FanLimits,
        profile: SafetyProfile = .default
    ) -> Double {
        guard dieCelsius.isFinite else { return limits.minRpm }

        let upper = limits.normalizedMax
        let start = profile.floorStartCelsius
        let end = profile.floorEndCelsius
        guard end > start else { return upper }

        if dieCelsius <= start { return limits.minRpm }
        if dieCelsius >= end { return upper }

        let ratio = (dieCelsius - start) / (end - start)
        return limits.minRpm + (upper - limits.minRpm) * ratio
    }

    /// 把目标转速收敛到安全区间。
    public static func clamp(
        _ commandedRpm: Double,
        dieCelsius: Double,
        limits: FanLimits,
        profile: SafetyProfile = .default
    ) -> Double {
        let floor = floorRpm(dieCelsius: dieCelsius, limits: limits, profile: profile)
        let upper = limits.normalizedMax

        var value = commandedRpm.isFinite ? commandedRpm : floor
        value = max(value, floor)
        value = max(value, limits.minRpm)   // 双保险：floor 已 >= minRpm
        return min(value, upper)
    }

    /// 目标转速是否可下发（helper 侧下发前二次校验，防止 GUI 侧被绕过）。
    public static func isValidTarget(_ rpm: Double, limits: FanLimits) -> Bool {
        guard rpm.isFinite, rpm > 0 else { return false }
        return rpm >= limits.minRpm && rpm <= limits.normalizedMax
    }
}
