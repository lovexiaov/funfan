import Foundation

/// 菜单栏点击的取证日志（只有 `FunFan --log-popover` 启动时才写盘）。
///
/// 为什么需要它：图标点击属于「看得见、抓不着」的问题——GUI 进程在 agent 沙箱里
/// 起不来，拿不到「哪一下按下、目标是哪个窗口、那一刻面板是什么状态」的时序，
/// 只能靠猜。开关一开就把每次点击落到
/// `~/Library/Application Support/FunFan/popover-click.log`，事后直接读文件，
/// 不用让用户开 Console。
///
/// 正常使用不写盘（`isEnabled` 为 false 时整条 `write` 直接返回）。
enum PopoverClickLog {

    static let isEnabled = CommandLine.arguments.contains("--log-popover")

    private static let queue = DispatchQueue(label: "cn.lovexiaov.fun.fan.popover-log")

    private static let url: URL? = {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        return base.appendingPathComponent("FunFan/popover-click.log")
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

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }
}
