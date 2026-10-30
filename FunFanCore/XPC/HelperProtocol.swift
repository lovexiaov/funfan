import Foundation

/// 特权 helper 的 XPC 常量与协议。
///
/// 设计取舍：协议只传 `Data`（内部是 Codable JSON），而不是自定义 `NSSecureCoding` 类。
/// 原因：FanControlRequest 是带关联值的 Swift 枚举，桥接到 Objective-C 类型成本高且易错；
/// 用 `Data` 既保留了类型安全（解码失败可回报），又让协议面保持极窄。
public enum HelperConstants {
    /// launchd Mach service 名（需与 LaunchDaemon plist 的 MachServices 一致）。
    public static let machServiceName = "com.funfan.helper"
    /// helper 可执行文件安装路径（root 所有）。
    public static let installedBinaryPath = "/Library/PrivilegedHelperTools/com.funfan.helper"
    /// LaunchDaemon plist 安装路径。
    public static let installedPlistPath = "/Library/LaunchDaemons/com.funfan.helper.plist"
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
