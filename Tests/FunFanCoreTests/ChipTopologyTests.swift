import XCTest
import FunFanCore

final class ChipTopologyTests: XCTestCase {

    /// totalCPUCores 必须等同于性能核 + 能效核，UI 才会显示正确总数。
    func testTotalCPUCoresSumsPerformanceAndEfficiency() {
        let topo = ChipTopology(chipName: "Apple M4", performanceCores: 4, efficiencyCores: 6, gpuCores: 10)
        XCTAssertEqual(topo.totalCPUCores, 10)
    }

    /// 消费方（如 MonitorStore）通过协议拿到注入的拓扑，验证可注入、可单测。
    func testReadViaFakeProbeReturnsInjectedTopology() {
        let fake = FakeTopology(performanceCores: 4, efficiencyCores: 6, gpuCores: 10)
        guard let topo = fake.read() else { return XCTFail("假 probe 必须返回拓扑") }
        XCTAssertEqual(topo.performanceCores, 4)
        XCTAssertEqual(topo.efficiencyCores, 6)
        XCTAssertEqual(topo.gpuCores, 10)
        XCTAssertEqual(topo.totalCPUCores, 10)
    }

    /// 真实探针在正常 macOS 上应能从系统接口读到拓扑，且核心数自洽。
    /// 不写死具体机型数值（CI runner 芯片不同），只断言不变量。
    func testRealProbeReadsActualHardwareOnMac() throws {
        #if os(macOS)
        let topo = SystemTopologyProbe().read()
        let t = try XCTUnwrap(topo, "本机应能从 sysctl/IORegistry 读到拓扑")
        XCTAssertGreaterThan(t.performanceCores, 0, "性能核数必须 > 0")
        XCTAssertGreaterThanOrEqual(t.efficiencyCores, 0)
        XCTAssertGreaterThanOrEqual(t.gpuCores, 0)
        XCTAssertEqual(t.totalCPUCores, t.performanceCores + t.efficiencyCores)
        #else
        throw XCTSkip("仅 macOS 可验证真实硬件拓扑")
        #endif
    }
}

private struct FakeTopology: TopologyProviding {
    let performanceCores: Int
    let efficiencyCores: Int
    let gpuCores: Int
    func read() -> ChipTopology? {
        ChipTopology(
            chipName: "Fake",
            performanceCores: performanceCores,
            efficiencyCores: efficiencyCores,
            gpuCores: gpuCores
        )
    }
}
