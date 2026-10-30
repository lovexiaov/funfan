import Foundation
import IOKit
import Darwin

/// AppleSMC 用户态访问服务。
///
/// 读操作任意进程可用（免 root）；写操作需 root（由特权 helper 调用）。
/// 本类型只负责「打开连接 + 收发 + 按键读取」，不包含任何控制/解锁逻辑。
public final class SMCService: SMCDevice {

    /// AppleSMC 的 YPC 事件 selector。
    private static let ypcEventSelector: UInt32 = 2

    private var connection: io_connect_t = 0

    /// 键信息缓存：`dataSize`/`dataType` 在一次开机内不变，
    /// 缓存后每次读值只需 1 次 IPC（不再先 `GetKeyInfo`），实测可省一半开销。
    private var keyInfoCache: [String: SMCKeyInfo] = [:]

    /// 累计 IPC 往返次数（诊断/性能回归用）。
    public private(set) var ipcCallCount = 0

    public init() {}

    deinit { close() }

    // MARK: - 连接生命周期

    public func open() throws {
        guard connection == 0 else { return }

        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSMC")
        )
        guard service != 0 else { throw FunFanError.smcAccessDenied }
        defer { IOObjectRelease(service) }

        var conn: io_connect_t = 0
        let kr = IOServiceOpen(service, mach_task_self_, 0, &conn)
        guard kr == kIOReturnSuccess, conn != 0 else {
            throw FunFanError.smcAccessDenied
        }
        connection = conn
    }

    public func close() {
        if connection != 0 {
            IOServiceClose(connection)
            connection = 0
        }
        keyInfoCache.removeAll()
    }

    public var isOpen: Bool { connection != 0 }

    // MARK: - 底层收发

    @discardableResult
    private func call(_ input: inout SMCParamStruct) throws -> SMCParamStruct {
        guard connection != 0 else { throw FunFanError.smcAccessDenied }

        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.size

        let kr = IOConnectCallStructMethod(
            connection,
            Self.ypcEventSelector,
            &input,
            MemoryLayout<SMCParamStruct>.size,
            &output,
            &outputSize
        )
        ipcCallCount += 1

        guard kr == kIOReturnSuccess else { throw FunFanError.smcAccessDenied }
        guard output.result == 0 else { throw FunFanError.smcAccessDenied }
        return output
    }

    // MARK: - 键信息

    /// 读取键信息（先 GetKeyInfo 再按类型解码，是关键工程约束）。
    ///
    /// 结果会缓存：键信息在一次开机内不变，缓存后读值只需 1 次 IPC。
    public func keyInfo(_ key: String) throws -> SMCKeyInfo {
        if let cached = keyInfoCache[key] { return cached }

        var input = SMCParamStruct()
        input.key = FourCC.encode(key)
        input.data8 = SMCCommand.getKeyInfo.rawValue

        let out = try call(&input)
        let type = FourCC.decode(out.keyInfo.dataType)
        let size = Int(out.keyInfo.dataSize)
        guard size > 0 else { throw FunFanError.keyNotFound(key) }

        let info = SMCKeyInfo(
            key: key,
            dataSize: size,
            dataType: type,
            dataAttributes: out.keyInfo.dataAttributes
        )
        keyInfoCache[key] = info
        return info
    }

    /// 清空键信息缓存（重连、睡眠唤醒、系统升级后调用）。
    public func invalidateKeyInfoCache() {
        keyInfoCache.removeAll()
    }

    public func keyExists(_ key: String) -> Bool {
        (try? keyInfo(key)) != nil
    }

    /// 按索引读取键名（`SMC_CMD_READ_INDEX`，即 `data8 = 8`、`data32 = index`）。
    public func keyName(at index: Int) throws -> String {
        var input = SMCParamStruct()
        input.data8 = SMCCommand.readIndex.rawValue
        input.data32 = UInt32(index)

        let out = try call(&input)
        return FourCC.decode(out.key)
    }

    /// 枚举 SMC 全部键名（三级回退第 2 级的基础能力）。
    ///
    /// 单索引失败会被跳过——真机上存在无效槽位，不应因此中断枚举。
    public func allKeys() throws -> [String] {
        let count = Int(try readKey(SMCKeyName.keyCount))
        return try SMCKeyEnumeration.allKeys(
            keyCount: { count },
            keyAt: { try self.keyName(at: $0) }
        )
    }

    /// 枚举全部温度键（`T*`），用于不依赖预置密钥表的传感器发现。
    public func temperatureKeys() throws -> [String] {
        SensorCatalog.temperatureKeys(fromAllKeys: try allKeys())
    }

    // MARK: - 读取

    /// 读取键的原始字节（不做任何解码）。
    ///
    /// 用于两类场景：诊断报告展示未知类型的实际字节，以及为新类型反向推断
    /// 字节序/定点位数（`ioft` 就是这么定下来的）。
    public func readRawBytes(_ key: String) throws -> [UInt8] {
        let info = try keyInfo(key)

        var input = SMCParamStruct()
        input.key = FourCC.encode(key)
        input.keyInfo.dataSize = UInt32(info.dataSize)
        input.data8 = SMCCommand.readBytes.rawValue

        let out = try call(&input)
        let rawBytes = withUnsafeBytes(of: out.bytes) { Array($0) }
        return Array(rawBytes.prefix(max(info.dataSize, 1)))
    }

    /// 读取键值并解码为 Double。风扇转速、温度均返回 Double。
    public func readKey(_ key: String) throws -> Double {
        let info = try keyInfo(key)
        let prefix = try readRawBytes(key)

        guard let value = SMCDataCodec.decode(type: info.dataType, bytes: prefix) else {
            throw FunFanError.decodeFailed(key: key, type: info.dataType)
        }
        return value
    }

    // MARK: - 写入

    /// 写入键值（需 root）。
    ///
    /// 关键约束：
    /// - 编码类型必须取 `GetKeyInfo` 的**真实类型**，不能按字节长度猜；
    /// - 编码结果长度必须等于键的 `dataSize`，否则固件会拒绝或截断。
    public func writeKey(_ key: String, value: Double) throws {
        let info = try keyInfo(key)

        guard let encoded = SMCDataCodec.encode(type: info.dataType, value: value) else {
            throw FunFanError.dataTypeUnsupported(info.dataType)
        }
        guard encoded.count == info.dataSize, encoded.count <= 32 else {
            throw FunFanError.dataTypeUnsupported(info.dataType)
        }

        var input = SMCParamStruct()
        input.key = FourCC.encode(key)
        input.keyInfo.dataSize = UInt32(info.dataSize)
        input.data8 = SMCCommand.writeBytes.rawValue
        input.bytes = SMCParamStruct.makeBytes(encoded)

        _ = try call(&input)
    }
}
