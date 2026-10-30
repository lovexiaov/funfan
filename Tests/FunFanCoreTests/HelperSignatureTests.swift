import XCTest
@testable import FunFanCore

/// helper 侧「只允许自家 App 连进来」的签名要求构造。
///
/// 这些断言看着琐碎，但要求串写错一个字（多一个空格、少一个引号）的后果是
/// **所有合法连接被系统拒绝**，而错误信息只有一句 "connection invalid"，
/// 极难现场定位。所以在纯字符串层面钉死。
final class HelperSignatureTests: XCTestCase {

    func testRequirementContainsIdentifierAnchorAndTeam() {
        let requirement = HelperSignature.clientRequirement(teamID: "ABCDE12345")
        XCTAssertNotNil(requirement)

        let text = requirement ?? ""
        XCTAssertTrue(text.contains("identifier \"com.funfan.app\""),
                      "缺少 bundle 标识约束：\(text)")
        XCTAssertTrue(text.contains("anchor apple generic"),
                      "缺少 Apple 证书链约束（adhoc/自签会被放进来）：\(text)")
        XCTAssertTrue(text.contains("certificate leaf[subject.OU] = \"ABCDE12345\""),
                      "缺少 Team ID 约束（别人可用同名 bundle id 冒充）：\(text)")
    }

    func testRequirementIsSingleLine() {
        // 要求串是传给 setCodeSigningRequirement 的单条表达式，
        // 混进换行会被解析成语法错误。
        let requirement = HelperSignature.clientRequirement(teamID: "ABCDE12345") ?? ""
        XCTAssertFalse(requirement.contains("\n"), "要求串不能含换行")
        XCTAssertFalse(requirement.contains("  "), "要求串不能有连续空格")
    }

    func testAdhocTeamIDProducesNoRequirement() {
        // adhoc 签名没有 Team ID：构造不出有效要求，必须显式返回 nil，
        // 让调用方走「开发期不校验」分支，而不是拿到一个空 Team 的要求串。
        XCTAssertNil(HelperSignature.clientRequirement(teamID: nil))
        XCTAssertNil(HelperSignature.clientRequirement(teamID: ""))
        XCTAssertNil(HelperSignature.clientRequirement(teamID: "   "))
    }

    func testTeamIDIsTrimmed() {
        let requirement = HelperSignature.clientRequirement(teamID: " ABCDE12345\n")
        XCTAssertTrue(requirement?.contains("OU] = \"ABCDE12345\"") == true)
    }

    func testAppIdentifierMatchesBundleIdentifier() {
        // 这个常量必须与 packaging/Info.plist 的 CFBundleIdentifier 一致，
        // 否则正式包里 helper 会把真正的 App 拒之门外。
        XCTAssertEqual(HelperSignature.appBundleIdentifier, "com.funfan.app")
    }
}
