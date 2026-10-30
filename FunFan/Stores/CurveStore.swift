import Foundation
import Combine
import FunFanCore

/// 曲线的 UI 侧数据源：编辑 + 立即持久化 + 供控制层线程安全读取。
///
/// 两条设计约束：
/// 1. **拖动不能让控制点越过邻居**——曲线是温度→转速的单值映射，一旦出现
///    「两个点温度相同」，插值就失去意义（`FanCurve.rpm(at:)` 会走除零分支）。
///    因此在 `movePoint` 里把 x 夹在左右邻居之间，而不是拖完再排序。
/// 2. **预设与自定义要能区分**：用户套了「均衡」但还没动手时，换机型（风扇区间变了）
///    应该自动重新展开；一旦他拖过任何一个点，就变成自定义，不再跟着区间走。
final class CurveStore: ObservableObject {

    @Published private(set) var curve: FanCurve

    /// 当前曲线是否仍等价于某个预设（nil = 用户自定义）。
    @Published private(set) var preset: CurvePreset?

    private let persistence: CurvePersistence
    private let lock = NSLock()
    private var cache: FanCurve
    private var limits: FanLimits

    /// 未知真实区间时的兜底（Mac mini 量级），仅用于首次展开预设。
    static let fallbackLimits = FanLimits(minRpm: 1000, maxRpm: 4900)

    init(
        persistence: CurvePersistence = CurvePersistence(fileURL: CurvePersistence.defaultFileURL()),
        limits: FanLimits = CurveStore.fallbackLimits
    ) {
        self.persistence = persistence
        self.limits = limits

        let initial: FanCurve
        let initialPreset: CurvePreset?
        if let loaded = persistence.load() {
            initial = loaded
            initialPreset = CurvePreset.matching(loaded, limits: limits)
        } else {
            initial = CurvePreset.balanced.curve(limits: limits)
            initialPreset = .balanced
        }

        self.curve = initial
        self.preset = initialPreset
        self.cache = initial
    }

    // MARK: - 读取

    /// 控制层（后台队列）读取用，避免跨线程读 `@Published`。
    func currentCurve() -> FanCurve {
        lock.lock()
        defer { lock.unlock() }
        return cache
    }

    /// 真实风扇区间到达（helper 连上）时调用。
    ///
    /// 只在「仍等于预设」时按新区间重排；用户自定义过的曲线绝不能被悄悄改数值。
    func updateLimits(_ newLimits: FanLimits) {
        guard newLimits.isUsable, newLimits != limits else { return }
        let wasPreset = preset
        // 用旧区间下的形状判定是不是预设（用户可能刚从文件恢复一条均衡曲线）
        let stillPreset = wasPreset ?? CurvePreset.matching(curve, limits: limits)
        limits = newLimits

        guard let matched = stillPreset else { return }
        curve = matched.curve(limits: newLimits)
        preset = matched
        commit()
    }

    // MARK: - 编辑

    func apply(_ preset: CurvePreset, limits: FanLimits) {
        self.limits = limits.isUsable ? limits : self.limits
        curve = preset.curve(limits: self.limits)
        self.preset = preset
        commit()
    }

    /// 拖动某个控制点。x 夹在左右邻居之间（留 `minGapCelsius` 间隔）。
    func movePoint(index: Int, celsius: Double, rpm: Double) {
        var points = curve.points
        guard points.indices.contains(index) else { return }

        let lowerBound = index > 0
            ? points[index - 1].celsius + CurvePersistence.minGapCelsius
            : CurvePersistence.celsiusRange.lowerBound
        let upperBound = index < points.count - 1
            ? points[index + 1].celsius - CurvePersistence.minGapCelsius
            : CurvePersistence.celsiusRange.upperBound

        // 邻居把空间挤没了（控制点过密）时，保持原位而不是翻转
        guard lowerBound <= upperBound else { return }

        let clampedCelsius = min(max(celsius, lowerBound), upperBound)
        // 0.5℃ / 10 RPM 步进：再细的差别 SMC 侧也体现不出来，只会让界面数字乱跳
        let snappedCelsius = (clampedCelsius * 2).rounded() / 2
        let clampedRpm = min(max(rpm, limits.minRpm), limits.normalizedMax)
        let snappedRpm = (clampedRpm / 10).rounded() * 10

        points[index] = CurvePoint(celsius: snappedCelsius, rpm: snappedRpm)
        curve = FanCurve(points: points)
        preset = nil
        commit()
    }

    /// 在指定温度插入控制点；与已有点过近或数量已达上限时返回 false。
    @discardableResult
    func addPoint(celsius: Double, rpm: Double) -> Bool {
        var points = curve.points
        guard points.count < CurvePersistence.maxPoints else { return false }
        let tooClose = points.contains { abs($0.celsius - celsius) < CurvePersistence.minGapCelsius * 2 }
        guard !tooClose else { return false }

        let clampedCelsius = min(
            max(celsius, CurvePersistence.celsiusRange.lowerBound),
            CurvePersistence.celsiusRange.upperBound
        )
        let clampedRpm = min(max(rpm, limits.minRpm), limits.normalizedMax)
        points.append(CurvePoint(celsius: clampedCelsius, rpm: (clampedRpm / 10).rounded() * 10))
        curve = FanCurve(points: points)
        preset = nil
        commit()
        return true
    }

    /// 删除控制点。少于 2 个点就不再是曲线，拒绝删除。
    @discardableResult
    func removePoint(index: Int) -> Bool {
        guard curve.points.count > 2, curve.points.indices.contains(index) else { return false }
        var points = curve.points
        points.remove(at: index)
        curve = FanCurve(points: points)
        preset = nil
        commit()
        return true
    }

    /// 恢复成「均衡」预设。
    func resetToBalanced() {
        apply(.balanced, limits: limits)
    }

    // MARK: - 持久化

    private func commit() {
        lock.lock()
        cache = curve
        lock.unlock()
        do {
            try persistence.save(curve)
        } catch {
            // 写盘失败不该让 UI 崩溃；内存态仍然生效
            NSLog("FunFan: 曲线保存失败 \(error)")
        }
    }
}
