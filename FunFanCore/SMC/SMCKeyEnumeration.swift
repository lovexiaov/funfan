import Foundation

/// SMC 全键枚举（三级回退的第 2 级）。
///
/// 为什么需要它：温度键名逐代变化（M1 `TC0P`、M3 `Tf04`、M4 `Tp01`、M5 新增 Super 簇），
/// 内置密钥表**永远不可能覆盖所有机型**。全键枚举让程序在任意机型上自动发现全部键，
/// 从而不依赖预置列表——这是「未知代系也能用」的根本保障。
///
/// 实现解耦为纯逻辑 + 两个闭包注入，便于单测覆盖异常路径（真机存在无效槽位）。
public enum SMCKeyEnumeration {

    /// 按索引枚举全部键名。
    ///
    /// - Parameters:
    ///   - keyCount: 返回键总数（真机为读取 `#KEY`）。
    ///   - keyAt: 按索引返回键名；单索引失败时**跳过**该槽位而非整体失败。
    /// - Returns: 键名数组（保持固件索引顺序，不做去重/排序）。
    public static func allKeys(
        keyCount: () throws -> Int,
        keyAt: (Int) throws -> String
    ) rethrows -> [String] {
        let count = try keyCount()
        guard count > 0 else { return [] }

        var keys: [String] = []
        keys.reserveCapacity(count)

        for index in 0..<count {
            if let key = try? keyAt(index), !key.isEmpty {
                keys.append(key)
            }
        }
        return keys
    }
}
