import Foundation

/// 风扇当前模式。
public enum FanMode: String, Codable, Equatable, Sendable {
    /// 系统自动（macOS 自己控制）。
    case automatic
    /// 手动固定转速。
    case manualFixed
    /// 手动曲线。
    case manualCurve
    /// 手动规则。
    case manualRules
    /// 机型不支持/未知。
    case unknown
}

/// 单个风扇的状态快照（跨进程传输）。
public struct FanState: Codable, Equatable, Sendable {
    public let index: Int
    /// 实际转速（`F0Ac`）。
    public let actualRpm: Double
    /// 目标转速（`F0Tg`）。
    public let targetRpm: Double
    /// 系统最小（`F0Mn`，只读）。
    public let minRpm: Double
    /// 系统最大（`F0Mx`，只读）。
    public let maxRpm: Double
    public let mode: FanMode
    /// 是否处于手动接管状态。
    public let isManual: Bool

    public init(
        index: Int,
        actualRpm: Double,
        targetRpm: Double,
        minRpm: Double,
        maxRpm: Double,
        mode: FanMode,
        isManual: Bool
    ) {
        self.index = index
        self.actualRpm = actualRpm
        self.targetRpm = targetRpm
        self.minRpm = minRpm
        self.maxRpm = maxRpm
        self.mode = mode
        self.isManual = isManual
    }

    public var limits: FanLimits {
        FanLimits(minRpm: minRpm, maxRpm: maxRpm)
    }
}

/// GUI → helper 的请求。
public enum FanControlRequest: Codable, Equatable, Sendable {
    case listFans
    case queryState(fanIndex: Int)
    case setTargetRpm(fanIndex: Int, rpm: Double)
    case setMode(fanIndex: Int, mode: FanMode)
    case restoreAuto(fanIndex: Int)
}

/// helper → GUI 的应答。
public enum FanControlReply: Codable, Equatable, Sendable {
    case states([FanState])
    case acknowledged(FanState)
    case failed(FanControlErrorPayload)
}

/// 可跨进程传输的错误描述。
///
/// `FunFanError` 带关联值且不直接 Codable，故用 `code + detail` 表达，
/// 接收侧 `error` 属性可尽力还原成 `FunFanError`。
public struct FanControlErrorPayload: Codable, Equatable, Sendable {
    public let code: String
    public let message: String
    public let detail: String?

    public init(code: String, message: String, detail: String? = nil) {
        self.code = code
        self.message = message
        self.detail = detail
    }

    public init(error: FunFanError) {
        switch error {
        case .smcAccessDenied:
            self.init(code: "smcAccessDenied", message: "AppleSMC 访问被拒绝（写操作需 root 或系统策略拦截）")
        case .keyNotFound(let key):
            self.init(code: "keyNotFound", message: "当前机型不存在该 SMC 键", detail: key)
        case .dataTypeUnsupported(let type):
            self.init(code: "dataTypeUnsupported", message: "不支持的数据类型", detail: type)
        case .decodeFailed(let key, let type):
            self.init(code: "decodeFailed", message: "解码失败", detail: "\(key)|\(type)")
        case .thermalManagerRefused:
            self.init(code: "thermalManagerRefused", message: "thermalmonitord 拒绝手动写入（未解锁或解锁失效）")
        case .helperUnavailable:
            self.init(code: "helperUnavailable", message: "特权 helper 不可用或未授权")
        case .invalidTargetRpm(let rpm):
            self.init(code: "invalidTargetRpm", message: "目标转速非法", detail: String(rpm))
        }
    }

    /// 尽力还原为 `FunFanError`（未知 code 返回 nil）。
    public var error: FunFanError? {
        switch code {
        case "smcAccessDenied": return .smcAccessDenied
        case "keyNotFound": return detail.map(FunFanError.keyNotFound)
        case "dataTypeUnsupported": return detail.map(FunFanError.dataTypeUnsupported)
        case "decodeFailed":
            let parts = (detail ?? "").split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            return .decodeFailed(key: parts[0], type: parts[1])
        case "thermalManagerRefused": return .thermalManagerRefused
        case "helperUnavailable": return .helperUnavailable
        case "invalidTargetRpm": return detail.flatMap(Int.init).map(FunFanError.invalidTargetRpm)
        default: return nil
        }
    }
}

/// 传输抽象：真实实现走 XPC（M4），单测用 mock。
public protocol FanControlTransport {
    func send(_ request: FanControlRequest) throws -> FanControlReply
}
