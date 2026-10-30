import Foundation
import Combine
import FunFanCore

/// 控制侧：把用户选择翻译成 XPC 请求，交给特权 helper 执行。
///
/// GUI 永不持有 root——所有 SMC 写入都在 helper 进程内完成。
/// helper 未安装时优雅退化为「仅监控」，并在 UI 上明确告知。
final class ControlStore: ObservableObject {

    // MARK: - 策略

    enum Strategy: String, CaseIterable, Identifiable {
        case automatic
        case fixed
        case curve
        case rules

        var id: String { rawValue }

        var label: String {
            switch self {
            case .automatic: return "自动"
            case .fixed: return "固定"
            case .curve: return "曲线"
            case .rules: return "规则"
            }
        }

        /// 是否由本应用持续计算目标（需要更快的采样与规则/曲线引擎）。
        var isAutomated: Bool {
            self == .curve || self == .rules
        }
    }

    enum HelperStatus: Equatable {
        case checking
        case available(fanCount: Int)
        case unavailable

        var isReady: Bool {
            if case .available = self { return true }
            return false
        }
    }

    // MARK: - 对外状态

    @Published var strategy: Strategy = .automatic {
        didSet {
            guard strategy != oldValue else { return }
            if oldValue.isAutomated { teardownAutomation() }
            mirroredStrategy = strategy
            apply()
        }
    }

    @Published var fixedRpm: Double = 2000

    @Published private(set) var helperStatus: HelperStatus = .checking
    @Published private(set) var limits = FanLimits(minRpm: 1000, maxRpm: 4900)
    @Published private(set) var message: String?
    @Published private(set) var isManual = false

    /// 当前处于触发状态的规则（UI 高亮用）。
    @Published private(set) var triggeredRuleIDs: [UUID] = []
    /// 规则/曲线引擎当前下发的目标（nil = 未接管）。
    @Published private(set) var automatedRpm: Double?
    /// 曲线本身给出的目标（未过安全下限），用于编辑器里显示「你画的 vs 实际下发的」。
    @Published private(set) var curveRawRpm: Double?

    // MARK: - 内部

    private var transport: XPCTransport?
    private var controller: FanController?
    private let queue = DispatchQueue(label: "com.funfan.control", qos: .userInitiated)
    private var heartbeat: DispatchSourceTimer?

    /// 后台队列读取的镜像状态（避免跨线程读 `@Published`）。
    private var mirroredStrategy: Strategy = .automatic
    private var mirroredLimits = FanLimits(minRpm: 1000, maxRpm: 4900)
    private var mirroredHelperReady = false

    /// 规则来源（由 `RulesStore` 提供，线程安全方法）。
    private var rulesProvider: (() -> [FanRule])?
    private var automation = RuleAutomation()

    /// 曲线来源（由 `CurveStore` 提供，线程安全方法）。
    private var curveProvider: (() -> FanCurve)?
    private var curveAutomation = CurveAutomation(curve: FanCurve(points: []))

    /// 上一次快照时间：曲线引擎的斜率限制需要「距上次多少秒」。
    private var lastSnapshotAt: Date?

    /// 合盖期间挂起：返还系统自动，并拦住规则重新接管（只在控制队列上读写）。
    private var suspendedForLid = false

    /// 租约心跳间隔：helper 侧 TTL 10 s，2 s 一次足够容错。
    private let heartbeatInterval: TimeInterval = 2

    // MARK: - 启动

    func bootstrap() {
        queue.async { [weak self] in
            guard let self else { return }
            let transport = XPCTransport()
            let controller = FanController(transport: transport)

            do {
                let fans = try controller.listFans()
                self.transport = transport
                self.controller = controller
                self.mirroredHelperReady = true

                if let primary = fans.first {
                    let limits = primary.limits
                    self.mirroredLimits = limits
                    DispatchQueue.main.async {
                        self.limits = limits
                        self.fixedRpm = min(max(self.fixedRpm, limits.minRpm), limits.normalizedMax)
                    }
                }

                DispatchQueue.main.async {
                    self.helperStatus = .available(fanCount: fans.count)
                    self.message = "helper 已连接"
                }
            } catch {
                self.mirroredHelperReady = false
                DispatchQueue.main.async {
                    self.helperStatus = .unavailable
                    self.message = "未安装特权 helper，仅可监控"
                }
            }
        }
    }

    /// 绑定规则来源（通常传 `rules.currentRules`）。
    func bindRules(_ provider: @escaping () -> [FanRule]) {
        rulesProvider = provider
    }

    /// 绑定曲线来源（通常传 `curve.currentCurve`）。
    func bindCurve(_ provider: @escaping () -> FanCurve) {
        curveProvider = provider
    }

    // MARK: - 下发

    /// 按当前策略下发。helper 不可用时只提示，不发请求。
    func apply(forFan index: Int = 0) {
        guard helperStatus.isReady else {
            DispatchQueue.main.async {
                self.message = "未安装特权 helper，无法控制风扇"
            }
            return
        }

        let strategy = self.strategy
        let rpm = self.fixedRpm

        queue.async { [weak self] in
            guard let self, let controller = self.controller else { return }
            // 合盖期间只允许「返还」，不允许重新接管
            if self.suspendedForLid, strategy != .automatic { return }
            do {
                switch strategy {
                case .automatic:
                    try controller.restoreAuto(fanIndex: index)
                    self.stopHeartbeat()
                    DispatchQueue.main.async {
                        self.isManual = false
                        self.message = "已返还系统自动控制"
                    }

                case .fixed:
                    _ = try controller.refreshState(fanIndex: index)
                    _ = try controller.setTarget(rpm: rpm, fanIndex: index)
                    self.startHeartbeat()
                    DispatchQueue.main.async {
                        self.isManual = true
                        self.message = String(format: "已设为 %.0f RPM", rpm)
                    }

                case .rules:
                    // 规则模式不立即写入：等下一帧温度快照评估后决定是否接管。
                    // 这样「规则没触发」的场景不会白白占用手动模式。
                    DispatchQueue.main.async {
                        self.message = "规则监控中，温度越阈值时自动提速"
                    }

                case .curve:
                    // 曲线同理：曲线一定有值，但仍然等真正的温度快照，
                    // 避免用「上一次的温度」或猜测值写一次硬件。
                    DispatchQueue.main.async {
                        self.message = "曲线接管中，按当前温度映射转速"
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.message = Self.describe(error)
                }
            }
        }
    }

    // MARK: - 规则自动化

    /// 每帧采样回调（在监控队列上调用）。内部转到控制队列，避免阻塞采样。
    func handleSnapshot(_ snapshot: SensorSnapshot, fanIndex: Int = 0) {
        queue.async { [weak self] in
            guard let self else { return }
            // 只有自动化策略才评估；自动/固定下不做任何多余计算
            guard self.mirroredStrategy.isAutomated else { return }
            guard !self.suspendedForLid else { return }
            guard self.mirroredHelperReady, let controller = self.controller else { return }

            let now = Date()
            let die = snapshot.readings.map(\.celsius).max()

            switch self.mirroredStrategy {
            case .curve:
                // 斜率限制需要真实间隔；首帧或处理策略切换后按 1 s 处理（曲线引擎首帧本就直达）
                let elapsed = self.lastSnapshotAt.map { now.timeIntervalSince($0) } ?? 1
                self.lastSnapshotAt = now

                let curve = self.curveProvider?() ?? FanCurve(points: [])
                let command = self.curveAutomation.update(
                    curve: curve,
                    dieCelsius: die,
                    limits: self.mirroredLimits,
                    secondsElapsed: elapsed,
                    now: now
                )
                let raw = self.curveAutomation.rawCurveRpm
                let commanded = self.curveAutomation.lastCommandedRpm
                DispatchQueue.main.async {
                    self.curveRawRpm = raw
                    self.automatedRpm = commanded
                }
                self.execute(command, label: "曲线", controller: controller, fanIndex: fanIndex)

            case .rules:
                let rules = self.rulesProvider?() ?? []
                let command = self.automation.update(
                    snapshot: snapshot,
                    rules: rules,
                    limits: self.mirroredLimits,
                    now: now
                )
                let triggered = self.automation.triggeredRuleIDs
                let automated = self.automation.lastCommandedRpm
                DispatchQueue.main.async {
                    self.triggeredRuleIDs = triggered
                    self.automatedRpm = automated
                }
                self.execute(command, label: "规则", controller: controller, fanIndex: fanIndex)

            case .automatic, .fixed:
                return
            }
        }
    }

    /// 把闸门给出的命令落到硬件，并同步 UI 状态。规则与曲线共用。
    private func execute(
        _ command: ControlCommandGate.Command?,
        label: String,
        controller: FanController,
        fanIndex: Int
    ) {
        guard let command else { return }

        do {
            switch command {
            case .setRpm(let rpm):
                _ = try controller.refreshState(fanIndex: fanIndex)
                _ = try controller.setTarget(rpm: rpm, fanIndex: fanIndex)
                startHeartbeat()
                DispatchQueue.main.async {
                    self.isManual = true
                    self.message = String(format: "%@接管：%.0f RPM", label, rpm)
                }

            case .release:
                try controller.restoreAuto(fanIndex: fanIndex)
                stopHeartbeat()
                DispatchQueue.main.async {
                    self.isManual = false
                    self.message = "\(label)未接管，已返还系统自动"
                }
            }
        } catch {
            DispatchQueue.main.async {
                self.message = Self.describe(error)
            }
        }
    }

    /// 离开自动化策略：解除接管并清空迟滞/斜率状态。
    private func teardownAutomation() {
        queue.async { [weak self] in
            guard let self else { return }
            let wasActive = self.automation.isActive || self.curveAutomation.isActive
            self.automation.reset()
            self.curveAutomation.reset()
            self.lastSnapshotAt = nil
            if wasActive, let controller = self.controller {
                try? controller.restoreAuto(fanIndex: 0)
            }
            self.stopHeartbeat()
            DispatchQueue.main.async {
                self.isManual = false
                self.triggeredRuleIDs = []
                self.automatedRpm = nil
                self.curveRawRpm = nil
            }
        }
    }

    /// 退出 / 合盖 / 睡眠前必须调用。
    func release() {
        queue.async { [weak self] in
            guard let self, let controller = self.controller else { return }
            self.automation.reset()
            self.curveAutomation.reset()
            self.lastSnapshotAt = nil
            self.stopHeartbeat()
            try? controller.restoreAuto(fanIndex: 0)
        }
        DispatchQueue.main.async {
            self.isManual = false
            self.triggeredRuleIDs = []
            self.automatedRpm = nil
            self.curveRawRpm = nil
        }
    }

    // MARK: - 合盖

    /// 合盖：立刻返还系统自动，并在开盖前拒绝一切重新接管。
    ///
    /// 合盖后机身散热条件变差、也可能被塞进包里，继续锁着手动转速没有任何好处，
    /// 因此无条件返还（不看当前策略）。
    func suspendForLid() {
        queue.async { [weak self] in
            guard let self, !self.suspendedForLid else { return }
            self.suspendedForLid = true
            self.automation.reset()
            self.curveAutomation.reset()
            self.lastSnapshotAt = nil
            self.stopHeartbeat()
            if let controller = self.controller {
                try? controller.restoreAuto(fanIndex: 0)
            }
            DispatchQueue.main.async {
                self.isManual = false
                self.triggeredRuleIDs = []
                self.automatedRpm = nil
                self.curveRawRpm = nil
                self.message = self.suspendedMessage
            }
        }
    }

    /// 开盖：恢复接管。规则策略会在下一帧温度快照上重新评估，固定策略立即重新下发。
    func resumeAfterLid() {
        queue.async { [weak self] in
            guard let self, self.suspendedForLid else { return }
            self.suspendedForLid = false
        }
        switch strategy {
        case .automatic:
            DispatchQueue.main.async { self.message = "已开盖，继续系统自动控制" }
        case .fixed:
            DispatchQueue.main.async { self.message = "已开盖，恢复固定转速" }
            apply()
        case .curve:
            queue.async { [weak self] in
                self?.curveAutomation.reset()
                self?.lastSnapshotAt = nil
                DispatchQueue.main.async { self?.message = "已开盖，曲线恢复接管" }
            }
        case .rules:
            queue.async { [weak self] in
                self?.automation.reset()
                DispatchQueue.main.async { self?.message = "已开盖，规则恢复监控" }
            }
        }
    }

    private var suspendedMessage: String {
        strategy == .automatic ? "已合盖：系统自动控制" : "已合盖：已返还系统自动控制"
    }

    // MARK: - 租约心跳

    private func startHeartbeat() {
        guard heartbeat == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + heartbeatInterval, repeating: heartbeatInterval)
        timer.setEventHandler { [weak self] in
            guard let self, let transport = self.transport else { return }
            if !transport.heartbeat() {
                // 租约已失效：helper 已自行返还，GUI 侧同步状态
                self.stopHeartbeat()
                self.automation.noteExternallyReleased()
                self.curveAutomation.noteExternallyReleased()
                DispatchQueue.main.async {
                    self.isManual = false
                    self.strategy = .automatic
                    self.message = "租约过期，已自动返还系统控制"
                }
            }
        }
        timer.resume()
        heartbeat = timer
    }

    private func stopHeartbeat() {
        heartbeat?.cancel()
        heartbeat = nil
    }

    // MARK: - 错误文案

    static func describe(_ error: Error) -> String {
        guard let e = error as? FunFanError else { return "\(error)" }
        switch e {
        case .smcAccessDenied: return "SMC 访问被拒绝"
        case .keyNotFound(let key): return "当前机型无此键：\(key)"
        case .dataTypeUnsupported(let type): return "不支持的数据类型：\(type)"
        case .decodeFailed(let key, _): return "解码失败：\(key)"
        case .thermalManagerRefused: return "系统拒绝了手动写入"
        case .helperUnavailable: return "特权 helper 不可用"
        case .invalidTargetRpm(let rpm): return "目标转速非法：\(rpm)"
        }
    }
}
