import AppKit
import FunFanCore

/// 合盖监听（GUI 侧）。
///
/// 只负责采集信号并做去抖，判定逻辑在 `FunFanCore.LidPolicy` 里（可单测）。
/// 信号取自 `NSScreen.screens`：合盖（含带外接屏的 clamshell 模式）时内建面板会关闭、
/// 从屏幕列表消失；开盖后重新出现。
///
/// 注意：带外接屏合盖时系统不睡，`NSWorkspace.willSleepNotification` 不会触发，
/// 所以必须靠这条屏幕信号兜住；不带外接屏合盖时系统会睡，两条信号都会命中。
final class LidMonitor {

    /// 合盖状态变化回调（主线程）。
    var onChange: ((Bool) -> Void)?

    private(set) var isClosed = false

    private let isPortable: Bool
    private var observer: NSObjectProtocol?

    init(model: String = LidMonitor.hardwareModel(), hasBattery: Bool = LidMonitor.hasBattery()) {
        self.isPortable = LidPolicy.isPortable(model: model, hasBattery: hasBattery)
    }

    /// 台式机（无内建屏）直接不启动，避免「无内建屏 → 永远合盖」的误判。
    func start() {
        guard isPortable else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh(notify: true)
        }
        refresh(notify: false)   // 启动时只记录状态，不触发返还
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    /// 验收用：强制注入一个合盖状态并立刻回调。
    ///
    /// 存在的理由：台式机没有盖子，agent / 远程会话里也看不到内建屏，真实信号
    /// 根本无从产生，但「合盖之后的行为链」（返还 → 拒绝重新接管 → 开盖恢复）
    /// 是必须能验的。这条通道只由 `--simulate-lid` 调试参数调用。
    ///
    /// 刻意不做「与当前状态相同就 early return」：验收脚本需要在同一状态上
    /// 重复触发，而下游 `suspend` / `resume` 本身都是幂等的。
    func force(closed: Bool) {
        isClosed = closed
        onChange?(closed)
    }

    // MARK: - 内部

    private func refresh(notify: Bool) {
        var builtinOnline = false
        var externalOnline = false

        // 用「在线」列表而非「活动」列表：显示器休眠只是 active = false，
        // 合盖才是物理断电、直接离线。差别就在这里。
        for id in LidMonitor.onlineDisplays() {
            if CGDisplayIsBuiltin(id) != 0 {
                builtinOnline = true
            } else {
                externalOnline = true
            }
        }

        let closed = LidPolicy.isClosed(
            builtinDisplayOnline: builtinOnline,
            externalDisplayOnline: externalOnline,
            isPortable: isPortable
        )
        guard closed != isClosed else { return }
        isClosed = closed
        guard notify else { return }
        onChange?(closed)
    }

    private static func onlineDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    /// `sysctl hw.model`，例如 `Mac16,10`。
    static func hardwareModel() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return "" }
        return String(cString: buffer)
    }

    /// 是否有电池——这是「笔记本 vs 台式机」最可靠的判据。
    static func hasBattery() -> Bool {
        BatteryDetailParser.parse(AppleSmartBatteryReader.properties()).present
    }
}
