import Foundation

/// 调速依据温度的口径：最高温 / 平均温。
///
/// 它决定的是「风扇按哪个温度动」，不是「界面显示哪个数字」：
/// - `CurveAutomation` 的插值输入；
/// - `SafetyPolicy` 的动态安全下限锚点；
/// - `RuleEngine` 的 `dieCelsius`（规则触发值仍由每条规则自己的 `Metric` 决定）。
///
/// 两个口径的取值集合**刻意不同**，理由见 `controlCelsius(_:)` 的注释。
public enum TemperatureAggregation: String, Codable, CaseIterable, Sendable, Hashable {
    /// 全部传感器中的最高温（默认，最保守）。
    case peak
    /// 核心簇（CPU + GPU）全部探测点的均温。
    case average
}

extension SensorSnapshot {

    /// 按用户选择的统计口径算出「芯片温度」（曲线输入 + 安全下限锚点）。
    ///
    /// 两个口径的取值集合不同，这不是疏漏：
    /// - **最高温取全部传感器**：安全方向。SSD、电池里只要有一个真的烫了，
    ///   也说明机箱里在积热，宁可多转一点——少算一个传感器就是漏掉一条告警。
    /// - **均温只取 CPU + GPU**：调速方向。SSD / 电池 / 环境温度键数量不少
    ///   （M4 mini 上 SSD 29 个、`other` 52 个），温度却普遍偏低，混进平均会把
    ///   「芯片均温」稀释十几度，风扇该提速时反而更安静——那就不是「按均温调速」，
    ///   而是「按一堆不发热的传感器调速」。
    ///
    /// 核心簇一个读数都没有时（机型特殊 / 唤醒那一帧）退回全量均温，
    /// 而不是返回 nil：返回 nil 会让风扇直接返还系统，负载中掉转速比算什么更糟。
    public func controlCelsius(_ aggregation: TemperatureAggregation) -> Double? {
        let usable = readings.filter { $0.celsius.isFinite }
        switch aggregation {
        case .peak:
            return usable.map(\.celsius).max()

        case .average:
            let core = usable.filter {
                $0.descriptor.category == .cpu || $0.descriptor.category == .gpu
            }
            let values = (core.isEmpty ? usable : core).map(\.celsius)
            guard !values.isEmpty else { return nil }
            return values.reduce(0, +) / Double(values.count)
        }
    }
}
