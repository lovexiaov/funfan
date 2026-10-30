import Foundation

/// SMC 数据类型编解码。
///
/// 约定（与 SMCKit / 硬件一致）：
/// - `flt `：小端 float32（温度、风扇转速常用）
/// - `fpe2`：大端 16 位定点，值 = raw / 4
/// - `sp78`：大端有符号 16 位，值 = raw / 256（带小数温度）
/// - `ioft`：8 字节小端 48.16 定点，值 = raw / 65536（Apple Silicon 探针温度）
/// - `ui8` / `ui16` / `ui32`：大端无符号整数
public enum SMCDataCodec {

    // MARK: - flt（小端 float32）

    public static func decodeFLT(_ bytes: [UInt8]) -> Double? {
        guard bytes.count >= 4 else { return nil }
        let bits = UInt32(bytes[0])
            | (UInt32(bytes[1]) << 8)
            | (UInt32(bytes[2]) << 16)
            | (UInt32(bytes[3]) << 24)
        return Double(Float(bitPattern: bits))
    }

    public static func encodeFLT(_ value: Double) -> [UInt8] {
        let bits = Float(value).bitPattern
        return [
            UInt8(truncatingIfNeeded: bits),
            UInt8(truncatingIfNeeded: bits >> 8),
            UInt8(truncatingIfNeeded: bits >> 16),
            UInt8(truncatingIfNeeded: bits >> 24),
        ]
    }

    // MARK: - fpe2（大端定点 / 4）

    public static func decodeFPE2(_ bytes: [UInt8]) -> Double? {
        guard bytes.count >= 2 else { return nil }
        let raw = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        return Double(raw) / 4.0
    }

    public static func encodeFPE2(_ value: Double) -> [UInt8] {
        let clamped = max(0, min(65535.0, (value * 4).rounded()))
        let raw = UInt16(clamped)
        return [UInt8(raw >> 8), UInt8(raw & 0xff)]
    }

    // MARK: - sp78（大端有符号 / 256）

    public static func decodeSP78(_ bytes: [UInt8]) -> Double? {
        guard bytes.count >= 2 else { return nil }
        let raw = Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        return Double(raw) / 256.0
    }

    // MARK: - 无符号整数（大端）

    public static func decodeUInt8(_ bytes: [UInt8]) -> Double? {
        guard let b = bytes.first else { return nil }
        return Double(b)
    }

    public static func decodeUInt16(_ bytes: [UInt8]) -> Double? {
        guard bytes.count >= 2 else { return nil }
        return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
    }

    public static func decodeUInt32(_ bytes: [UInt8]) -> Double? {
        guard bytes.count >= 4 else { return nil }
        return Double(UInt32(bytes[0]) << 24
            | UInt32(bytes[1]) << 16
            | UInt32(bytes[2]) << 8
            | UInt32(bytes[3]))
    }

    // MARK: - ioft（64 位小端定点 48.16）

    /// `ioft`：8 字节小端定点，整数 48 位 + 小数 16 位，值 = raw / 65536。
    ///
    /// 出现在 Apple Silicon 上（本机 M4 的 `TR0Z`、`TR1d`–`TR5d` 等探针键），
    /// 判定依据：Asahi Linux 的 SMC 文档与 Linux 上游 `macsmc-hwmon` 驱动
    /// 都按「48.16 fixed point」处理同名字段（`macsmc_hwmon_read_ioft_scaled`）。
    ///
    /// **按有符号解**，这一点很关键：部分机型对「未接/不可用」的探针会返回
    /// 高字节全 1 的值（例如 `f8 3f ea ff ff ff ff ff`）。若按无符号解，
    /// 会得到 2.8e14 ℃ 这种"看着像合法数字"的巨大值，反而骗过温度合理性过滤、
    /// 把 CPU 均温拉到天文数字；按有符号解得 -21.8 ℃，会被 5…131 ℃ 的
    /// 范围检查直接丢弃——这才是我们要的行为。
    public static func decodeIOFT(_ bytes: [UInt8]) -> Double? {
        guard bytes.count >= 8 else { return nil }
        var raw: UInt64 = 0
        for index in 0..<8 {
            raw |= UInt64(bytes[index]) << (UInt64(index) * 8)
        }
        return Double(Int64(bitPattern: raw)) / 65_536.0
    }

    // MARK: - 类型分派

    /// 按四字符类型码解码原始字节。
    public static func decode(type: String, bytes: [UInt8]) -> Double? {
        switch type {
        case "flt ": return decodeFLT(bytes)
        case "fpe2": return decodeFPE2(bytes)
        case "sp78": return decodeSP78(bytes)
        case "ioft": return decodeIOFT(bytes)
        case "ui8 ": return decodeUInt8(bytes)
        case "ui16": return decodeUInt16(bytes)
        case "ui32": return decodeUInt32(bytes)
        default:     return nil
        }
    }

    // MARK: - 编码（写入用）

    /// 把数值编码成 SMC 键的原始字节，长度与键的 `dataSize` 一致。
    ///
    /// 写入比读取危险：字节长度或字节序错了会写坏 SMC 状态。
    /// 因此不支持的类型一律返回 `nil`（调用方转成 `.dataTypeUnsupported`），绝不猜。
    ///
    /// `ioft` 刻意只实现解码、不实现编码：它在真机上全部是温度探针（只读），
    /// 没有任何写入需求；为它补一个"能写"的实现只会扩大误写风险。
    public static func encode(type: String, value: Double) -> [UInt8]? {
        guard value.isFinite else { return nil }

        switch type {
        case "flt ":
            return encodeFLT(value)
        case "fpe2":
            return encodeFPE2(value)
        case "sp78":
            return encodeSP78(value)
        case "ui8 ":
            let clamped = max(0, min(255, value.rounded()))
            return [UInt8(clamped)]
        case "ui16":
            let clamped = UInt16(max(0, min(65535, value.rounded())))
            return [UInt8(clamped >> 8), UInt8(clamped & 0xff)]
        case "ui32":
            let clamped = UInt32(max(0, min(4_294_967_295, value.rounded())))
            return [
                UInt8((clamped >> 24) & 0xff),
                UInt8((clamped >> 16) & 0xff),
                UInt8((clamped >> 8) & 0xff),
                UInt8(clamped & 0xff),
            ]
        default:
            return nil
        }
    }

    /// sp78 编码（大端有符号，值 × 256）。
    public static func encodeSP78(_ value: Double) -> [UInt8] {
        let scaled = (value * 256).rounded()
        let clamped = max(Double(Int16.min), min(Double(Int16.max), scaled))
        let raw = UInt16(bitPattern: Int16(clamped))
        return [UInt8(raw >> 8), UInt8(raw & 0xff)]
    }
}
