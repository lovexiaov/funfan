import Foundation

/// 统一错误类型。GUI 侧将 4xx 类映射为「不重试」，5xx 类最多重试 3 次。
public enum FunFanError: Error, Equatable, Sendable {
    /// 打开 AppleSMC 连接被拒（通常发生在写操作缺 root，或系统策略拦截）。
    case smcAccessDenied
    /// 指定 SMC 键不存在于当前机型。
    case keyNotFound(String)
    /// GetKeyInfo 返回的数据类型不受支持。
    case dataTypeUnsupported(String)
    /// 解码失败（原始字节与类型不匹配）。
    case decodeFailed(key: String, type: String)
    /// M3/M4 的 `thermalmonitord` 拒绝手动写入（未解锁或解锁失效）。
    case thermalManagerRefused
    /// 特权 helper 不可用 / 未授权。
    case helperUnavailable
    /// 目标转速非法（如 0 或越界）。
    case invalidTargetRpm(Int)
}
