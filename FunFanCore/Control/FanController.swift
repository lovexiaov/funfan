import Foundation

/// 风扇控制器（GUI 侧）：只负责「把意图翻译成 XPC 请求」，不直接碰 SMC。
///
/// 安全职责：
/// - 已知上下限时**本地预检**非法目标，避免一次无谓 IPC（也让错误尽早暴露）；
/// - helper 侧仍会二次校验（`SafetyPolicy.isValidTarget`），GUI 被绕过也不至于写坏。
public final class FanController {

    private let transport: FanControlTransport
    /// 最近一次读到的风扇状态，用于本地预检。
    private var cache: [Int: FanState] = [:]

    public init(transport: FanControlTransport) {
        self.transport = transport
    }

    // MARK: - 读

    @discardableResult
    public func refreshState(fanIndex: Int = 0) throws -> FanState {
        let reply = try transport.send(.queryState(fanIndex: fanIndex))
        let state = try Self.state(from: reply, fanIndex: fanIndex)
        cache[fanIndex] = state
        return state
    }

    @discardableResult
    public func listFans() throws -> [FanState] {
        let reply = try transport.send(.listFans)
        guard case .states(let states) = reply else {
            throw Self.error(from: reply) ?? FunFanError.helperUnavailable
        }
        for state in states { cache[state.index] = state }
        return states
    }

    /// 已知上下限（做过一次 `refreshState` 后可用）。
    public func cachedLimits(for fanIndex: Int) -> FanLimits? {
        cache[fanIndex]?.limits
    }

    // MARK: - 写

    /// 下发目标转速。`rpm` 必须是系统允许区间内的值。
    @discardableResult
    public func setTarget(rpm: Double, fanIndex: Int = 0) throws -> FanState {
        if let limits = cachedLimits(for: fanIndex), !SafetyPolicy.isValidTarget(rpm, limits: limits) {
            throw FunFanError.invalidTargetRpm(Int(rpm.rounded()))
        }

        let reply = try transport.send(.setTargetRpm(fanIndex: fanIndex, rpm: rpm))
        let state = try Self.state(from: reply, fanIndex: fanIndex)
        cache[fanIndex] = state
        return state
    }

    /// 返还系统自动控制（退出/合盖/睡眠/出错时必须调用）。
    public func restoreAuto(fanIndex: Int = 0) throws {
        let reply = try transport.send(.restoreAuto(fanIndex: fanIndex))
        if case .failed(let payload) = reply {
            throw payload.error ?? FunFanError.helperUnavailable
        }
        cache[fanIndex] = nil
    }

    // MARK: - 应答解析

    private static func state(from reply: FanControlReply, fanIndex: Int) throws -> FanState {
        switch reply {
        case .acknowledged(let state):
            return state
        case .states(let states):
            guard let state = states.first(where: { $0.index == fanIndex }) ?? states.first else {
                throw FunFanError.helperUnavailable
            }
            return state
        case .failed(let payload):
            throw payload.error ?? FunFanError.helperUnavailable
        }
    }

    private static func error(from reply: FanControlReply) -> FunFanError? {
        guard case .failed(let payload) = reply else { return nil }
        return payload.error ?? FunFanError.helperUnavailable
    }
}
