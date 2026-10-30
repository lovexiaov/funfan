import AppKit
import FunFanCore

/// 正在运行的进程里有没有已知的风扇控制软件。
///
/// 只用于**解释**冲突原因（「大概是 Macs Fan Control 在控制」），
/// 不参与「是否冲突」的判定——判定只看硬件里的手动模式。
/// 这么分工的原因是：名单永远不全，而 `F0Md=1` 是硬事实。
enum RunningApps {

    /// 识别到的风扇控制软件名；没有则 nil。
    static func fanControllerName() -> String? {
        for app in NSWorkspace.shared.runningApplications {
            if let name = KnownFanControllers.name(
                bundleIdentifier: app.bundleIdentifier,
                processName: app.localizedName ?? app.executableURL?.lastPathComponent
            ) {
                return name
            }
        }
        return nil
    }
}
