import Foundation

/// 单台风机的可控制性探测结果。
public struct FanProbe: Equatable, Sendable {
    public let index: Int
    /// 实际存在的模式键（`F0Md` 或 `F0md`）；`nil` 表示该机型不支持手动控制。
    public let modeKey: String?
    /// 是否为 M3/M4 式「需要 Ftst 解锁」的机型。
    public let hasFtst: Bool

    public init(index: Int, modeKey: String?, hasFtst: Bool) {
        self.index = index
        self.modeKey = modeKey
        self.hasFtst = hasFtst
    }

    public var supportsManualControl: Bool { modeKey != nil }
}

/// 真实风扇硬件驱动：把「意图」翻译成 SMC 写入序列。
///
/// 只做硬件层的事，不含策略（曲线/规则由 `CurveEngine` / `RuleEngine` 决定）。
/// 依赖 `SMCDevice` 抽象，因此全流程可单测，不必真机 root。
///
/// 写入序列（顺序不可调换）：
/// 1. `unlockIfNeeded()` —— `Ftst` 存在时写 1（thermalmonitord 会回收，故每次下发都重断言）
/// 2. `enterManual()` —— 探测到的模式键写 1
/// 3. 写 `F0Tg` 目标转速（clamp 到 `F0Mn–F0Mx`）
/// 返还：只写模式键 0，**绝不写 `F0Tg`**（让系统自己接管）。
public final class FanHardwareDriver {

    private let device: SMCDevice
    private let sleep: (TimeInterval) -> Void

    public init(device: SMCDevice, sleep: @escaping (TimeInterval) -> Void = Thread.sleep) {
        self.device = device
        self.sleep = sleep
    }

    // MARK: - 探测

    /// 探测单台风机的模式键与解锁键（绝不假设键名）。
    public func probe(fanIndex: Int = 0) -> FanProbe {
        let modeKey = SMCKeyName.fanModeCandidates(fanIndex).first { device.keyExists($0) }
        return FanProbe(
            index: fanIndex,
            modeKey: modeKey,
            hasFtst: device.keyExists(SMCKeyName.ftst)
        )
    }

    /// 风扇数量（无风扇机型返回 0）。
    public func fanCount() -> Int {
        guard let raw = try? device.readKey(SMCKeyName.fanCount), raw.isFinite else { return 0 }
        return max(0, Int(raw))
    }

    // MARK: - 解锁

    /// `Ftst` 存在则写入解锁标记；返回是否真的执行了解锁。
    ///
    /// 本机实测（M4 级）`Ftst` 不存在，此时直接写 `F0Tg` 即可——
    /// 因此这里必须是「探测到才解锁，探测不到直写」，不能写死。
    @discardableResult
    public func unlockIfNeeded() throws -> Bool {
        guard device.keyExists(SMCKeyName.ftst) else { return false }
        try device.writeKey(SMCKeyName.ftst, value: 1)
        return true
    }

    // MARK: - 模式

    /// 切到手动模式。
    public func enterManual(fanIndex: Int = 0) throws {
        guard let modeKey = probe(fanIndex: fanIndex).modeKey else {
            // 组合键名便于诊断：两个候选都不存在
            throw FunFanError.keyNotFound(
                SMCKeyName.fanModeCandidates(fanIndex).joined(separator: "|")
            )
        }
        try device.writeKey(modeKey, value: 1)
    }

    /// 返还系统自动控制（退出/合盖/睡眠/租约过期时必须调用）。
    public func restoreAuto(fanIndex: Int = 0) throws {
        guard let modeKey = probe(fanIndex: fanIndex).modeKey else {
            throw FunFanError.keyNotFound(
                SMCKeyName.fanModeCandidates(fanIndex).joined(separator: "|")
            )
        }
        try device.writeKey(modeKey, value: 0)
    }

    // MARK: - 设目标

    /// 下发目标转速。`rpm` 必须为正；会被 clamp 到系统区间。
    ///
    /// - Parameter dieCelsius: 提供时额外套用「动态安全下限」（只能更快，不能更慢）。
    @discardableResult
    public func setTarget(
        fanIndex: Int = 0,
        rpm: Double,
        limits: FanLimits,
        dieCelsius: Double? = nil
    ) throws -> FanState {
        guard rpm.isFinite, rpm > 0 else { throw FunFanError.invalidTargetRpm(Int(rpm.rounded())) }
        guard limits.isUsable else { throw FunFanError.invalidTargetRpm(Int(rpm.rounded())) }

        let clamped: Double
        if let die = dieCelsius {
            clamped = SafetyPolicy.clamp(rpm, dieCelsius: die, limits: limits)
        } else {
            clamped = min(max(rpm, limits.minRpm), limits.normalizedMax)
        }

        try unlockIfNeeded()
        try enterManual(fanIndex: fanIndex)
        try device.writeKey(SMCKeyName.fanTarget(fanIndex), value: clamped)

        return try state(fanIndex: fanIndex)
    }

    // MARK: - 读状态

    public func state(fanIndex: Int = 0) throws -> FanState {
        let actual = (try? device.readKey(SMCKeyName.fanActual(fanIndex))) ?? 0
        let target = (try? device.readKey(SMCKeyName.fanTarget(fanIndex))) ?? 0
        let minimum = (try? device.readKey(SMCKeyName.fanMin(fanIndex))) ?? 0
        let maximum = (try? device.readKey(SMCKeyName.fanMax(fanIndex))) ?? 0

        let modeKey = probe(fanIndex: fanIndex).modeKey
        let modeValue = modeKey.flatMap { try? device.readKey($0) }

        let isManual = (modeValue ?? 0) != 0
        let mode: FanMode
        if modeKey == nil {
            mode = .unknown
        } else {
            mode = isManual ? .manualFixed : .automatic
        }

        return FanState(
            index: fanIndex,
            actualRpm: actual,
            targetRpm: target,
            minRpm: minimum,
            maxRpm: maximum,
            mode: mode,
            isManual: isManual
        )
    }

    // MARK: - 收敛校验

    /// 等待实际转速（`F0Ac`）收敛到目标附近。
    ///
    /// 风扇有物理惯性（约 1–3 s），写后立即读回必然不一致，
    /// 所以判定生效的依据是 `F0Ac` 收敛，而不是 `F0Tg` 立即回读。
    @discardableResult
    public func waitForConvergence(
        fanIndex: Int = 0,
        expected: Double,
        tolerance: Double = 150,
        timeout: TimeInterval = 5,
        pollInterval: TimeInterval = 0.25
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let actual = try? device.readKey(SMCKeyName.fanActual(fanIndex)),
               abs(actual - expected) <= tolerance {
                return true
            }
            if Date() >= deadline { return false }
            sleep(pollInterval)
        } while true
    }
}
