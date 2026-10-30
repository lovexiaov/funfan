import Foundation

/// helper 对 GUI 客户端的代码签名要求。
///
/// 背景：helper 以 root 运行、能写 SMC。如果任何进程都能连上它的 Mach service，
/// 那就等于把 root 的 SMC 写权限裸露给全系统。所以连接建立前必须校验客户端签名。
///
/// 校验条件三件套：
/// 1. `identifier "com.funfan.app"` —— 是本 App，不是别的东西复用同名服务；
/// 2. `anchor apple generic` —— 证书链能上溯到 Apple（排除自签/adhoc）；
/// 3. `certificate leaf[subject.OU] = "<TeamID>"` —— 同一个团队的签名，
///    防止别人拿自己的 Developer ID 签一个同样 bundle id 的 App 来冒充。
///
/// adhoc 签名取不到 Team ID（`TeamIdentifier=not set`），这时构造不出有效要求，
/// 只能返回 nil —— 开发期不做校验，发布期必须为 nil 之外的值。
public enum HelperSignature {

    /// 主 App 的 bundle 标识，与 `packaging/Info.plist` 里的 `CFBundleIdentifier` 一致。
    public static let appBundleIdentifier = "com.funfan.app"

    /// 生成 XPC 客户端签名要求串；`teamID` 为空（adhoc）时返回 nil。
    ///
    /// - Note: 这是 `NSXPCConnection.setCodeSigningRequirement(_:)` 接受的
    ///   代码签名要求语言（Code Signing Requirement Language），不是 shell 字符串，
    ///   引号与 `=` 两侧的空格都是有意义的，别随手格式化。
    public static func clientRequirement(teamID: String?) -> String? {
        guard let teamID = teamID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !teamID.isEmpty else { return nil }
        return "identifier \"\(appBundleIdentifier)\""
            + " and anchor apple generic"
            + " and certificate leaf[subject.OU] = \"\(teamID)\""
    }
}
