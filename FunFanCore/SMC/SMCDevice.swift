import Foundation

/// SMC 设备抽象。
///
/// 把「读写 SMC」与「怎么控制风扇」解耦：
/// - 生产实现是 `SMCService`（真实 IOKit 连接）；
/// - 单测实现是内存字典，可在不碰硬件的前提下验证完整控制流程。
///
/// 有了这层抽象，M4 的解锁序列/模式切换/收敛校验才能被 TDD 覆盖。
public protocol SMCDevice: AnyObject {
    /// 键是否存在于当前机型（内部会探测并缓存键信息）。
    func keyExists(_ key: String) -> Bool
    /// 读取键信息（类型/长度）。
    func keyInfo(_ key: String) throws -> SMCKeyInfo
    /// 读取键值（按类型解码）。
    func readKey(_ key: String) throws -> Double
    /// 写入键值（按类型编码）。需要 root，由特权进程调用。
    func writeKey(_ key: String, value: Double) throws
}
