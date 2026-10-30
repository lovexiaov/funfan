import Foundation

/// 合盖（clamshell）判定。
///
/// 背景：本机（Mac16,10 / macOS 27）实测，IORegistry 里 **已经没有** `AppleClamshellState`
/// 这个键，`IOPMrootDomain` 服务也不存在——这两条是老方案读盖子状态的唯一途径。
/// 于是改用两条公开信号组合：
///
///   1. **系统睡眠 / 唤醒**：合盖且没有外接屏时系统必然入睡，
///      由 `AppDelegate` 直接订阅 `NSWorkspace.willSleepNotification` 返还；
///   2. **内建屏是否在线**：合盖 + 外接屏（clamshell 模式）时系统不睡，
///      但内建面板会被关闭，于是从 `NSScreen.screens` 中消失。
///
/// 判据刻意偏向保守：误判为「合盖」的代价只是多返还一次系统自动（安全方向），
/// 而漏判的代价是风扇被锁在手动转速里（危险方向）。
public enum LidPolicy {

    /// 是否处于合盖状态。
    ///
    /// 判据 = 笔记本 + 内建屏**离线** + 至少一块外接屏在线。
    ///
    /// 三个条件缺一不可，理由：
    /// - `isPortable`：台式机没有内建屏，否则会被判成「一直合着盖」；
    /// - `externalDisplayOnline`：合盖而无外接屏时系统必然入睡，由睡眠通知覆盖；
    ///   真机实测里「只有虚拟屏/远程会话」也会出现内建屏缺失，加这条可挡住误判；
    /// - `builtinDisplayOnline == false`：clamshell 模式下内建面板物理断电、从**在线**列表消失，
    ///   而仅仅「显示器休眠」时它仍在在线列表里——所以必须用在线列表，不是活动列表。
    ///
    /// - Parameters:
    ///   - builtinDisplayOnline: 内建屏是否在在线显示列表中
    ///   - externalDisplayOnline: 是否至少有一块外接屏在线
    ///   - isPortable: 是否为笔记本机型
    public static func isClosed(
        builtinDisplayOnline: Bool,
        externalDisplayOnline: Bool,
        isPortable: Bool
    ) -> Bool {
        guard isPortable, externalDisplayOnline else { return false }
        return !builtinDisplayOnline
    }

    /// 机型是否为笔记本（有内建屏 + 盖子）。
    ///
    /// 不能只看机型标识：现代 Apple Silicon 已经改成 `Mac16,10` 这种编号
    /// （这台开发机就是 Mac mini M4），不再是 `MacBookPro18,3` 那种写法，
    /// 而 Mac mini / Studio 也同样是 `Mac1x,y` 形态，两者从型号上分不开。
    /// 因此以**是否检测到电池**为主判据（台式机没有电池），
    /// 老机型的 `MacBook*` 标识作为兜底（电池读取失败时仍能认出来）。
    public static func isPortable(model: String, hasBattery: Bool) -> Bool {
        if hasBattery { return true }
        return model.hasPrefix("MacBook")
    }
}
