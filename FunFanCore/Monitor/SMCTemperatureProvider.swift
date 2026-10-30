import Foundation

/// SMC 温度采样源（`SensorMonitor` 的真实数据来源）。
///
/// 设计要点：
/// - **键表只枚举一次并缓存**：全键枚举在真机上约 1369 个键 / 10–30 ms，
///   若每 0.5 s 重做会白烧 CPU，与「轻量」目标冲突；
/// - 每周期只读缓存的温度键，并做 5–131℃ 合理性过滤；
/// - 单键读失败（睡眠唤醒偶发超时）跳过，不拖垮整次采样；
/// - 枚举失败不清空已有键表、下一周期自动重试；机型/系统变化时调 `invalidateKeyCache()`。
public final class SMCTemperatureProvider {

    private let keyLister: () throws -> [String]
    private let reader: (String) throws -> Double

    private var descriptors: [SensorDescriptor]?

    /// 需要采样的类别。默认排除 `.other`——真机上未识别传感器可达 50+ 个，
    /// 每个键都要 2 次 IPC，盲读全部会白烧 CPU（实测 180 键 ≈ 40 ms/帧）。
    private let includedCategories: Set<SensorCategory>

    /// 合理温度区间（℃）。低于下限多为未初始化（0），高于上限明显异常。
    private static let validRange: ClosedRange<Double> = 5...131

    /// 默认采样范围：除 `.other` 外的全部已知类别。
    public static let defaultCategories: Set<SensorCategory> =
        Set(SensorCategory.allCases).subtracting([.other])

    /// - Parameters:
    ///   - keyLister: 返回 SMC 全部键名（真机为 `SMCService.allKeys()`）。
    ///   - reader: 按键名读取数值（真机为 `SMCService.readKey(_:)`）。
    ///   - includedCategories: 需要采样的类别，默认 `defaultCategories`。
    public init(
        keyLister: @escaping () throws -> [String],
        reader: @escaping (String) throws -> Double,
        includedCategories: Set<SensorCategory> = SMCTemperatureProvider.defaultCategories
    ) {
        self.keyLister = keyLister
        self.reader = reader
        self.includedCategories = includedCategories
    }

    /// 用真实 `SMCService` 构造（读操作免 root）。
    public convenience init(service: SMCService) {
        self.init(keyLister: { try service.allKeys() }, reader: { try service.readKey($0) })
    }

    /// 丢弃缓存的键表（重连 SMC、睡眠唤醒、机型变化后调用）。
    public func invalidateKeyCache() {
        descriptors = nil
    }

    /// 当前已确认的传感器描述（未枚举时为空）。
    public var knownDescriptors: [SensorDescriptor] {
        descriptors ?? []
    }

    /// 读取一轮温度。首次调用会枚举键表；之后复用缓存。
    public func readings() -> [SensorReading] {
        guard let descriptors = resolveDescriptors() else { return [] }

        var result: [SensorReading] = []
        result.reserveCapacity(descriptors.count)

        for descriptor in descriptors {
            guard let value = try? reader(descriptor.key) else { continue }
            guard Self.validRange.contains(value) else { continue }
            result.append(SensorReading(descriptor: descriptor, celsius: value))
        }
        return result
    }

    // MARK: - 键表

    private func resolveDescriptors() -> [SensorDescriptor]? {
        if let cached = descriptors { return cached }

        guard let keys = try? keyLister() else { return nil }   // 失败：下周期重试
        let discovered = SensorCatalog.descriptors(
            forKeys: SensorCatalog.temperatureKeys(fromAllKeys: keys)
        )
        .filter { includedCategories.contains($0.category) }

        // 空结果也缓存，避免对「本机确实无温度键」的机型反复枚举；
        // 真正需要重试的场景（枚举抛错）已在上面返回 nil。
        descriptors = discovered
        return discovered
    }
}
