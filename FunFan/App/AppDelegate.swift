import AppKit
import SwiftUI
import Combine
import FunFanCore

/// 应用入口：菜单栏常驻，无 Dock 图标。
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {

    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let monitor = MonitorStore()
    private let control = ControlStore()
    private let rules = RulesStore()
    private let lid = LidMonitor()
    private let diagnostics = DiagnosticsStore()

    private var rulesWindow: NSWindow?
    private var popoverVisible = false
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

        // 规则自动化接线：每帧快照 → 控制层评估 → 必要时经 XPC 下发
        control.bindRules { [weak self] in self?.rules.currentRules() ?? [] }
        monitor.onSnapshot = { [weak self] snapshot in
            self?.control.handleSnapshot(snapshot)
        }

        // 规则策略需要更快的采样（1 s），其余情况沿用菜单栏档位
        control.$strategy
            .sink { [weak self] _ in self?.refreshVisibility() }
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

        monitor.start()
        control.bootstrap()

        // 调试/验收用：`FunFan --rules-window` 直接打开规则窗口，省去点菜单栏
        if CommandLine.arguments.contains("--rules-window") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.showRulesWindow()
            }
        }
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
        button.title = cpu.map { String(format: " %.0f°", $0) } ?? ""
    }

    // MARK: - Popover

    private func setupPopover() {
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: MenuBarView(
                monitor: monitor,
                control: control,
                diagnostics: diagnostics,
                onOpenRules: { [weak self] in self?.showRulesWindow() },
                onQuit: { NSApp.terminate(nil) }
            )
        )
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func popoverDidShow(_ notification: Notification) {
        popoverVisible = true
        refreshVisibility()
    }

    func popoverDidClose(_ notification: Notification) {
        popoverVisible = false
        refreshVisibility()
    }

    /// 采样频率：面板打开 > 规则接管 > 仅菜单栏。
    private func refreshVisibility() {
        let visibility: SamplingPolicy.Visibility
        if popoverVisible {
            visibility = .popoverOpen
        } else if control.strategy == .rules {
            visibility = .automation
        } else {
            visibility = .menuBarOnly
        }
        monitor.setVisibility(visibility)
    }

    // MARK: - 规则窗口

    private func showRulesWindow() {
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

    // MARK: - 系统事件

    private func observeSystemEvents() {
        let center = NSWorkspace.shared.notificationCenter

        // 睡眠前返还，唤醒后重建 SMC 连接（睡眠会失效）
        center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.control.release()
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
        }
        lid.start()
    }
}
