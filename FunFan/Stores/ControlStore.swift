import Foundation
import Combine
import FunFanCore

/// 控制侧：把用户选择翻译成 XPC 请求，交给特权 helper 执行。
///
/// GUI 永不持有 root——所有 SMC 写入都在 helper 进程内完成。
/// helper 未安装时优雅退化为「仅监控」，并在 UI 上明确告知。
final class ControlStore: ObservableObject {

    // MARK: - 策略

    /// 策略枚举定义在 `FunFanCore.ControlStrategy`：持久化与 UI 必须共用同一份
    /// `rawValue`，放在 App 里就没法用单测把它钉住。
    typealias Strategy = ControlStrategy

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
            // 恢复上次设置时不写回：值本来就是从磁盘读的，再写一遍没有意义，
            // 而且此刻 helper 还没连上，apply() 会先弹一条「无法控制」的错误。
            guard !isRestoringPreferences else {
                mirroredStrategy = strategy
                return
            }
            ControlJournal.write("用户改策略：\(oldValue.rawValue) → \(strategy.rawValue)（落盘）")
            prefs.strategy = strategy
            recovery.reset()
            if oldValue.isAutomated { teardownAutomation() }
            mirroredStrategy = strategy
            apply()
        }
    }

    @Published var fixedRpm: Double = ControlPreferences.defaultFixedRpm {
        didSet {
            guard fixedRpm != oldValue, !isRestoringPreferences else { return }
            prefs.fixedRpm = fixedRpm
        }
    }

    /// 调速依据：最高温 / 均温。
    ///
    /// 它同时改变曲线的插值输入与安全下限的锚点，所以切换时必须把两个引擎的
    /// 迟滞/斜率状态清掉——否则引擎会拿「上一个是峰值口径」的历史温度去比对
    /// 这一帧的均温，凭空多出十几度的落差，迟滞判定就失效了。
    @Published var temperatureAggregation: TemperatureAggregation = .peak {
        didSet {
            guard temperatureAggregation != oldValue else { return }
            guard !isRestoringPreferences else { return }
            prefs.temperatureAggregation = temperatureAggregation
            ControlJournal.write("用户改调速依据：\(oldValue.rawValue) → \(temperatureAggregation.rawValue)（落盘）")
            let newValue = temperatureAggregation
            queue.async { [weak self] in
                guard let self else { return }
                self.mirroredAggregation = newValue
                self.automation.reset()
                self.curveAutomation.reset()
                self.lastSnapshotAt = nil
                DispatchQueue.main.async {
                    // 闸门已清空，「正在下发」的显示要跟着归零，否则残留上一轮的目标
                    self.automatedRpm = nil
                    self.curveRawRpm = nil
                }
            }
        }
    }

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

    /// 检测到的第三方接管证据（空数组 = 无冲突）。
    ///
    /// 判据只有一条：我们没持租约，但风扇处于手动模式。谁在写不重要，
    /// 重要的是**不能两个程序同时写同一个风扇**，否则转速会来回跳。
    @Published private(set) var conflict: [ForeignControlEvidence] = []
    /// 冲突来源的可读名字（识别不到时为 nil，不影响拦截）。
    @Published private(set) var conflictSource: String?

    // MARK: - 内部

    private var transport: XPCTransport?
    private var controller: FanController?
    private let queue = DispatchQueue(label: "cn.lovexiaov.fun.fan.control", qos: .userInitiated)
    private var heartbeat: DispatchSourceTimer?

    /// 上次设置的落盘入口。
    private let prefs: ControlPreferences
    /// 恢复期间抑制 `didSet` 的副作用（不写盘、不 apply）。
    private var isRestoringPreferences = true

    /// 后台队列读取的镜像状态（避免跨线程读 `@Published`）。
    private var mirroredStrategy: Strategy = .automatic
    private var mirroredLimits = FanLimits(minRpm: 1000, maxRpm: 4900)
    private var mirroredHelperReady = false
    private var mirroredAggregation: TemperatureAggregation = .peak

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

    /// 冲突拦截的队列侧镜像（只在控制队列读写）。
    private var mirroredConflictBlocked = false

    /// 租约心跳间隔：helper 侧 TTL 10 s，2 s 一次足够容错。
    private let heartbeatInterval: TimeInterval = 2

    /// 心跳代次。`stopHeartbeat()` 会 +1，让**已经在队列里排队**的 tick 直接作废。
    ///
    /// 少这一层就有一条缝：定时器被取消/或者我们刚 `restoreAuto` 清掉 helper 租约，
    /// 而在途的 tick 紧接着跑到 helper —— 那边已经没有租约，`heartbeat()` 返回 false，
    /// 旧代码据此把用户策略改成「自动」并落盘。一次瞬时抖动就这样变成了永久设置。
    private var heartbeatGeneration = 0

    /// 租约断开后的重连节奏（有界退避）。只允许在主线程读写。
    private var recovery = ControlRecoveryPolicy()

    // MARK: - 启动

    /// 恢复上次的策略与固定转速。
    ///
    /// 为什么在 init 里恢复而不是等 bootstrap：分段控件与滑块的**首帧**就该是用户
    /// 上次看到的样子，否则会先闪一下「自动 / 2000」再跳回去。
    /// 真正的接管不在这里做——`bootstrap()` 连上 helper 之后才 apply，
    /// 固不固定、能不能控，要等硬件区间和冲突检测都有结论。
    init(preferences: ControlPreferences = ControlPreferences()) {
        self.prefs = preferences
        strategy = preferences.strategy
        fixedRpm = preferences.fixedRpm
        temperatureAggregation = preferences.temperatureAggregation
        mirroredStrategy = strategy
        mirroredAggregation = temperatureAggregation
        isRestoringPreferences = false
        ControlJournal.sessionStart(strategy: strategy.rawValue)
    }

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

                // 冲突检测：持有租约（唤醒重连）时的手动模式是我们自己造成的，
                // 只有「没租约却处于手动」才说明有第三方在写。
                let evidence = ConflictDetector.foreignEvidence(
                    in: fans,
                    holdingControl: self.heartbeat != nil
                )
                self.mirroredConflictBlocked = !evidence.isEmpty

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
                    if evidence.isEmpty {
                        self.conflict = []
                        self.conflictSource = nil
                        self.message = "helper 已连接"
                        // 连上了就说明通道恢复：退避计数归零，下次断开重新从 2 s 起
                        self.recovery.reset()
                        ControlJournal.write("helper 已连接（策略 \(self.strategy.rawValue)）")
                    } else {
                        self.conflict = evidence
                        // 进程名单只用来解释原因，识别不到也照样拦。
                        self.conflictSource = RunningApps.fanControllerName()
                        self.message = "检测到其他程序正在控制风扇，已停止接管"
                        ControlJournal.write("检测到第三方接管，暂停下发（策略 \(self.strategy.rawValue) 不变）")
                    }

                    // 重启后把「固定」真正落回硬件。不做这一步，界面显示固定 3000 RPM，
                    // 风扇却还挂在系统自动上——设置看起来恢复了，其实没有生效。
                    // 曲线 / 规则不需要立即写硬件：它们在下一帧温度快照里自己评估、
                    // 自己接管，这里调用只是把「正在接管」的文案摆正。
                    if evidence.isEmpty, self.strategy != .automatic {
                        self.apply()
                    }
                }
            } catch {
                self.mirroredHelperReady = false
                DispatchQueue.main.async {
                    self.helperStatus = .unavailable
                    self.message = "未安装特权 helper，仅可监控"
                    ControlJournal.write("helper 不可用（策略 \(self.strategy.rawValue) 不变）")
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

        // 冲突期间只允许「返还」，不允许任何接管：两个程序同时写同一台风扇，
        // 用户看到的是转速来回跳，实际是两个写手在互相覆盖。
        if !conflict.isEmpty, strategy != .automatic {
            message = "检测到其他程序已接管风扇，本次不下发；确需接管请点提示条上的「仍要接管」"
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
                        self.recovery.reset()
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

    // MARK: - 冲突

    /// 用户明确表示「我知道，还是要接管」。
    ///
    /// 这是**唯一**绕过冲突拦截的入口，且必须由用户点按钮触发。
    /// 自动绕过等于没有检测——两个写手互相覆盖出来的转速抖动，
    /// 比「不接管」更难排查。
    func takeOverAnyway(forFan index: Int = 0) {
        // 先入队再调 apply：串行队列保证「解除拦截」排在「下发」之前。
        queue.async { [weak self] in
            self?.mirroredConflictBlocked = false
        }
        conflict = []
        conflictSource = nil
        if strategy == .automatic {
            message = "已解除拦截；选择固定 / 曲线 / 规则后才会真正接管"
        } else {
            apply(forFan: index)
        }
    }

    /// 重新检测一次（用户退出对方软件后点）。
    func redetectConflict() {
        conflict = []
        conflictSource = nil
        message = "正在重新检测…"
        bootstrap()
    }

    // MARK: - 规则自动化

    /// 每帧采样回调（在监控队列上调用）。内部转到控制队列，避免阻塞采样。
    func handleSnapshot(_ snapshot: SensorSnapshot, fanIndex: Int = 0) {
        queue.async { [weak self] in
            guard let self else { return }
            // 只有自动化策略才评估；自动/固定下不做任何多余计算
            guard self.mirroredStrategy.isAutomated else { return }
            guard !self.suspendedForLid else { return }
            // 第三方正在控制时，规则/曲线一律不下发（宁可不动，也不和对方互相覆盖）
            guard !self.mirroredConflictBlocked else { return }
            guard self.mirroredHelperReady, let controller = self.controller else { return }

            let now = Date()
            // 「芯片温度」按用户选的统计口径取：最高温（全部传感器）或均温（CPU+GPU）。
            // 曲线的插值与安全下限吃同一个值，规则引擎只把安全下限换成它。
            let die = snapshot.controlCelsius(self.mirroredAggregation)

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
                    now: now,
                    aggregation: self.mirroredAggregation
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
                    self.recovery.reset()
                    self.message = String(format: "%@接管：%.0f RPM", label, rpm)
                }

            case .release:
                try controller.restoreAuto(fanIndex: fanIndex)
                stopHeartbeat()
                // 主动返还时 helper 会清掉租约，紧接着的在途 tick 会拿到 false。
                // 靠 `stopHeartbeat()` 的代次自增把它作废，并且**不改策略**——
                // 「曲线暂时不需要接管」不等于「用户想要自动」。
                DispatchQueue.main.async {
                    self.isManual = false
                    self.recovery.reset()
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
        suspend(message: suspendedMessage)
    }

    /// 系统即将睡眠：与合盖走同一条路径。
    ///
    /// 必须**也**置 `suspendedForLid`——只做返还而不挂起的话，采样线程可能在
    /// 收到睡眠通知后的最后几帧里又接管回去，于是带着一个锁定的转速进入睡眠。
    /// 合盖塞进包里的场景下，这正是最危险的一种状态。
    func suspendForSleep() {
        suspend(message: "系统睡眠：已返还自动控制")
    }

    /// 挂起接管的唯一实现：返还 + 停心跳 + 清引擎状态 + 打标记。
    ///
    /// 「返还了但没挂起」和「挂起了但没返还」都是 bug，所以两者必须绑在一处。
    private func suspend(message: String) {
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
                self.message = message
            }
        }
    }

    /// 开盖：恢复接管。规则策略会在下一帧温度快照上重新评估，固定策略立即重新下发。
    func resumeAfterLid() {
        recovery.reset()
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
        heartbeatGeneration &+= 1
        let generation = heartbeatGeneration
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + heartbeatInterval, repeating: heartbeatInterval)
        timer.setEventHandler { [weak self] in
            guard let self, let transport = self.transport else { return }
            // 已经 stop 过（或换了新一轮）：在途的 tick 只许作废，不许改状态
            guard self.heartbeatGeneration == generation else { return }
            if !transport.heartbeat() {
                self.handleLeaseLost(generation: generation)
            }
        }
        timer.resume()
        heartbeat = timer
    }

    private func stopHeartbeat() {
        heartbeatGeneration &+= 1
        heartbeat?.cancel()
        heartbeat = nil
    }

    /// 租约没了：helper 重启、XPC 超时、机器忙着编译、刚被睡眠叫醒，
    /// 或者我们自己在别处刚 `restoreAuto` 过了（`restore()` 会清 helper 侧租约）。
    ///
    /// **铁律：这里绝不写用户策略。** 策略是用户意图，租约是运行时状态；把一次
    /// 瞬时故障落盘成「自动」，用户下次重启就再也回不来——这正是「策略每次重启
    /// 都变回自动」的来源（旧实现直接 `strategy = .automatic`，落盘且不可逆）。
    /// 因此失败只做两件事：交还系统控制（安全），然后按退避重连。
    private func handleLeaseLost(generation: Int) {
        guard heartbeatGeneration == generation else { return }
        stopHeartbeat()
        automation.noteExternallyReleased()
        curveAutomation.noteExternallyReleased()

        // 尽力先把风扇还给系统：helper 侧 `restore()` 会清掉租约，风扇回到自动。
        // 不还就直接重连的话，重连时读到「手动 + 我们没租约」，会被冲突检测
        // 当成第三方接管（其实是我们自己刚留下的），于是一直不敢重新下发。
        if let controller = self.controller {
            try? controller.restoreAuto(fanIndex: 0)
        }

        let intended = mirroredStrategy
        ControlJournal.write("租约失败：交还系统控制，策略保持 \(intended.rawValue)")

        DispatchQueue.main.async {
            self.isManual = false
            self.triggeredRuleIDs = []
            self.automatedRpm = nil
            self.curveRawRpm = nil
            guard intended != .automatic else {
                self.message = "租约过期，风扇已交还系统控制"
                return
            }
            self.message = "控制通道中断，已交还系统；正在重连（策略保持「\(intended.label)」）"
            self.scheduleRecovery()
        }
    }

    /// 仅供 `--probe-prefs lease` 取证：把「租约丢失」这条路真走一遍。
    ///
    /// 为什么要留这个口子：这条路径以前**会静默改写并落盘用户的策略**，
    /// 而触发它需要 helper 重启 / XPC 超时 / 睡眠唤醒，全是偶发条件。
    /// 没有这个入口就只能等它自己发生，等不到就永远不知道修没修好。
    /// 它只调用失败处理，不伪造任何成功路径，正常运行时没人调。
    func simulateLeaseLossForDiagnostics() {
        queue.async { [weak self] in
            guard let self else { return }
            self.handleLeaseLost(generation: self.heartbeatGeneration)
        }
    }

    /// 按退避重连：重新连 helper → 重新判冲突 → 重新下发。
    ///
    /// 全程不动持久化的策略。次数用尽才停下并提示用户手动「重新检测」——
    /// 自动重试必须有界，helper 被卸载时不能每 2 s 刷一次 XPC。
    private func scheduleRecovery() {
        guard strategy != .automatic else { return }
        guard let delay = recovery.nextDelay() else {
            message = "重连失败：helper 无响应。风扇由系统控制，策略仍是「\(strategy.label)」，可点「重新检测」再试"
            ControlJournal.write("重连放弃（已试 \(recovery.attemptsMade) 次）")
            return
        }
        ControlJournal.write("计划重连：\(Int(delay))s 后（第 \(recovery.attemptsMade) 次）")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.strategy != .automatic else { return }
            self.message = "正在重连…"
            self.bootstrap()
        }
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
