import Foundation

/// 日志里的「这条是哪个二进制写的」。
///
/// 开发态两种启动方式**共用同一份日志文件**（`~/Library/Application Support/FunFan/`）：
///
///   · `make run`             → `.build/debug/FunFan`，没有 bundle 身份
///   · `make run-app` / `open dist/FunFan.app` → 有 bundle 身份
///
/// 不标身份的话，两种行为会被读成同一条时间线——例如「打包版点击正常、裸二进制
/// 点击异常」这种差异，日志里只会看到忽好忽坏，白排查一轮。
enum LogSession {

    /// 形如 `cn.lovexiaov.fun.fan（/…/dist/FunFan.app）` 或 `裸二进制（/…/.build/debug/FunFan）`。
    static let identity: String = {
        let path = Bundle.main.bundlePath
        guard let identifier = Bundle.main.bundleIdentifier else {
            return "裸二进制（\(path)）"
        }
        return "\(identifier)（\(path)）"
    }()

    /// 一次运行一行的会话头：身份 + pid + 启动参数。
    static var header: String {
        let arguments = CommandLine.arguments.dropFirst().joined(separator: " ")
        let suffix = arguments.isEmpty ? " ===" : " args=[\(arguments)] ==="
        return "=== 会话：\(identity) pid=\(ProcessInfo.processInfo.processIdentifier)" + suffix
    }
}
