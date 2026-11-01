import AppKit
import SwiftUI
import Combine
import FunFanCore

/// 应用入口：菜单栏常驻，无 Dock 图标。
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {

    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var popoverHosting: NSHostingController<MenuBarView>?
    private var popoverSizeObservation: NSKeyValueObservation?
    private let monitor = MonitorStore()
    private let control = ControlStore()
    private let rules = RulesStore()
    private let curve = CurveStore()
    private let lid = LidMonitor()
    private let diagnostics = DiagnosticsStore()
    private let settings = SettingsStore()
    private let helperInstaller = HelperInstaller()

    private var rulesWindow: NSWindow?
    private var curveWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var popoverVisible = false
    private var dismissMonitors: [Any] = []
    private var cancellables = Set<AnyCancellable>()

    // MARK: - 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 菜单栏工具：无 Dock 图标、无主窗口
        NSApp.setActivationPolicy(.accessory)

        setupStatusItem()
        setupPopover()
        observeSystemEvents()

        monitor.onSample = { [weak self] cpu in
            self?.updateTitle(cpu: cpu)
        }

        // 规则/曲线自动化接线：每帧快照 → 控制层评估 → 必要时经 XPC 下发
        control.bindRules { [weak self] in self?.rules.currentRules() ?? [] }
        control.bindCurve { [weak self] in self?.curve.currentCurve() ?? FanCurve(points: []) }
        monitor.onSnapshot = { [weak self] snapshot in
            self?.control.handleSnapshot(snapshot)
        }

        // 真实风扇区间到达后，按机型重排预设曲线（自定义曲线不受影响）
        control.$limits
            .sink { [weak self] limits in self?.curve.updateLimits(limits) }
            .store(in: &cancellables)

        // 自动化策略需要更快的采样（1 s），其余情况沿用菜单栏档位
        control.$strategy
            .sink { [weak self] _ in self?.refreshVisibility() }
            .store(in: &cancellables)

        // 菜单栏标题跟随「显示温度」开关（关掉后只留图标）
        settings.$showsMenuBarTemperature
            .sink { [weak self] _ in
                guard let self else { return }
                self.updateTitle(cpu: self.monitor.cpuAverage)
            }
            .store(in: &cancellables)

        // 能力出错（helper 不可用 / 连不上）时自动落一份系统信息，
        // 用户报 bug 时直接取文件，不用再教他跑命令。
        control.$helperStatus
            .sink { [weak self] status in
                guard case .unavailable = status else { return }
                self?.diagnostics.captureOnFailure(
                    "特权 helper 不可用",
                    context: ["stage": "ControlStore.bootstrap"]
                )
            }
            .store(in: &cancellables)

        // 装好/卸掉后台组件后必须重连一次，否则界面还停在「只能监控」。
        // 刚 bootstrap 的 daemon 有时还没把 Mach service 注册好，所以重试一次。
        helperInstaller.$completionTick
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.control.bootstrap()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                    guard let self, !self.control.helperStatus.isReady else { return }
                    self.control.bootstrap()
                }
            }
            .store(in: &cancellables)

        monitor.start()
        control.bootstrap()

        // 调试/验收用：`FunFan --rules-window` / `--curve-window` 直接开窗，省去点菜单栏
        if CommandLine.arguments.contains("--rules-window") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.showRulesWindow()
            }
        }
        if CommandLine.arguments.contains("--curve-window") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.showCurveWindow()
            }
        }
        if CommandLine.arguments.contains("--settings-window") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.showSettingsWindow()
            }
        }

        // 验收用：`FunFan --strategy curve` 启动即进入指定策略。
        // 存在意义是让「策略接管」可被无人值守验证——切换后目标值可以直接
        // 用 `funfanctl status` 读到，不必有人站在屏幕前点分段控件。
        // 延迟 1.5 s 是为了等 bootstrap 把 XPC 连接建起来，否则首次 apply 会落空。
        if let requested = Self.launchStrategy() {
            let rpm = Self.launchRPM()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                if let rpm { self.control.fixedRpm = rpm }
                self.control.strategy = requested
                NSLog("FunFan: 已按启动参数切到策略 \(requested.rawValue)")
            }
        }

        // 验收用：`--simulate-lid closed|open|cycle` 注入合盖信号。
        // 台式机没有盖子，真实信号永不产生；但「接管 → 合盖返还 → 拒绝重新接管 →
        // 开盖恢复」这条链必须能验，否则只能等一台笔记本。
        if let simulation = Self.launchLidSimulation() {
            runLidSimulation(simulation)
        }
    }

    // MARK: - 合盖模拟（验收用）

    private enum LidSimulation {
        case closed
        case open
        /// 先合盖再开盖，一条命令验完整个往返
        case cycle
    }

    private static func launchLidSimulation() -> LidSimulation? {
        guard let index = CommandLine.arguments.firstIndex(of: "--simulate-lid"),
              CommandLine.arguments.indices.contains(index + 1) else { return nil }
        switch CommandLine.arguments[index + 1] {
        case "closed": return .closed
        case "open": return .open
        case "cycle": return .cycle
        default: return nil
        }
    }

    /// 时间点刻意排在 `--strategy`（1.5 s 生效）之后，才能验到「已接管被合盖打断」。
    private func runLidSimulation(_ simulation: LidSimulation) {
        func inject(_ closed: Bool, at seconds: TimeInterval) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                NSLog("FunFan: 模拟合盖 = \(closed)")
                self?.lid.force(closed: closed)
            }
        }
        switch simulation {
        case .closed:
            inject(true, at: 3)
        case .open:
            inject(false, at: 3)
        case .cycle:
            inject(true, at: 3)
            inject(false, at: 11)
        }
    }

    // MARK: - 启动参数

    /// 解析 `--strategy <automatic|fixed|curve|rules>`，非法值返回 `nil`（保持默认自动）。
    private static func launchStrategy() -> ControlStore.Strategy? {
        guard let index = CommandLine.arguments.firstIndex(of: "--strategy"),
              CommandLine.arguments.indices.contains(index + 1) else { return nil }
        return ControlStore.Strategy(rawValue: CommandLine.arguments[index + 1])
    }

    /// 解析 `--rpm <数值>`，仅在 `--strategy fixed` 时有意义。
    private static func launchRPM() -> Double? {
        guard let index = CommandLine.arguments.firstIndex(of: "--rpm"),
              CommandLine.arguments.indices.contains(index + 1) else { return nil }
        return Double(CommandLine.arguments[index + 1])
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 退出必须返还系统自动，否则风扇会被留在手动模式
        control.release()
        monitor.stop()
        lid.stop()
    }

    // MARK: - 状态栏

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }

        let image = NSImage(
            systemSymbolName: "fanblades.fill",
            accessibilityDescription: "FunFan"
        )
        image?.isTemplate = true
        button.image = image
        button.imagePosition = .imageLeading
        button.title = ""
        button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        button.target = self
        button.action = #selector(togglePopover)
        button.sendAction(on: [.leftMouseUp])
    }

    private func updateTitle(cpu: Double?) {
        guard let button = statusItem.button else { return }
        // 设置里关掉「菜单栏显示温度」时只留图标，给菜单栏省出空间
        guard settings.showsMenuBarTemperature else {
            button.title = ""
            return
        }
        button.title = cpu.map { String(format: " %.0f°", $0) } ?? ""
    }

    // MARK: - Popover

    private func setupPopover() {
        // 关闭时机必须自己管，不能用 `.transient`。
        //
        // `.transient` 的语义是「点到面板以外就关」，而菜单栏图标本身也算「以外」，
        // 于是 AppKit 在**鼠标按下**那一刻就把面板关掉了；而 NSStatusItem 的 action
        // 配的是 `.leftMouseUp`，等它跑起来读到的 `isShown` 已经是 false ——
        // `togglePopover()` 误判成「用户要打开」，把刚关掉的面板又弹回来，
        // 表现就是「图标只会显示、永远关不掉」（中间还闪一下）。
        //
        // 改成 `.applicationDefined` 后，AppKit 不再自作主张，点击归属由
        // `handleClick(_:isGlobal:)` 判定：点图标交给 action 切换，点别处才关。
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.delegate = self

        let hosting = NSHostingController(
            rootView: MenuBarView(
                monitor: monitor,
                control: control,
                diagnostics: diagnostics,
                installer: helperInstaller,
                onOpenRules: { [weak self] in self?.showRulesWindow() },
                onOpenCurve: { [weak self] in self?.showCurveWindow() },
                onOpenSettings: { [weak self] in self?.showSettingsWindow() },
                onQuit: { NSApp.terminate(nil) }
            )
        )
        // 让 hosting 自己把理想尺寸报上来，否则 popover 会一直用首次显示时的固定高度
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popoverHosting = hosting

        // 内容高度是会变的（展开各核心温度、冲突提示条出现/消失），
        // 而 NSPopover 只在 show 的那一刻量一次尺寸 —— 不同步的话，展开后的内容
        // 会画在可视区外面，用户看到的就是「点了没反应」。
        popoverSizeObservation = hosting.observe(\.preferredContentSize, options: [.new]) { [weak self] _, change in
            guard let size = change.newValue, size.height > 0 else { return }
            DispatchQueue.main.async {
                guard let self, self.popover.isShown else { return }
                guard abs(self.popover.contentSize.height - size.height) > 0.5 else { return }
                self.popover.contentSize = size
            }
        }

        installDismissMonitors()
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            closePopover()
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func closePopover() {
        guard popover.isShown else { return }
        popover.performClose(nil)
    }

    // MARK: - Popover 关闭时机

    /// 自己实现「点外面关闭」：面板是 `.applicationDefined`，不装这些监视器就永远关不掉。
    ///
    /// 本地监视器在事件派发给窗口**之前**回调，所以不会被 AppKit 抢先关面板，
    /// 也就不会出现 `.transient` 那种「按下关、抬起又开」的时序事故。
    private func installDismissMonitors() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]

        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            // 点到我们自己 App 的窗口：判定后原样放行，别吃掉控件点击
            self?.handleClick(event, isGlobal: false)
            return event
        }) {
            dismissMonitors.append(local)
        }

        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            // 点到别的 App / 桌面：全局监视器拿不到事件本身，一律当「点外面」
            self?.handleClick(nil, isGlobal: true)
        }) {
            dismissMonitors.append(global)
        }

        // `.transient` 时 AppKit 顺手做了 ESC 关闭，改成自定义后得补回来
        if let escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            if event.keyCode == 53 { self?.closePopover() }
            return event
        }) {
            dismissMonitors.append(escape)
        }
    }

    private func handleClick(_ event: NSEvent?, isGlobal: Bool) {
        guard popover.isShown else { return }

        // 别的 App 里的点击（全局监视器不交事件本体）：直接关
        guard !isGlobal, let event else {
            closePopover()
            return
        }

        let window = event.window
        // 面板内部：不动
        if window === popover.contentViewController?.view.window { return }
        // 菜单栏图标：左键交给 `togglePopover` 自己切换（它知道当前状态），右键当「取消」
        if window === statusItem.button?.window {
            if event.type == .rightMouseDown { closePopover() }
            return
        }
        // 我们自己的其它窗口（规则 / 曲线 / 设置）
        closePopover()
    }

    func popoverDidShow(_ notification: Notification) {
        popoverVisible = true
        // 上次关掉时如果停在「展开各核心温度」，重开必须按展开后的高度显示，
        // 否则内容会被按旧高度裁掉。这里在 show 之后补一次同步。
        if let hosting = popoverHosting {
            let size = hosting.preferredContentSize
            if size.height > 0, abs(popover.contentSize.height - size.height) > 0.5 {
                popover.contentSize = size
            }
        }
        refreshVisibility()
    }

    func popoverDidClose(_ notification: Notification) {
        popoverVisible = false
        refreshVisibility()
    }

    /// 采样频率：合盖 > 面板打开 > 自动化接管（规则/曲线）> 仅菜单栏。
    private func refreshVisibility() {
        let visibility: SamplingPolicy.Visibility
        if lid.isClosed {
            // 合盖：屏幕全黑，自动化引擎也已挂起，按空闲档（5 s）采样即可
            visibility = .idle
        } else if popoverVisible {
            visibility = .popoverOpen
        } else if control.strategy.isAutomated {
            visibility = .automation
        } else {
            visibility = .menuBarOnly
        }
        monitor.setVisibility(visibility)
    }

    // MARK: - 规则窗口

    private func showRulesWindow() {
        // 面板改成 `.applicationDefined` 后不再「一失焦就自己关」，
        // 从这里跳出去开窗时必须顺手关掉，否则面板会赖在菜单栏下面。
        closePopover()
        if let window = rulesWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(
            rootView: RulesView(rules: rules, control: control)
        )
        let window = NSWindow(contentViewController: hosting)
        window.title = "FunFan · 自动调速规则"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 560, height: 460))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        rulesWindow = window
    }

    // MARK: - 曲线窗口

    private func showCurveWindow() {
        closePopover()
        if let window = curveWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(
            rootView: CurveEditorView(store: curve, control: control, monitor: monitor)
        )
        let window = NSWindow(contentViewController: hosting)
        window.title = "FunFan · 温度曲线"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 640, height: 540))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        curveWindow = window
    }

    // MARK: - 设置窗口

    private func showSettingsWindow() {
        closePopover()
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(
            rootView: SettingsView(
                settings: settings,
                control: control,
                diagnostics: diagnostics,
                installer: helperInstaller
            )
        )
        let window = NSWindow(contentViewController: hosting)
        window.title = "FunFan · 设置"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 540, height: 700))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        settingsWindow = window
    }

    // MARK: - 系统事件

    private func observeSystemEvents() {
        let center = NSWorkspace.shared.notificationCenter

        // 切换到别的 App（⌘Tab / Mission Control）时关掉面板。
        // `.transient` 原本由 AppKit 负责，现在归我们自己：全局鼠标监视器只能覆盖
        // 「点一下」这一种离开方式，纯键盘切走得靠这条通知兜住。
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.closePopover()
        }

        // 用户去「系统设置 → 登录项与扩展」批准后台项后会切回来，
        // 这时必须重读一次状态，否则设置页一直停在「待批准」。
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.helperInstaller.refresh()
        }

        // 睡眠前返还，唤醒后重建 SMC 连接（睡眠会失效）
        center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // 用「挂起」而不是裸 release：睡眠期间必须拒绝重新接管，
            // 否则采样线程可能在最后一帧把风扇又锁回手动转速
            self?.control.suspendForSleep()
        }

        center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.monitor.restart()
            self?.control.bootstrap()
            // 唤醒后若盖子是开的，恢复正常接管（合盖带外接屏不睡，靠下面这条兜住）
            if self?.lid.isClosed == false {
                self?.control.resumeAfterLid()
            }
        }

        // 合盖检测：带外接屏合盖时系统不睡，只能靠内建屏消失来判定
        lid.onChange = { [weak self] closed in
            guard let self else { return }
            if closed {
                self.control.suspendForLid()
            } else {
                self.control.resumeAfterLid()
            }
            // 合盖后屏幕全黑，采样降到最低档
            self.refreshVisibility()
        }
        lid.start()
    }
}
