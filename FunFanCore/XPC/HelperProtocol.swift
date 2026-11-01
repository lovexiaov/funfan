import Foundation

/// 特权 helper 的 XPC 常量与协议。
///
/// 设计取舍：协议只传 `Data`（内部是 Codable JSON），而不是自定义 `NSSecureCoding` 类。
/// 原因：FanControlRequest 是带关联值的 Swift 枚举，桥接到 Objective-C 类型成本高且易错；
/// 用 `Data` 既保留了类型安全（解码失败可回报），又让协议面保持极窄。
public enum HelperConstants {
    /// 反向域名标识的唯一前缀：App、helper、日志、偏好设置全部挂在这一个根下。
    ///
    /// helper 一律用 `<root>.helper`，不要另起一个不相关的名字 —— 让人一眼看出
    /// 它是谁的组件，`AssociatedBundleIdentifiers` 也才能把后台项归到 App 名下。
    public static let identifierRoot = "cn.lovexiaov.fun.fan"

    /// launchd Mach service 名（需与 LaunchDaemon plist 的 MachServices 一致）。
    public static let machServiceName = "\(identifierRoot).helper"
    /// helper 可执行文件安装路径（root 所有）。
    public static let installedBinaryPath = "/Library/PrivilegedHelperTools/\(machServiceName)"
    /// LaunchDaemon plist 安装路径。
    public static let installedPlistPath = "/Library/LaunchDaemons/\(machServiceName).plist"
    /// helper 的 stderr 落点（launchd 直接追加，不做轮转）。
    public static let logPath = "/var/log/\(machServiceName).log"

    /// 改名前的标识与路径。
    ///
    /// 改名是个有代价的动作：旧 daemon 若还留在机器上，它会和新 helper 同时写
    /// SMC（风扇忽快忽慢、退出后不返还）。所以安装流程第一步就要把旧的全清掉，
    /// 而不是指望用户记得手动卸载。
    public enum Legacy {
        public static let identifierRoot = "com.funfan"
        public static let machServiceName = "\(identifierRoot).helper"
        public static let appBundleIdentifier = "\(identifierRoot).app"
        public static let installedBinaryPath = "/Library/PrivilegedHelperTools/\(machServiceName)"
        public static let installedPlistPath = "/Library/LaunchDaemons/\(machServiceName).plist"
        public static let logPath = "/var/log/\(machServiceName).log"
    }
}

@objc public protocol FunFanHelperXPCProtocol {
    /// 处理一个 Codable 编码的 `FanControlRequest`，回传 Codable 编码的 `FanControlReply`。
    func handle(_ requestData: Data, reply: @escaping (Data) -> Void)

    /// GUI 心跳：续租。返回租约是否仍有效。
    func heartbeat(reply: @escaping (Bool) -> Void)
}

/// 请求/应答的编解码（客户端与 helper 共用，保证两端格式一致）。
public enum HelperCodec {

    public static func encode(_ request: FanControlRequest) -> Data {
        (try? JSONEncoder().encode(request)) ?? Data()
    }

    public static func decodeRequest(_ data: Data) -> FanControlRequest? {
        try? JSONDecoder().decode(FanControlRequest.self, from: data)
    }

    public static func encode(_ reply: FanControlReply) -> Data {
        (try? JSONEncoder().encode(reply)) ?? Data()
    }

    public static func decodeReply(_ data: Data) -> FanControlReply? {
        try? JSONDecoder().decode(FanControlReply.self, from: data)
    }

    /// 失败应答的便捷构造。
    public static func failure(_ error: FunFanError) -> Data {
        encode(.failed(FanControlErrorPayload(error: error)))
    }
}
