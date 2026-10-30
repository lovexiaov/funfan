import Foundation

/// 定长滑动窗口，用于温度平滑（均值）。
public struct SlidingWindow: Sendable {
    private var values: [Double] = []
    public let capacity: Int

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    public mutating func add(_ value: Double) {
        values.append(value)
        if values.count > capacity {
            values.removeFirst(values.count - capacity)
        }
    }

    public var count: Int { values.count }

    public var mean: Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}

/// 传感器监视器：纯逻辑引擎（不含计时器）。
///
/// GUI 层用 2 Hz 定时器调用 `tick()`；此类型只负责「采样 → 平滑 → 产出快照」，
/// 因此可用注入的样本源在单测中确定性验证。
public final class SensorMonitor {
    private var windows: [String: SlidingWindow] = [:]
    private let windowCapacity: Int
    private let provider: () -> [SensorReading]

    public private(set) var latest: SensorSnapshot?

    public init(windowCapacity: Int = 60, provider: @escaping () -> [SensorReading]) {
        self.windowCapacity = max(1, windowCapacity)
        self.provider = provider
    }

    /// 推进一个采样周期，返回平滑后的快照。
    @discardableResult
    public func tick(now: Date = Date()) -> SensorSnapshot {
        let readings = provider()

        for reading in readings {
            var window = windows[reading.descriptor.key] ?? SlidingWindow(capacity: windowCapacity)
            window.add(reading.celsius)
            windows[reading.descriptor.key] = window
        }

        let smoothed = readings.map { reading -> SensorReading in
            let mean = windows[reading.descriptor.key]?.mean ?? reading.celsius
            return SensorReading(descriptor: reading.descriptor, celsius: mean)
        }

        let snapshot = SensorSnapshot(readings: smoothed, timestamp: now)
        latest = snapshot
        return snapshot
    }
}
