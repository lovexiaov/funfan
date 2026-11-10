import Foundation
import Combine
import FunFanCore

/// 监控数据源：温度 + 风扇 + 电量，全部免 root。
///
/// 线程模型：采样在专用串行队列（单帧约 19 ms，不能占主线程），
/// 结果统一切回主线程更新 `@Published`。
final class MonitorStore: ObservableObject {

    // MARK: - 对外状态

    @Published private(set) var fans: [FanState] = []
    @Published private(set) var cpuAverage: Double?
    @Published private(set) var gpuAverage: Double?
    @Published private(set) var ssdAverage: Double?
    @Published private(set) var ambientAverage: Double?
    /// 环境温度在这台机器上到底有没有——`ambientAverage == nil` 不足以区分
    /// 「没有这个传感器」和「这一刻没采到」，UI 需要这个三态才能不说谎。
    @Published private(set) var ambientAvailability: SensorAvailability = .pending
    /// 全部传感器中的最高温——「最高温度」口径下的芯片温度（与 `RuleEngine` 一致）。
    @Published private(set) var hottestCelsius: Double?
    /// CPU + GPU 的均温——「平均温度」口径下的芯片温度（SSD/电池/环境不参与）。
    @Published private(set) var coreAverageCelsius: Double?
    @Published private(set) var coreGroups: [CoreGroup] = []
    @Published private(set) var battery: BatteryState = .absent
    @Published private(set) var lastSample: Date?
    @Published private(set) var sensorCount: Int = 0
    /// 采样耗时（ms），用于自检「是否够轻量」。
    @Published private(set) var sampleCostMs: Double = 0
    /// 芯片真实拓扑（核心数来自系统接口，非 SMC 倒推）。启动读一次即可，硬件不变。
    @Published private(set) var chipTopology: ChipTopology?

    /// 每次采样完成后回调（用于刷新菜单栏标题）。
    var onSample: ((Double?) -> Void)?
    /// 每帧原始快照回调（规则引擎评估用）。在监控队列上调用。
    var onSnapshot: ((SensorSnapshot) -> Void)?

    // MARK: - 内部

    private let queue = DispatchQueue(label: "cn.lovexiaov.fun.fan.monitor", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var smc: SMCService?
    private var monitor: SensorMonitor?
    /// 保留一份 provider 引用：只有它知道「这台机器的键表里有没有某类传感器」，
    /// 而单帧读数答不了这个问题（读失败、越界过滤都会让当帧缺席）。
    private var temperatureProvider: SMCTemperatureProvider?
    private var batteryStore: BatteryStore?

    /// 当前可见性决定采样频率（0.5 / 2 / 5 s）。
    private var visibility: SamplingPolicy.Visibility = .menuBarOnly

    /// 主风扇索引。
    var primaryFan: FanState? { fans.first }

    /// 当前调速口径对应的芯片温度（UI 复现「风扇到底按几度在算」）。
    ///
    /// 必须与 `ControlStore` 喂给引擎的值同源：两边各算一套，就会出现
    /// 「设置页说 52℃、曲线却按 78℃ 画」这种自相矛盾的画面。
    func controlTemperature(_ aggregation: TemperatureAggregation) -> Double? {
        switch aggregation {
        case .peak: return hottestCelsius
        case .average: return coreAverageCelsius
        }
    }

    /// 拓扑来源（可注入假实现用于测试）。默认从 sysctl / IORegistry 读真实硬件。
    var topologyProvider: TopologyProviding = SystemTopologyProbe()

    // MARK: - 生命周期

    func start() {
        readTopology()
        queue.async { [weak self] in self?.openIfNeeded() }
    }

    /// 读一次芯片拓扑（便宜，且硬件不变）。失败则留 nil，UI 降级不显示该卡。
    private func readTopology() {
        let topo = topologyProvider.read()
        DispatchQueue.main.async { [weak self] in self?.chipTopology = topo }
    }

    /// 睡眠唤醒后重建连接：睡眠会让 SMC 连接失效，键信息缓存也可能过期。
    func restart() {
        queue.async { [weak self] in
            guard let self else { return }
            self.timer?.cancel()
            self.timer = nil
            self.smc?.invalidateKeyInfoCache()
            self.smc?.close()
            self.smc = nil
            self.monitor = nil
            self.temperatureProvider = nil
            self.openIfNeeded()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
            self?.smc?.close()
            self?.smc = nil
        }
    }

    private func openIfNeeded() {
        let service = SMCService()
        do {
            try service.open()
        } catch {
            DispatchQueue.main.async { self.lastSample = nil }
            return
        }
        smc = service

        // 两层采样（M14）：每 10 帧一次全量扫描，快帧只读每类最热 4 个键，
        // 其余键复用缓存——输出形状与全量一致，消费方零改动。
        // 全量帧间隔：面板打开 2 s × 10 = 20 s；自动化 1 s × 10 = 10 s。
        let provider = SMCTemperatureProvider(service: service, fullScanEvery: 10, perCategoryHotKeys: 4)
        temperatureProvider = provider
        monitor = SensorMonitor(windowCapacity: 60, provider: { provider.readings() })
        batteryStore = BatteryStore()

        scheduleTimer()
        sampleOnce()
    }

    /// 更新可见性（Popover 开/关时调用），立即按新频率重排定时器。
    func setVisibility(_ newValue: SamplingPolicy.Visibility) {
        queue.async { [weak self] in
            guard let self, self.visibility != newValue else { return }
            self.visibility = newValue
            self.scheduleTimer()
            self.sampleOnce()
        }
    }

    // MARK: - 采样

    private func scheduleTimer() {
        timer?.cancel()
        let interval = SamplingPolicy.interval(for: visibility)
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(200))
        source.setEventHandler { [weak self] in self?.sampleOnce() }
        source.resume()
        timer = source
    }

    private func sampleOnce() {
        guard let smc, let monitor else { return }

        let started = Date()
        let snapshot = monitor.tick()
        let cost = Date().timeIntervalSince(started) * 1000

        // 风扇状态（只读，免 root）
        var fanStates: [FanState] = []
        let driver = FanHardwareDriver(device: smc)
        for index in 0..<driver.fanCount() {
            if let state = try? driver.state(fanIndex: index) { fanStates.append(state) }
        }

        let battery = batteryStore?.refresh() ?? .absent

        let groups = snapshot.coreGroups()
        let cpu = snapshot.averageCPU()
        let gpu = snapshot.averageGPU()
        let ssd = snapshot.average(for: .ssd)
        let ambient = snapshot.average(for: .ambient)
        let ambientAvailability = snapshot.availability(
            for: .ambient,
            sensorCount: temperatureProvider?.sensorCount(for: .ambient)
        )
        let hottest = snapshot.readings.map(\.celsius).max()
        let coreAverage = snapshot.controlCelsius(.average)
        let count = snapshot.readings.count

        // 规则评估用原始快照：在监控队列上同步回调，避免额外线程切换。
        // 控制层内部会再转到自己的串行队列，不阻塞采样。
        onSnapshot?(snapshot)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.fans = fanStates
            self.cpuAverage = cpu
            self.gpuAverage = gpu
            self.ssdAverage = ssd
            self.ambientAverage = ambient
            self.ambientAvailability = ambientAvailability
            self.hottestCelsius = hottest
            self.coreAverageCelsius = coreAverage
            self.coreGroups = groups
            self.battery = battery
            self.lastSample = snapshot.timestamp
            self.sensorCount = count
            self.sampleCostMs = cost
            self.onSample?(cpu)
        }
    }

    /// 把快照按「CPU 的 P/E/Super 簇 + GPU 簇」聚合成可展开的分组。
    ///
    /// 逻辑已下沉到 `SensorSnapshot.coreGroups()`（FunFanCore，可单测）：
    /// 每个簇列出其全部 SMC 温度探测点（真实键名），核心数由 `ChipTopology` 单独提供。
}
