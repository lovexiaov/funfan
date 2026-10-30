import Foundation
import Combine
import FunFanCore

/// 按簇/核心聚合后的温度组，供 UI 展开显示。
struct CoreGroup: Identifiable, Equatable {
    let id: String
    let title: String
    /// 该组全部传感器的均温。
    let average: Double
    /// 仅「逐核确认」的传感器（不编造核号）。
    let confirmedCores: [(name: String, celsius: Double)]

    static func == (lhs: CoreGroup, rhs: CoreGroup) -> Bool {
        lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.average == rhs.average
            && lhs.confirmedCores.count == rhs.confirmedCores.count
            && lhs.confirmedCores.elementsEqual(rhs.confirmedCores, by: { $0.name == $1.name && $0.celsius == $1.celsius })
    }
}

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
    @Published private(set) var coreGroups: [CoreGroup] = []
    @Published private(set) var battery: BatteryState = .absent
    @Published private(set) var lastSample: Date?
    @Published private(set) var sensorCount: Int = 0
    /// 采样耗时（ms），用于自检「是否够轻量」。
    @Published private(set) var sampleCostMs: Double = 0

    /// 每次采样完成后回调（用于刷新菜单栏标题）。
    var onSample: ((Double?) -> Void)?
    /// 每帧原始快照回调（规则引擎评估用）。在监控队列上调用。
    var onSnapshot: ((SensorSnapshot) -> Void)?

    // MARK: - 内部

    private let queue = DispatchQueue(label: "com.funfan.monitor", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var smc: SMCService?
    private var monitor: SensorMonitor?
    private var batteryStore: BatteryStore?

    /// 当前可见性决定采样频率（0.5 / 2 / 5 s）。
    private var visibility: SamplingPolicy.Visibility = .menuBarOnly

    /// 主风扇索引。
    var primaryFan: FanState? { fans.first }

    // MARK: - 生命周期

    func start() {
        queue.async { [weak self] in self?.openIfNeeded() }
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

        let provider = SMCTemperatureProvider(service: service)
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

        let groups = Self.coreGroups(from: snapshot)
        let cpu = snapshot.averageCPU()
        let gpu = snapshot.averageGPU()
        let ssd = snapshot.average(for: .ssd)
        let ambient = snapshot.average(for: .ambient)
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
    /// 只有内置表确认过的键才算「逐核」，其余只做簇均温——不编造核号。
    private static func coreGroups(from snapshot: SensorSnapshot) -> [CoreGroup] {
        var groups: [CoreGroup] = []

        for subcluster in [CPUSubcluster.performance, .efficiency, .superCluster] {
            let all = snapshot.readings.filter { $0.descriptor.subcluster == subcluster }
            guard !all.isEmpty, let average = snapshot.average(subcluster: subcluster) else { continue }
            let cores = snapshot.coreLevelReadings(in: .cpu)
                .filter { $0.descriptor.subcluster == subcluster }
                .map { (name: $0.descriptor.name, celsius: $0.celsius) }
            groups.append(CoreGroup(
                id: "cpu-\(subcluster.rawValue)",
                title: "CPU · \(subcluster.rawValue)",
                average: average,
                confirmedCores: cores
            ))
        }

        let gpuReadings = snapshot.readings(in: .gpu)
        if !gpuReadings.isEmpty, let gpuAverage = snapshot.averageGPU() {
            let cores = gpuReadings
                .filter { $0.descriptor.isCoreLevel }
                .map { (name: $0.descriptor.name, celsius: $0.celsius) }
            groups.append(CoreGroup(id: "gpu", title: "GPU", average: gpuAverage, confirmedCores: cores))
        }

        return groups
    }
}
