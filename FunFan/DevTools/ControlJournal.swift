import Foundation

/// 控制侧的取证日志（只有 `FunFan --log-control` 启动时才写盘）。
///
/// 为什么需要它：策略「重启后变回自动」这类问题，现场只有两样东西可查——
/// 用户偏好里最后落盘的值，和「谁在什么时候把它改写了」。前者有 plist，
/// 后者什么都没有。GUI 进程在 agent 沙箱里起不来，只能把每条改变策略的动作
/// （用户点击 / 恢复 / 租约失败 / 重连）连原因一起落到
/// `~/Library/Application Support/FunFan/control.log`，事后直接读文件。
///
/// 与 `PopoverClickLog` 同一套路：默认关闭，`isEnabled` 为 false 时整条直接返回。
enum ControlJournal {

    static let isEnabled = CommandLine.arguments.contains("--log-control")

    private static let queue = DispatchQueue(label: "cn.lovexiaov.fun.fan.control-log")

    private static let url: URL? = {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        return base.appendingPathComponent("FunFan/control.log")
    }()

    static func write(_ message: String) {
        guard isEnabled, let url else { return }
        let line = "\(stamp()) \(message)\n"
        queue.async {
            let manager = FileManager.default
            try? manager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }

    /// 一次运行一条分隔线：日志是追加写的，没有边界就分不清哪段属于哪次重启。
    static func sessionStart(strategy: String) {
        write("=== 启动：恢复到的策略 = \(strategy) pid=\(ProcessInfo.processInfo.processIdentifier) ===")
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }
}
