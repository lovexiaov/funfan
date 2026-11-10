import Foundation

/// 语义化版本（semver 2.0.0 的**比较**子集）。
///
/// 只做一件事：把 `v1.0.0-alpha.7` 这样的 tag 变成可以正确排序的值。
/// 为什么不用字符串比较——那会把 `alpha.10` 判成小于 `alpha.9`（`'1' < '9'`），
/// 于是第 10 个预发布版永远推不出来，而且**没有任何报错**，用户只是长期停在旧版。
///
/// 与 semver 的差异（都是为了迁就真实 tag）：
/// - 接受 `v` / `V` 前缀（我们自己的 tag 就带 `v`）；
/// - 接受 1–3 段核心号，缺的按 0 补齐（`1.0` == `1.0.0`），不因为写得随意就让一整个版本消失；
/// - 数字标识符的前导零归一化（`alpha.07` == `alpha.7`），避免它与 `alpha.7` 排出两个位置；
/// - `+` 之后的构建元数据直接丢弃（semver 明写它不参与优先级）。
public struct SemanticVersion: Comparable, Hashable, CustomStringConvertible {

    public let major: Int
    public let minor: Int
    public let patch: Int
    /// 预发布标识符，已归一化；空数组表示正式版。
    public let prerelease: [String]

    public init(major: Int, minor: Int, patch: Int, prerelease: [String] = []) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    public init?(parsing raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if text.hasPrefix("v") || text.hasPrefix("V") {
            text.removeFirst()
        }
        // 构建元数据不参与比较，先切掉，免得 `+` 后面的点号把核心号切乱
        if let plus = text.firstIndex(of: "+") {
            text = String(text[text.startIndex..<plus])
        }
        guard !text.isEmpty else { return nil }

        var core = text
        var prerelease: [String] = []

        if let dash = text.firstIndex(of: "-") {
            core = String(text[text.startIndex..<dash])
            let tail = String(text[text.index(after: dash)...])
            guard !tail.isEmpty else { return nil }
            for piece in tail.split(separator: ".", omittingEmptySubsequences: false) {
                guard !piece.isEmpty else { return nil }
                let identifier = String(piece)
                guard identifier.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else {
                    return nil
                }
                if identifier.allSatisfy(\.isNumber) {
                    guard let number = Int(identifier) else { return nil }
                    prerelease.append(String(number))
                } else {
                    prerelease.append(identifier)
                }
            }
        }

        let parts = core.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard (1...3).contains(parts.count) else { return nil }

        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isNumber), let value = Int(part) else { return nil }
            numbers.append(value)
        }
        while numbers.count < 3 { numbers.append(0) }

        self.init(major: numbers[0], minor: numbers[1], patch: numbers[2], prerelease: prerelease)
    }

    public var isPrerelease: Bool { !prerelease.isEmpty }

    public var description: String {
        let core = "\(major).\(minor).\(patch)"
        return isPrerelease ? "\(core)-\(prerelease.joined(separator: "."))" : core
    }

    // MARK: - 比较

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }

        switch (lhs.isPrerelease, rhs.isPrerelease) {
        case (false, false): return false
        // 正式版 > 同号预发布。写反了会让「发布 1.0.0」推不到任何 alpha 用户。
        case (false, true): return false
        case (true, false): return true
        case (true, true): return comparePrerelease(lhs.prerelease, rhs.prerelease) < 0
        }
    }

    /// semver §11：逐段比较；数字段按数值，数字段小于任意字母段；
    /// 全部前缀相同时，段数少的更小（`alpha` < `alpha.1`）。
    private static func comparePrerelease(_ lhs: [String], _ rhs: [String]) -> Int {
        for (left, right) in zip(lhs, rhs) {
            let leftNumber = Int(left)
            let rightNumber = Int(right)

            switch (leftNumber, rightNumber) {
            case let (l?, r?):
                if l != r { return l < r ? -1 : 1 }
            case (_?, nil):
                return -1
            case (nil, _?):
                return 1
            case (nil, nil):
                if left != right { return left < right ? -1 : 1 }
            }
        }

        if lhs.count == rhs.count { return 0 }
        return lhs.count < rhs.count ? -1 : 1
    }
}
