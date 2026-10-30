import Foundation

/// SMC 固定 32 字节数据负载。
public typealias SMCBytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

/// 全零的 SMCBytes，用作默认值。
public let zeroSMCBytes: SMCBytes = (
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0
)

/// 与 Apple `smc.h` 布局对齐的 80 字节参数结构体。
///
/// 内存布局（按 C 对齐规则，总大小 80 字节）：
/// ```
/// key          UInt32   offset 0   (4)
/// vers         Vers     offset 4   (6, align 2)
/// pLimitData   PLimit   offset 12  (16, align 4)
/// keyInfo      KeyInfo  offset 28  (12, align 4)
/// result       UInt8    offset 40
/// status       UInt8    offset 41
/// data8        UInt8    offset 42
/// data32       UInt32   offset 44  (4, align 4)
/// bytes        [32]     offset 48  (32)
/// = 80
/// ```
/// 由 `SMCParamStructTests` 以 `MemoryLayout.size == 80` 锁定。
public struct SMCParamStruct {

    /// 版本信息（6 字节）。
    public struct Vers {
        public var major: UInt8 = 0
        public var minor: UInt8 = 0
        public var build: UInt8 = 0
        public var reserved: UInt16 = 0
        public init() {}
    }

    /// 平台限制数据（16 字节）。
    public struct PLimitData {
        public var version: UInt16 = 0
        public var length: UInt16 = 0
        public var cpuPLimit: UInt32 = 0
        public var gpuPLimit: UInt32 = 0
        public var memPLimit: UInt32 = 0
        public init() {}
    }

    /// 键信息（12 字节）。
    ///
    /// 注意：Swift 中 `MemoryLayout<KeyInfo>.size` 不含尾部对齐填充（为 9），
    /// 而 C 结构体要求 12 字节。故显式补 3 字节 padding，保证嵌入外层后字段偏移与 C 一致。
    public struct KeyInfo {
        public var dataSize: UInt32 = 0
        public var dataType: UInt32 = 0
        public var dataAttributes: UInt8 = 0
        public var padding: (UInt8, UInt8, UInt8) = (0, 0, 0)
        public init() {}
    }

    public var key: UInt32 = 0
    public var vers: Vers = Vers()
    public var pLimitData: PLimitData = PLimitData()
    public var keyInfo: KeyInfo = KeyInfo()
    public var result: UInt8 = 0
    public var status: UInt8 = 0
    public var data8: UInt8 = 0
    public var data32: UInt32 = 0
    public var bytes: SMCBytes = zeroSMCBytes

    public init() {}

    /// 把任意长度字节数组装进固定 32 字节负载（不足补 0，超出截断）。
    ///
    /// 用于写入路径：`SMCBytes` 是元组而非数组，无法直接 memcpy。
    public static func makeBytes(_ data: [UInt8]) -> SMCBytes {
        let padded = Array(data.prefix(32)) + Array(repeating: 0, count: max(0, 32 - data.count))
        return (
            padded[0], padded[1], padded[2], padded[3],
            padded[4], padded[5], padded[6], padded[7],
            padded[8], padded[9], padded[10], padded[11],
            padded[12], padded[13], padded[14], padded[15],
            padded[16], padded[17], padded[18], padded[19],
            padded[20], padded[21], padded[22], padded[23],
            padded[24], padded[25], padded[26], padded[27],
            padded[28], padded[29], padded[30], padded[31]
        )
    }
}

/// SMC 命令码（写入 `data8`）。
public enum SMCCommand: UInt8 {
    case readBytes = 5
    case writeBytes = 6
    /// 按索引取键名（`data32` 传索引，返回键名在 `output.key`）。用于全键枚举。
    case readIndex = 8
    case getKeyInfo = 9
}
