import Foundation
import IOKit

/// 芯片真实硬件拓扑。
///
/// 核心数来自系统接口，**不是**从 SMC 温度键倒推——这是「展开面板里 CPU/GPU
/// 个数和实际对不上」的根因修复。
///
/// 背景（实测教训，Mac mini M4 / Mac16,10）：Apple Silicon 一个物理核簇会暴露
/// 多个 SMC 温度探测点（die / proximity / uncore…），键名后缀是探测点编号而非
/// 「第几个核」。用温度键数量当核数必然对不上——该机型 P 簇实测 18 个 `Tp*` 键，
/// 对应却只有 4 个 P 核。因此核数改由系统接口读取：P/E 走 `sysctl` 的 perflevel，
/// GPU 走 IORegistry，SMC 温度键只用于给已知部件贴温度，不再参与数核。
public struct ChipTopology: Equatable, Sendable {
    public let chipName: String
    public let performanceCores: Int
    public let efficiencyCores: Int
    public let gpuCores: Int

    public init(chipName: String, performanceCores: Int, efficiencyCores: Int, gpuCores: Int) {
        self.chipName = chipName
        self.performanceCores = performanceCores
        self.efficiencyCores = efficiencyCores
        self.gpuCores = gpuCores
    }

    /// 逻辑 CPU 核心总数（性能核 + 能效核）。
    public var totalCPUCores: Int { performanceCores + efficiencyCores }
}

/// 拓扑信息来源。抽成协议便于单测注入假数据（无需真机 / root）。
public protocol TopologyProviding {
    func read() -> ChipTopology?
}

/// 真实实现：`sysctl` + IOKit。任意一项读取失败都降级为 0 或整体 nil，不抛错。
public struct SystemTopologyProbe: TopologyProviding {
    public init() {}

    public func read() -> ChipTopology? {
        let p = Sysctl.int("hw.perflevel0.physicalcpu")
        let e = Sysctl.int("hw.perflevel1.physicalcpu")

        let performanceCores: Int
        let efficiencyCores: Int
        if let p, let e, (p + e) > 0 {
            performanceCores = p
            efficiencyCores = e
        } else if let total = Sysctl.int("hw.physicalcpu"), total > 0 {
            // 理论只会发生在非 perflevel 机型；整批当作性能核，避免拓扑缺失
            performanceCores = total
            efficiencyCores = 0
        } else {
            return nil
        }

        let gpuCores = Self.gpuCoreCount() ?? 0
        let chipName = Sysctl.string("machdep.cpu.brand_string") ?? "—"
        return ChipTopology(
            chipName: chipName,
            performanceCores: performanceCores,
            efficiencyCores: efficiencyCores,
            gpuCores: gpuCores
        )
    }

    /// 从 IORegistry 的 `AGXAccelerator` 读 `gpu-core-count`。读不到返回 nil。
    ///
    /// Mac mini M4 实测该节点存在 `"gpu-core-count" = 10`（另有
    /// `GPUConfigurationVariable.num_cores = 10`），即单 GPU 的 10 个核心。
    private static func gpuCoreCount() -> Int? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AGXAccelerator"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = unmanaged?.takeRetainedValue() as? [String: Any] else {
            return nil
        }
        return props["gpu-core-count"] as? Int
    }
}
