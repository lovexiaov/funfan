import XCTest
@testable import FunFanCore

/// 版本号解析与比较。
///
/// 为什么值得单测：更新检查的**全部判断**都压在这个比较上。写错的方向有两个，
/// 而且都很安静：
/// 1. 字符串比较 —— `1.0.0-alpha.10` < `1.0.0-alpha.9`（'1' < '9'），
///    于是第 10 个预发布版永远推不出来，用户卡在 alpha.9 且没有任何报错；
/// 2. 忘了「正式版 > 同号预发布」—— `1.0.0` 会被判成比 `1.0.0-alpha.7` 旧，
///    正式版发布后反而没人被提示。
/// 两条都只在特定版本号组合下才暴露，靠手工点一次界面发现不了。
final class SemanticVersionTests: XCTestCase {

    private func version(_ raw: String, file: StaticString = #filePath, line: UInt = #line) -> SemanticVersion {
        guard let value = SemanticVersion(parsing: raw) else {
            XCTFail("解析失败：\(raw)", file: file, line: line)
            return SemanticVersion(major: 0, minor: 0, patch: 0, prerelease: [])
        }
        return value
    }

    // MARK: - 解析

    func testParsesStableVersion() {
        let v = version("1.0.0")
        XCTAssertEqual(v.major, 1)
        XCTAssertEqual(v.minor, 0)
        XCTAssertEqual(v.patch, 0)
        XCTAssertFalse(v.isPrerelease)
        XCTAssertEqual(v.description, "1.0.0")
    }

    func testParsesPrereleaseIdentifiers() {
        let v = version("1.0.0-alpha.7")
        XCTAssertEqual(v.prerelease, ["alpha", "7"])
        XCTAssertTrue(v.isPrerelease)
        XCTAssertEqual(v.description, "1.0.0-alpha.7")
    }

    /// tag 带 `v` 前缀是常态（我们自己的 tag 就是 `v1.0.0-alpha.7`）。
    func testStripsLeadingV() {
        XCTAssertEqual(version("v1.0.0-alpha.7"), version("1.0.0-alpha.7"))
        XCTAssertEqual(version("V2.3.4"), version("2.3.4"))
    }

    /// 构建元数据（`+` 之后）不参与优先级比较，这是 semver 明写的规则。
    func testIgnoresBuildMetadata() {
        XCTAssertEqual(version("1.0.0+build.5"), version("1.0.0"))
        XCTAssertEqual(version("1.0.0-alpha.7+20261111"), version("1.0.0-alpha.7"))
    }

    /// 遇到 `1.0` 这种省略补丁位的 tag 不能当解析失败——那会让一整个版本
    /// 从更新列表里静默消失。缺的位按 0 补齐。
    func testPadsMissingComponents() {
        XCTAssertEqual(version("1.0"), version("1.0.0"))
        XCTAssertEqual(version("2"), version("2.0.0"))
    }

    func testTrimsWhitespace() {
        XCTAssertEqual(version(" 1.0.0-alpha.7\n"), version("1.0.0-alpha.7"))
    }

    /// 数字标识符的前导零按 semver 非法，但真实 tag 里出现过（`alpha.07`）。
    /// 归一化成 `alpha.7`，这样它既不会解析失败，也不会和 `alpha.7` 排出两个位置。
    func testNormalizesLeadingZerosInNumericIdentifiers() {
        XCTAssertEqual(version("1.0.0-alpha.07"), version("1.0.0-alpha.7"))
        XCTAssertEqual(version("1.0.0-01"), version("1.0.0-1"))
    }

    func testRejectsInvalidInput() {
        for raw in ["", "  ", "abc", "1.x.0", "1.2.3.4", "1.0.0-", "1.0.0-alpha..1", "v"] {
            XCTAssertNil(SemanticVersion(parsing: raw), "应当拒绝：\(raw)")
        }
    }

    // MARK: - 排序（semver §11）

    /// 最容易写错的一条：数字段要按数值比，不能按字符串比。
    func testComparesNumericIdentifiersNumerically() {
        XCTAssertLessThan(version("1.0.0-alpha.9"), version("1.0.0-alpha.10"))
        XCTAssertLessThan(version("1.0.0-alpha.2"), version("1.0.0-alpha.11"))
    }

    func testOrdersPrereleaseChain() {
        let ordered = [
            "1.0.0-alpha.9",
            "1.0.0-alpha.10",
            "1.0.0-beta",
            "1.0.0-beta.2",
            "1.0.0-rc.1",
            "1.0.0",
        ].map { version($0) }

        for (earlier, later) in zip(ordered, ordered.dropFirst()) {
            XCTAssertLessThan(earlier, later, "\(earlier) 应当早于 \(later)")
        }
    }

    /// 前缀相同时，标识符更少的更小（`alpha` < `alpha.1`）。
    func testShorterPrereleaseIsSmaller() {
        XCTAssertLessThan(version("1.0.0-alpha"), version("1.0.0-alpha.1"))
    }

    /// 数字标识符 < 字母标识符。
    func testNumericIdentifierSortsBeforeAlphanumeric() {
        XCTAssertLessThan(version("1.0.0-1"), version("1.0.0-alpha"))
    }

    func testComparesCoreNumbers() {
        XCTAssertLessThan(version("1.0.0"), version("1.0.1"))
        XCTAssertLessThan(version("1.0.1"), version("1.1.0"))
        XCTAssertLessThan(version("1.1.0"), version("2.0.0"))
        XCTAssertLessThan(version("1.0.0-alpha.7"), version("1.0.1"))
    }

    /// 正式版必须大于同号预发布，否则「发布 1.0.0」不会提示任何 alpha 用户。
    func testStableIsGreaterThanSameNumberPrerelease() {
        XCTAssertGreaterThan(version("1.0.0"), version("1.0.0-alpha.7"))
        XCTAssertGreaterThan(version("1.0.0"), version("1.0.0-rc.9"))
    }

    func testEqualityIsConsistentWithOrdering() {
        let a = version("v1.0.0-alpha.7")
        let b = version("1.0.0-alpha.7+local")
        XCTAssertEqual(a, b)
        XCTAssertFalse(a < b)
        XCTAssertFalse(b < a)
    }
}
