import AppKit
import SwiftUI
import Combine
import FunFanCore

/// 应用入口：菜单栏常驻，无 Dock 图标。
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {

    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var popoverHosting: NSHostingController<AnyView>?
    private var popoverRootView: AnyView?
    private var popoverContentCleared = false
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
    private var clickMonitors: [Any] = []
    private var signalSources: [DispatchSourceSignal] = []
    private var cancellables = Set<AnyCancellable>()

    // MARK: - 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 菜单栏工具：无 Dock 图标、无主窗口
        NSApp.setActivationPolicy(.accessory)

        setupStatusItem()
        setupPopover()
        observeSystemEvents()
        installSignalHandlers()

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

        // 自动化策略用引擎档（1 s），其余情况沿用菜单栏档位
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

        // 外观切换：设置页一改就贴到所有已存在的窗口（含设置窗口自己）。
        settings.onAppearanceChange = { [weak self] appearance in
            self?.applyAppearance(appearance)
        }

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
        ControlJournal.write("退出：当前策略 \(control.strategy.rawValue)（返还系统控制）")
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
        // 改成 `.applicationDefined` 后 AppKit 不再自作主张，关不关由我们自己判
        // （`handleMouseDown` 分流 + `togglePopover` 用按下瞬间的状态做决策）。
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.delegate = self

        let rootView = AnyView(
            MenuBarView(
                monitor: monitor,
                control: control,
                diagnostics: diagnostics,
                installer: helperInstaller,
                onOpenRules: { [weak self] in self?.showRulesWindow() },
                onOpenCurve: { [weak self] in self?.showCurveWindow() },
                onOpenSettings: { [weak self] in self?.showSettingsWindow() },
                onQuit: { NSApp.terminate(nil) }
            )
            // 色令牌由根视图注入（见 Theme.swift）。必须挂在 rootView 上：
            // 子视图靠 `@Environment(\.palette)` 取，漏了就会落回深色兜底。
            .funfanTheme()
        )
        popoverRootView = rootView

        let hosting = NSHostingController(rootView: rootView)
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

        installClickRouter()
    }

    /// 菜单栏图标的开/关切换。
    ///
    /// 关键：**决策依据是「鼠标按下那瞬间」的状态，不是这时的 `popover.isShown`**。
    /// 按下和抬起之间隔着整个按钮 track，这段时间里面板可能已经被关过一次
    /// （AppKit 的 `.transient` 会自动关，我们自己的「点外面关闭」也可能误判）。
    /// 一读当前状态就会被骗：本来要关，读成「已经关了」→ 又给打开。
    ///
    /// 用按下时的状态就永远正确：该关就关（`closePopover` 幂等，关两次也只关一次），
    /// 该开就开，不受中间发生过什么影响。
    @objc private func togglePopover() {
        let now = ProcessInfo.processInfo.systemUptime
        let wasShown: Bool
        if let record = stateAtMouseDown, now - record.at < Self.clickActionWindow {
            wasShown = record.shown
        } else {
            // 没有 mouseDown 前情：键盘 / 辅助功能（VoiceOver）触发的 action
            wasShown = isPopoverVisible
        }
        stateAtMouseDown = nil

        PopoverClickLog.write("action wasShown=\(wasShown) isShown=\(popover.isShown)")
        if wasShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        // 关闭时换成了空白占位（见 popoverDidClose），打开前挂回真内容。
        if popoverContentCleared, let rootView = popoverRootView {
            popoverHosting?.rootView = rootView
            popoverContentCleared = false
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 关掉面板。不看 `isShown` 再动手：状态可能已经被别处改过，
    /// 而 `performClose` 本身就是幂等的（没开就什么都不做）。
    private func closePopover() {
        PopoverClickLog.write("close isShown=\(popover.isShown) visible=\(isPopoverVisible)")
        popover.performClose(nil)
        // 取证：如果「关完还在」，日志会写下 close-done visible=true ——
        // 那就说明问题不在判断逻辑，而在 performClose 本身没生效。
        guard PopoverClickLog.isEnabled else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            PopoverClickLog.write("close-done visible=\(self.isPopoverVisible)")
        }
    }

    /// 面板是不是真的在屏幕上。
    ///
    /// 为什么不只信 `popover.isShown`：`show` 与 `close` 撞在一起时它会短暂说谎，
    /// 而按它做的决定（该关却以为已关）正是「点几下才关得掉」的另一条来源。
    /// 窗口 `isVisible` 是硬事实，两者取或。
    private var isPopoverVisible: Bool {
        if popover.isShown { return true }
        return popover.contentViewController?.view.window?.isVisible ?? false
    }

    // MARK: - 点击路由

    /// 一次点击在「按下那瞬间」的面板状态。
    private var stateAtMouseDown: (shown: Bool, at: TimeInterval)?

    /// 按下到抬起正常 < 0.3 s；给到 2 s 只为容忍「按住不放再抬起」。
    /// 超过窗口就当没有前情，回落到当前状态（键盘 / 辅助功能触发）。
    private static let clickActionWindow: TimeInterval = 2.0

    /// 自己实现「点外面关闭」：面板是 `.applicationDefined`，不装这些监视器就永远关不掉。
    ///
    /// 本地监视器在事件派发给窗口**之前**回调，所以「记状态」一定发生在
    /// 任何可能的关闭动作之前 —— 这是 `togglePopover` 能读到干净状态的前提。
    private func installClickRouter() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]

        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.handleMouseDown(event)
            return event // 始终放行：图标要能高亮，控件要能收到点击
        }) {
            clickMonitors.append(local)
        }

        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            guard let self else { return }

            // 菜单栏图标本身也会被这条监视器看到 —— 真机日志实证：同一个物理点击，
            // 全局先到（因为菜单栏由系统托管，点击得先经过外面再转给我们），
            // 本地事件 30~70 ms 后才到。若这里按「点外面」关掉面板，
            // 紧接着到达的本地事件又会把它当「打开」——一次点击被处理成
            // 「关 + 开」，表现就是点几下都关不掉。所以图标上的点击一律放行。
            if PopoverClickLog.isEnabled {
                PopoverClickLog.write(
                    "global down onIcon=\(self.isCursorOnStatusItem) "
                        + "mouse=\(NSEvent.mouseLocation) rect=\(String(describing: self.statusItemRectOnScreen))"
                )
            }
            if self.isCursorOnStatusItem {
                PopoverClickLog.write("global down onIcon → skip（交给本地事件切）")
                self.notePendingIconClick()
                return
            }
            guard self.isPopoverVisible else { return }
            PopoverClickLog.write("global down → schedule close")
            self.scheduleDismiss()
        }) {
            clickMonitors.append(global)
        }

        // `.transient` 时 AppKit 顺手做了 ESC 关闭，改成自定义后得补回来
        if let escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            if event.keyCode == 53 { self?.closePopover() }
            return event
        }) {
            clickMonitors.append(escape)
        }
    }

    private func handleMouseDown(_ event: NSEvent) {
        let onIcon = isStatusItemClick(event)
        let shown = isPopoverVisible
        // 先记状态，再做任何可能改变状态的事
        stateAtMouseDown = (shown, ProcessInfo.processInfo.systemUptime)
        PopoverClickLog.write(
            "down type=\(event.type == .rightMouseDown ? "right" : "left") "
                + "onIcon=\(onIcon) shown=\(shown)"
        )

        if onIcon {
            // 本地事件接住了这一下，别让看门狗再切一次
            pendingIconClickAt = nil
            // …也别让全局监视器为这一下安排的「关闭」落地（几何判断万一失手，
            // 这条就把它救回来）
            pendingDismiss?.cancel()
            pendingDismiss = nil
            // 左键交给按钮的 action 切（辅助功能也走同一条路），这里不动手；
            // 右键当「取消」，直接关。
            if event.type == .rightMouseDown, shown { closePopover() }
            return
        }
        guard shown else { return }
        // 面板内部：不动
        if event.window === popover.contentViewController?.view.window { return }
        // 我们自己的其它窗口（规则 / 曲线 / 设置）
        closePopover()
    }

    /// 点的是不是菜单栏图标。
    ///
    /// 只比 `event.window === button.window` 不够稳：菜单栏是系统托管的宿主窗口，
    /// 事件报上来的 window 未必就是按钮自己那个。再按**屏幕坐标**兜一层 ——
    /// 落点在按钮矩形内就算点图标，与窗口身份无关。
    private func isStatusItemClick(_ event: NSEvent) -> Bool {
        if event.window === statusItem.button?.window { return true }
        return isCursorOnStatusItem
    }

    /// 光标此刻是否落在菜单栏图标上（屏幕坐标，与窗口身份无关）。
    private var isCursorOnStatusItem: Bool {
        guard let rect = statusItemRectOnScreen else { return false }
        return rect.contains(NSEvent.mouseLocation)
    }

    private var statusItemRectOnScreen: NSRect? {
        guard let button = statusItem.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    // MARK: - 图标点击的交接

    /// 全局监视器安排的「延迟关闭」。不立刻关是为了给同一个物理点击的本地事件
    /// 留一个反悔窗口（见 `handleMouseDown` 里的 `pendingDismiss?.cancel()`）。
    /// 80 ms 远小于人能察觉的延迟，但大于实测 27~70 ms 的交接间隔。
    private var pendingDismiss: DispatchWorkItem?

    /// 全局监视器先看到的那一下图标点击，等本地事件接手；等不到就自己切。
    ///
    /// 需要它是为了兜住「只给了全局事件」这种系统差异：那种情况下没人来开/关，
    /// 一次点击就白费了。正常路径下本地事件 30~70 ms 就到，会把这条标记清掉。
    private var pendingIconClickAt: TimeInterval?

    /// 交接窗口。真机实测全局比本地早 27~70 ms，给到 150 ms 有余量。
    private static let iconHandoverWindow: TimeInterval = 0.15

    private func scheduleDismiss() {
        pendingDismiss?.cancel()
        let delay = Self.globalDismissDelay
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isPopoverVisible else { return }
            PopoverClickLog.write("deferred global close → close")
            self.closePopover()
        }
        pendingDismiss = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private static let globalDismissDelay: TimeInterval = 0.08

    private func notePendingIconClick() {
        let now = ProcessInfo.processInfo.systemUptime
        pendingIconClickAt = now
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.iconHandoverWindow) { [weak self] in
            guard let self, let marked = self.pendingIconClickAt else { return }
            // 期间又来了新的一下：让它自己的定时器负责，这里不管。
            guard ProcessInfo.processInfo.systemUptime - marked >= Self.iconHandoverWindow - 0.01 else { return }
            self.pendingIconClickAt = nil
            PopoverClickLog.write("handover: 本地事件没来，自己切")
            self.togglePopover()
        }
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
        // 面板的窗口是 AppKit 在 show 时才建的，所以外观必须在这里补一次，
        // 否则用户切换外观后第一次打开面板仍是旧外观。
        applyAppearance(settings.appearance)
        refreshVisibility()
    }

    func popoverDidClose(_ notification: Notification) {
        popoverVisible = false
        // 关掉的 popover 窗口虽然不可见，里面的 SwiftUI 视图仍会按显示刷新率
        // 重排版（整棵 LazyStack 重算），空闲 CPU 从 1% 涨到 12%+（issue #3，
        // 已在 M2 真机验证：12~16% → 1.8~1.9%）。换成同尺寸空白视图把代价归零，
        // 下次打开前再挂回（见 showPopover）。
        //
        // 用「同尺寸」而不是零尺寸：`sizingOptions = [.preferredContentSize]`
        // 会在隐藏期间持续上报理想尺寸，占位为 0 会把 contentSize 改小，
        // 重开时先以极小尺寸显示再跳回，产生可见抖动。
        let size = popoverHosting?.preferredContentSize ?? .zero
        popoverHosting?.rootView = AnyView(
            Color.clear.frame(width: max(size.width, 1), height: max(size.height, 1))
        )
        popoverContentCleared = true
        refreshVisibility()
    }

    /// 采样频率：自动化接管（1 s）> 面板打开 = 仅菜单栏（2 s）> 合盖（5 s）。
    /// 自动化档排最前：引擎要控制响应；面板/菜单栏只是给人看的，2 s 够了。
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
            rootView: AnyView(RulesView(rules: rules, control: control).funfanTheme())
        )
        let window = NSWindow(contentViewController: hosting)
        window.title = "FunFan · 自动调速规则"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 560, height: 460))
        window.appearance = settings.appearance.nsAppearance
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
            rootView: AnyView(CurveEditorView(store: curve, control: control, monitor: monitor).funfanTheme())
        )
        let window = NSWindow(contentViewController: hosting)
        window.title = "FunFan · 温度曲线"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 640, height: 540))
        window.appearance = settings.appearance.nsAppearance
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
            rootView: AnyView(
                SettingsView(
                    settings: settings,
                    control: control,
                    diagnostics: diagnostics,
                    installer: helperInstaller
                )
                .funfanTheme()
            )
        )
        let window = NSWindow(contentViewController: hosting)
        window.title = "FunFan · 设置"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 540, height: 800))
        window.appearance = settings.appearance.nsAppearance
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        settingsWindow = window
    }

    // MARK: - 外观

    /// 把「跟随系统 / 浅色 / 深色」贴到每个窗口。
    ///
    /// 两个决定：
    /// 1. **不用 `NSApp.appearance`**。那是全局覆盖，菜单栏图标（模板图）和系统
    ///    弹出面板会一起反转，用户会觉得「整个系统都变了」，而设置里写的是
    ///    「本 App 的外观」；
    /// 2. **已存在的窗口要就地更新**，不能只影响新建窗口。否则用户点完「深色」，
    ///    已经开着的设置窗口还是浅的，得关掉重开——复审里「切换时机」那一条
    ///    要解决的就是这个。
    private func applyAppearance(_ appearance: SettingsStore.Appearance) {
        let ns = appearance.nsAppearance
        for window in [rulesWindow, curveWindow, settingsWindow].compactMap({ $0 }) {
            window.appearance = ns
        }
        popoverHosting?.view.window?.appearance = ns
    }

    // MARK: - 系统事件

    /// SIGTERM / SIGINT 也要走正常退出路径。
    ///
    /// 不接管的话，`make run` 里按 Ctrl-C、或者 `kill <pid>`，进程是直接死的：
    /// `applicationWillTerminate` 不执行 → 不调 `control.release()` → 风扇留在手动，
    /// 只能等 helper 的租约 TTL（10 s）兜底返还。开发循环里这 10 s 很要命：
    /// 紧接着重启的新实例会读到「手动 + 租约不是自己的」，被冲突检测判成第三方接管，
    /// 于是「策略对但没接管」——看起来像另一个 bug。
    ///
    /// 用 `DispatchSourceSignal` 而不是在信号处理函数里直接调 AppKit：
    /// 信号上下文里除了 async-signal-safe 的调用，别的都不保证能用。
    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                ControlJournal.write("收到信号 \(sig)：按正常退出处理（返还系统控制）")
                NSApp.terminate(nil)
            }
            source.resume()
            signalSources.append(source)
        }
    }

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
