import XCTest
@testable import FunFanCore

/// T5：滑动窗口与 SensorMonitor 平滑
final class SensorMonitorTests: XCTestCase {

    func testSlidingWindowMeanAndEviction() {
        var w = SlidingWindow(capacity: 3)
        XCTAssertNil(w.mean)
        w.add(10)
        XCTAssertEqual(w.mean!, 10, accuracy: 1e-9)
        w.add(20); w.add(30)
        XCTAssertEqual(w.mean!, 20, accuracy: 1e-9)
        w.add(40) // 逐出 10 -> (20+30+40)/3
        XCTAssertEqual(w.mean!, 30, accuracy: 1e-9)
    }

    /// 用可注入的样本源驱动 tick，验证平滑后的快照均温。
    func testMonitorSmoothsAcrossTicks() {
        final class Provider {
            let samples: [[SensorReading]]
            var i = 0
            init(_ s: [[SensorReading]]) { samples = s }
            func next() -> [SensorReading] {
                defer { i += 1 }
                return samples[min(i, samples.count - 1)]
            }
        }
        let d = SensorCatalog.descriptor(for: "Tp01")!
        let provider = Provider([
            [SensorReading(descriptor: d, celsius: 60)],
            [SensorReading(descriptor: d, celsius: 70)],
        ])
        let monitor = SensorMonitor(windowCapacity: 30, provider: { provider.next() })

        let s1 = monitor.tick()
        XCTAssertEqual(s1.average(for: .cpu)!, 60, accuracy: 1e-9)
        let s2 = monitor.tick()
        XCTAssertEqual(s2.average(for: .cpu)!, 65, accuracy: 1e-9) // mean(60,70)
    }
}
