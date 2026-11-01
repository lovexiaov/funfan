import Foundation
import FunFanCore

/// 开发期取证：策略持久化的读/写路径是否真的落到 `UserDefaults`。
///
/// 为什么需要它：`ControlStore.strategy` 的写盘藏在 `@Published` 的 `didSet` 里，
/// 单元测试只覆盖 `ControlPreferences` 本身（用一个私有 suite），覆盖不到
/// 「App 里那个实例到底写没写」。而 GUI 进程在本机沙箱内会被 SIGKILL，
/// 只能把探针放在 `NSApplication.shared` 之前跑——那一段不碰窗口服务器，
/// 是唯一能在无人值守下验证真实二进制的入口。
///
/// 用法：
///   FunFan --probe-prefs                   读一遍（不改任何东西）
///   FunFan --probe-prefs write             经 ControlStore 写一轮再还原
///   FunFan --probe-prefs launch fixed      预置持久值 → 走真实启动链 → 观察若干秒
///
/// `launch` 是最关键的一档：它复刻「重启后」的那条路（init 恢复 → bootstrap
/// 连 helper → apply → 租约心跳），能看出持久值是在**读**的时候丢的，还是在
/// **启动后几秒**被别的路径改回「自动」的。
enum PrefsProbe {

    static func runIfRequested() -> Bool {
        guard CommandLine.arguments.contains("--probe-prefs") else { return false }

        let args = CommandLine.arguments
        print("bundleID = \(Bundle.main.bundleIdentifier ?? "<nil>")")
        print("domain = \(Bundle.main.bundleIdentifier ?? (Bundle.main.bundlePath as NSString).lastPathComponent)")

        if args.contains("lease") {
            runLeaseLoss()
            return true
        }

        if let index = args.firstIndex(of: "launch") {
            let desired = args.indices.contains(index + 1) ? args[index + 1] : nil
            runLaunch(desired: desired)
            return true
        }

        let shouldWrite = args.contains("write")
        dumpDefaults(label: "启动前")

        let store = ControlStore()
        print("ControlStore.strategy = \(store.strategy.rawValue)")
        print("ControlStore.fixedRpm = \(store.fixedRpm)")

        guard shouldWrite else { return true }

        let original = store.strategy
        let probe: ControlStrategy = original == .fixed ? .curve : .fixed
        print("--- 写入 \(probe.rawValue) ---")
        store.strategy = probe
        dumpDefaults(label: "写入后")
        print("fresh ControlPreferences.strategy = \(ControlPreferences().strategy.rawValue)")

        // 还原，别把用户的设置当成实验品
        store.strategy = original
        print("--- 还原 \(original.rawValue) ---")
        dumpDefaults(label: "还原后")
        return true
    }

    // MARK: - 租约丢失：策略必须原地不动

    /// 预置「固定 2400」→ 接管 → 模拟租约丢失 → 看策略与持久值有没有被改掉。
    ///
    /// 判定标准只有一条：`strategy` 与落盘值都必须仍是 `fixed`。
    /// 旧实现在这里会变成 `automatic`，并且**写回磁盘**，于是每次重启都从自动开始。
    private static func runLeaseLoss() {
        let prefs = ControlPreferences()
        let originalStrategy = prefs.strategy
        let originalRpm = prefs.fixedRpm

        prefs.strategy = .fixed
        prefs.fixedRpm = 2400
        print("预置持久值 = fixed / 2400（原值 \(originalStrategy.rawValue) / \(Int(originalRpm))）")

        let store = ControlStore()
        store.bootstrap()
        spin(seconds: 1.5) { _ in }

        if !store.isManual, store.helperStatus.isReady {
            store.takeOverAnyway()
            spin(seconds: 1.5) { _ in }
        }
        print("接管状态：isManual = \(store.isManual)，message = \(store.message ?? "<nil>")")

        print("--- 模拟租约丢失 ---")
        store.simulateLeaseLossForDiagnostics()
        spin(seconds: 10) { elapsed in
            let raw = UserDefaults.standard.string(forKey: ControlPreferences.strategyKey) ?? "<nil>"
            print(String(format: "  t=%.1fs store=%@ persisted=%@ isManual=%@",
                         elapsed, store.strategy.rawValue, raw, store.isManual ? "true" : "false"))
        }

        let persisted = UserDefaults.standard.string(forKey: ControlPreferences.strategyKey) ?? "<nil>"
        print("--- 结论 ---")
        print("store.strategy = \(store.strategy.rawValue)（期望 fixed）")
        print("persisted     = \(persisted)（期望 fixed）")
        print(store.strategy == .fixed && persisted == "fixed"
              ? "PASS：租约失败没有改写用户策略"
              : "FAIL：策略被租约失败改掉了")
        print("message = \(store.message ?? "<nil>")")

        // 收尾：先返还系统控制，再还原用户的持久值
        store.release()
        spin(seconds: 1) { _ in }
        ControlPreferences().strategy = originalStrategy
        ControlPreferences().fixedRpm = originalRpm
        print("--- 收尾：持久值还原为 \(originalStrategy.rawValue) / \(Int(originalRpm)) ---")
    }

    // MARK: - 启动链复刻

    /// 预置持久值，然后照 App 的方式跑一遍启动，观察 N 秒后策略有没有被改掉。
    private static func runLaunch(desired: String?) {
        let prefs = ControlPreferences()
        let originalStrategy = prefs.strategy
        let originalRpm = prefs.fixedRpm

        if let desired, let value = ControlStrategy(rawValue: desired) {
            // 直接写盘：这一步模拟「用户上次选了 X 然后退出」
            prefs.strategy = value
            print("已把持久值预置为 \(value.rawValue)（原值 \(originalStrategy.rawValue)）")
        }
        dumpDefaults(label: "启动前")

        let store = ControlStore()
        print("init 恢复到的策略 = \(store.strategy.rawValue)  ← 读的这一步就对不上就说明问题在读")

        print("--- bootstrap（复刻 applicationDidFinishLaunching 的启动顺序）---")
        store.bootstrap()
        spin(seconds: 1) { _ in }

        if CommandLine.arguments.contains("force"), store.strategy != .automatic, !store.isManual {
            print("conflict=\(store.conflict.count) → 强制接管，把租约心跳跑起来")
            store.takeOverAnyway()
            spin(seconds: 1) { _ in }
            print("强制接管后 isManual = \(store.isManual)，message = \(store.message ?? "<nil>")")
        }

        // 主队列要靠 runloop 才转得起来：bootstrap 的回填和心跳失败都在 main 上
        spin(seconds: 12) { elapsed in
            let raw = UserDefaults.standard.string(forKey: ControlPreferences.strategyKey) ?? "<nil>"
            print(String(format: "  t=%.1fs store=%@ persisted=%@ helper=%@",
                         elapsed, store.strategy.rawValue, raw, describe(store.helperStatus)))
        }

        print("--- 观察结束 ---")
        print("store.strategy = \(store.strategy.rawValue)")
        print("persisted = \(UserDefaults.standard.string(forKey: ControlPreferences.strategyKey) ?? "<nil>")")
        print("message = \(store.message ?? "<nil>")")
        print("isManual = \(store.isManual)")

        // 收尾：把持久值还原成用户原来的，再把风扇交还系统自动
        if store.strategy != originalStrategy {
            store.strategy = originalStrategy
        }
        prefs.fixedRpm = originalRpm
        store.release()
        spin(seconds: 1.5) { _ in }
        print("--- 收尾后 persisted = \(UserDefaults.standard.string(forKey: ControlPreferences.strategyKey) ?? "<nil>") ---")
    }

    private static func spin(seconds: TimeInterval, tick: (TimeInterval) -> Void) {
        let start = Date()
        var nextReport = 0.5
        while Date().timeIntervalSince(start) < seconds {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            let elapsed = Date().timeIntervalSince(start)
            if elapsed >= nextReport {
                tick(elapsed)
                nextReport += 0.5
            }
        }
    }

    private static func dumpDefaults(label: String) {
        let defaults = UserDefaults.standard
        print("[\(label)] strategyKey = \(describe(defaults.object(forKey: ControlPreferences.strategyKey)))"
              + "  fixedRpmKey = \(describe(defaults.object(forKey: ControlPreferences.fixedRpmKey)))")
        print("[\(label)] fresh ControlPreferences.strategy = \(ControlPreferences().strategy.rawValue)")
    }

    private static func describe(_ status: ControlStore.HelperStatus) -> String {
        switch status {
        case .checking: return "checking"
        case .available(let count): return "available(\(count))"
        case .unavailable: return "unavailable"
        }
    }

    private static func describe(_ value: Any?) -> String {
        guard let value else { return "<nil>" }
        return "\(value)"
    }
}
