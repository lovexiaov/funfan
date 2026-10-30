import Foundation

/// 四字符键名工具。
public enum FourCC {
    /// 将 4 字符键名编码为 UInt32（大端序，与 SMC 固件一致）。
    public static func encode(_ key: String) -> UInt32 {
        var result: UInt32 = 0
        for byte in key.utf8.prefix(4) {
            result = (result << 8) | UInt32(byte)
        }
        return result
    }

    /// 将 UInt32 解码回 4 字符键名。
    public static func decode(_ value: UInt32) -> String {
        let bytes: [UInt8] = [
            UInt8(truncatingIfNeeded: value >> 24),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value),
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }
}

/// SMC 键名构造器。
///
/// 机型差异极大（如 `F0Md` vs `F0md`、`Ftst` 存在性），因此这里只提供**键名构造**，
/// 真正的存在性/类型判断一律走运行时 `GetKeyInfo` 探测，绝不写死。
public enum SMCKeyName {

    // 风扇相关（i 为风扇索引，从 0 开始）
    public static func fanActual(_ index: Int) -> String { "F\(index)Ac" }
    public static func fanTarget(_ index: Int) -> String { "F\(index)Tg" }
    public static func fanMin(_ index: Int) -> String { "F\(index)Mn" }
    public static func fanMax(_ index: Int) -> String { "F\(index)Mx" }

    /// 风扇模式键存在 `F0Md` 与 `F0md` 两种写法，调用方需两者都探测。
    public static func fanModeCandidates(_ index: Int) -> [String] {
        ["F\(index)Md", "F\(index)md"]
    }

    /// 风扇数量键。
    public static let fanCount = "FNum"
    /// 全部键数量键（`ui32`），全键枚举的入口。
    public static let keyCount = "#KEY"
    /// M3/M4 手动接管解锁键。
    public static let ftst = "Ftst"
}

/// 键信息快照。
public struct SMCKeyInfo: Equatable, Sendable {
    public let key: String
    public let dataSize: Int
    public let dataType: String
    public let dataAttributes: UInt8

    public init(key: String, dataSize: Int, dataType: String, dataAttributes: UInt8) {
        self.key = key
        self.dataSize = dataSize
        self.dataType = dataType
        self.dataAttributes = dataAttributes
    }
}
