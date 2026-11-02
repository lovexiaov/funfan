import Foundation

/// SMC 温度采样源（`SensorMonitor` 的真实数据来源）。
///
/// 设计要点：
/// - **键表只枚举一次并缓存**：全键枚举在真机上约 1369 个键 / 10–30 ms，
///   若每 0.5 s 重做会白烧 CPU，与「轻量」目标冲突；
/// - 每周期只读缓存的温度键，并做 5–131℃ 合理性过滤；
/// - **两层采样（可选，M14）**：`fullScanEvery > 1` 时，每 N 帧做一次全量扫描
///   并缓存各键读数；快帧只真读「上轮全扫中每类最热 K 个键」（温度慢变量，
///   最热的键大概率还是最热的），其余键复用缓存。**输出形状与全量一致**——
///   消费方（均温 / hottest / 明细列表）零改动，代价只是非白名单键最多
///   陈旧 N−1 帧。hottest 因此保守不回退（缓存值兜底）；
/// - 单键读失败（睡眠唤醒偶发超时）跳过，不拖垮整次采样；
/// - 枚举失败不清空已有键表、下一周期自动重试；机型/系统变化时调 `invalidateKeyCache()`。
public final class SMCTemperatureProvider {

    private let keyLister: () throws -> [String]
    private let reader: (String) throws -> Double

    private var descriptors: [SensorDescriptor]?

    /// 未按采样范围过滤的全量键表，只用来回答「这台机器有没有这类传感器」。
    ///
    /// 与 `descriptors` 分开存的原因：`descriptors` 已经滤掉 `.other` 等不采样的类别，
    /// 拿它数 `.other` 会一律得到 0——而本机恰恰有一批低温探测点（`Ta0p`/`TH0p`）
    /// 落在 `.other` 里，「有没有」和「采不采」是两件事。
    private var catalogDescriptors: [SensorDescriptor]?

    /// 需要采样的类别。默认排除 `.other`——真机上未识别传感器可达 50+ 个，
    /// 每个键都要 2 次 IPC，盲读全部会白烧 CPU（实测 180 键 ≈ 40 ms/帧）。
    private let includedCategories: Set<SensorCategory>

    /// 每 N 帧做一次全量扫描（1 = 每帧全量，旧行为）。
    /// 帧计数从 1 开始，第 1 帧恒为全量（白名单与缓存从全量数据建立）。
    private let fullScanEvery: Int

    /// 快帧白名单里每类保留的最热键数；该类键数 ≤ K 时整类保留。
    private let perCategoryHotKeys: Int

    /// 最近一次全量扫描的读数缓存（键名 → ℃），快帧复用。
    private var fullScanCache: [String: Double] = [:]

    /// 快帧真读的白名单键。仅在全量扫描时重建。
    private var whitelist: Set<String> = []

    /// 帧计数器（从 1 开始；`fullScanEvery` 用它决定本帧是否全量）。
    private var frameIndex = 0

    /// 合理温度区间（℃）。低于下限多为未初始化（0），高于上限明显异常。
    private static let validRange: ClosedRange<Double> = 5...131

    /// 默认采样范围：除 `.other` 外的全部已知类别。
    public static let defaultCategories: Set<SensorCategory> =
        Set(SensorCategory.allCases).subtracting([.other])

    /// - Parameters:
    ///   - keyLister: 返回 SMC 全部键名（真机为 `SMCService.allKeys()`）。
    ///   - reader: 按键名读取数值（真机为 `SMCService.readKey(_:)`）。
    ///   - includedCategories: 需要采样的类别，默认 `defaultCategories`。
    ///   - fullScanEvery: 每 N 帧全量扫描一次，快帧读热键白名单 + 缓存合并；
    ///     1（默认）= 每帧全量，与两层采样引入前的行为完全一致。
    ///   - perCategoryHotKeys: 快帧白名单每类保留的最热键数（≥ 1 才有意义）。
    public init(
        keyLister: @escaping () throws -> [String],
        reader: @escaping (String) throws -> Double,
        includedCategories: Set<SensorCategory> = SMCTemperatureProvider.defaultCategories,
        fullScanEvery: Int = 1,
        perCategoryHotKeys: Int = 4
    ) {
        self.keyLister = keyLister
        self.reader = reader
        self.includedCategories = includedCategories
        self.fullScanEvery = fullScanEvery
        self.perCategoryHotKeys = perCategoryHotKeys
    }

    /// 用真实 `SMCService` 构造（读操作免 root）。
    public convenience init(
        service: SMCService,
        fullScanEvery: Int = 1,
        perCategoryHotKeys: Int = 4
    ) {
        self.init(
            keyLister: { try service.allKeys() },
            reader: { try service.readKey($0) },
            fullScanEvery: fullScanEvery,
            perCategoryHotKeys: perCategoryHotKeys
        )
    }

    /// 丢弃缓存的键表（重连 SMC、睡眠唤醒、机型变化后调用）。
    ///
    /// 两层采样的读数缓存与白名单一并作废：键表都变了，旧缓存不可信，
    /// 下一帧由 `fullScanCache.isEmpty` 兜底强制回到全量扫描。
    public func invalidateKeyCache() {
        descriptors = nil
        catalogDescriptors = nil
        fullScanCache = [:]
        whitelist = []
    }

    /// 当前已确认的传感器描述（未枚举时为空）。
    public var knownDescriptors: [SensorDescriptor] {
        descriptors ?? []
    }

    /// 本机某类别的传感器个数；键表尚未枚举（或枚举失败）时返回 `nil`。
    ///
    /// `nil` 与 `0` 必须分开用：`nil` 是「还不知道」，`0` 才是「这台机器确实没有」。
    /// UI 拿它区分「本来就读不到」和「这一刻还没读到」（见 `SensorAvailability`）。
    public func sensorCount(for category: SensorCategory) -> Int? {
        guard let catalogDescriptors else { return nil }
        return catalogDescriptors.reduce(0) { $0 + ($1.category == category ? 1 : 0) }
    }

    /// 读取一轮温度。首次调用会枚举键表；之后复用缓存。
    ///
    /// `fullScanEvery > 1` 时按两层采样：全量帧真读全部键并重建缓存/白名单，
    /// 快帧真读白名单键、其余键复用最近一次全量的读数。两种帧的输出形状一致。
    public func readings() -> [SensorReading] {
        guard let descriptors = resolveDescriptors() else { return [] }
        frameIndex += 1

        // 全量判定：旧行为、缓存为空（首帧/失效重建/上轮全量全军覆没）、或到达周期。
        // 帧号 1, 1+N, 1+2N… 为全量帧，中间 N−1 帧为快帧。
        let needsFullScan = fullScanEvery <= 1
            || fullScanCache.isEmpty
            || (frameIndex - 1) % fullScanEvery == 0

        if needsFullScan {
            let full = readAll(descriptors)
            var cache: [String: Double] = [:]
            cache.reserveCapacity(full.count)
            for reading in full { cache[reading.descriptor.key] = reading.celsius }
            fullScanCache = cache
            whitelist = Self.hotKeyWhitelist(in: full, perCategory: perCategoryHotKeys)
            return full
        }

        // 快帧：白名单键真读拿新值；其余键复用缓存（读失败/越界的键上轮就没有
        // 缓存，本帧跳过——与全量帧对单键失败的处理一致）。
        var result: [SensorReading] = []
        result.reserveCapacity(descriptors.count)
        for descriptor in descriptors {
            if whitelist.contains(descriptor.key) {
                guard let value = try? reader(descriptor.key) else { continue }
                guard Self.validRange.contains(value) else { continue }
                result.append(SensorReading(descriptor: descriptor, celsius: value))
            } else if let cached = fullScanCache[descriptor.key] {
                result.append(SensorReading(descriptor: descriptor, celsius: cached))
            }
        }
        return result
    }

    /// 全量读取（两层采样的全量帧与旧行为共用这段循环）。
    private func readAll(_ descriptors: [SensorDescriptor]) -> [SensorReading] {
        var result: [SensorReading] = []
        result.reserveCapacity(descriptors.count)
        for descriptor in descriptors {
            guard let value = try? reader(descriptor.key) else { continue }
            guard Self.validRange.contains(value) else { continue }
            result.append(SensorReading(descriptor: descriptor, celsius: value))
        }
        return result
    }

    /// 从一轮全量读数里选出快帧白名单：每类最热 K 个键。
    ///
    /// 依据「温度是慢变量」：这轮最热的键，下 N−1 帧大概率还是最热的；
    /// 键数 ≤ K 的类别整类保留（如 GPU 常只有几个键，全读也不贵）。
    private static func hotKeyWhitelist(in readings: [SensorReading], perCategory k: Int) -> Set<String> {
        guard k >= 1 else { return [] }
        var byCategory: [SensorCategory: [SensorReading]] = [:]
        for reading in readings {
            byCategory[reading.descriptor.category, default: []].append(reading)
        }
        var keys = Set<String>()
        for group in byCategory.values {
            for reading in group.sorted(by: { $0.celsius > $1.celsius }).prefix(k) {
                keys.insert(reading.descriptor.key)
            }
        }
        return keys
    }

    // MARK: - 键表

    private func resolveDescriptors() -> [SensorDescriptor]? {
        if let cached = descriptors { return cached }

        guard let keys = try? keyLister() else { return nil }   // 失败：下周期重试
        let discovered = SensorCatalog.descriptors(
            forKeys: SensorCatalog.temperatureKeys(fromAllKeys: keys)
        )

        // 空结果也缓存，避免对「本机确实无温度键」的机型反复枚举；
        // 真正需要重试的场景（枚举抛错）已在上面返回 nil。
        catalogDescriptors = discovered
        descriptors = discovered.filter { includedCategories.contains($0.category) }
        return descriptors
    }
}
