import Foundation
import Security

/// 从代码签名里读团队标识（Team ID）。
///
/// 用途只有一个：helper 启动时自省「我是被谁签的」，再用这个 Team ID 生成
/// 客户端签名要求（见 `HelperSignature.clientRequirement(teamID:)`）。
/// 这样就不必在构建脚本里把 Team ID 塞成编译常量或环境变量 ——
/// 签名本身已经是唯一事实来源，塞第二份迟早漂移。
///
/// adhoc 签名（`codesign -s -`）没有 Team ID，返回 nil，调用方按开发期处理。
public enum CodeSigningInfo {

    /// 当前进程自己的 Team ID。
    public static func ownTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        // SecCode（运行中的代码）→ SecStaticCode（磁盘上的签名），
        // 签名信息挂在静态签名上，跳不过这一步。
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        return teamIdentifier(of: staticCode)
    }

    /// 磁盘上某个可执行文件/App 包的 Team ID。
    public static func teamIdentifier(of url: URL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        return teamIdentifier(of: staticCode)
    }

    // MARK: - 内部

    private static func teamIdentifier(of code: SecStaticCode) -> String? {
        var information: CFDictionary?
        // kSecCSSigningInformation 才是「签名信息」；不传这个 flag 拿不到 OU/Team。
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(code, flags, &information) == errSecSuccess,
              let dictionary = information as? [String: Any] else { return nil }
        guard let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String,
              !team.isEmpty else { return nil }
        return team
    }
}
