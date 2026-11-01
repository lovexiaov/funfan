import Foundation
import FunFanCore

// FunFanHelper —— 特权守护进程（M4，root 运行）
//
// 唯一职责：代表 GUI 写 SMC。GUI 永不持有 root。
//
// 安全不变量（Spec §7 Boundaries）：
//   1. 只写 F0Tg / 模式键 / Ftst，绝不写 F0Mn / F0Mx；
//   2. 目标转速二次校验（GUI 被绕过也写不坏）：非法值直接拒绝，不产生写入；
//   3. TTL 租约：GUI 不续租（崩溃/被杀）→ 自动返还系统自动，绝不把风扇锁死；
//   4. 进程退出（SIGTERM/SIGINT）→ 返还所有动过的风扇。

// MARK: - 日志

/// 统一日志出口。LaunchDaemon 下 stderr 被重定向到 StandardErrorPath
/// （/var/log/cn.lovexiaov.fun.fan.helper.log），前台运行时直接打到终端。
func log(_ message: String) {
    FileHandle.standardError.write("[FunFanHelper] \(message)\n".data(using: .utf8)!)
}

/// 特权侧的风扇服务实现。
final class HelperService: NSObject, FunFanHelperXPCProtocol {

    private let smc: SMCService
    private let driver: FanHardwareDriver
    private let queue = DispatchQueue(label: "cn.lovexiaov.fun.fan.helper.serial")

    /// 租约：仅在有效期内维持手动。
    private var lease: ControlLease?
    private var watchdog: DispatchSourceTimer?
    /// 本次会话动过的风扇（用于过期/退出时精确返还）。
    private var touchedFans: Set<Int> = []

    /// 租约时长：GUI 每 2 s 心跳一次，10 s 足够容错而不至于长期失控。
    private let leaseTTL: TimeInterval = 10

    override init() {
        let service = SMCService()
        try? service.open()
        self.smc = service
        self.driver = FanHardwareDriver(device: service)
        super.init()
    }

    // MARK: - XPC

    func handle(_ requestData: Data, reply: @escaping (Data) -> Void) {
        queue.async {
            let response = self.process(requestData)
            reply(response)
        }
    }

    func heartbeat(reply: @escaping (Bool) -> Void) {
        queue.async {
            guard var lease = self.lease else {
                reply(false)
                return
            }
            if lease.isExpired() {
                self.restoreAll(reason: "租约已过期")
                reply(false)
                return
            }
            lease.renew()
            self.lease = lease
            reply(true)
        }
    }

    // MARK: - 请求处理

    private func process(_ data: Data) -> Data {
        guard let request = HelperCodec.decodeRequest(data) else {
            return HelperCodec.failure(.helperUnavailable)
        }

        do {
            switch request {
            case .listFans:
                return HelperCodec.encode(.states(try allStates()))

            case .queryState(let fanIndex):
                return HelperCodec.encode(.acknowledged(try driver.state(fanIndex: fanIndex)))

            case .setTargetRpm(let fanIndex, let rpm):
                return try applyTarget(fanIndex: fanIndex, rpm: rpm)

            case .setMode(let fanIndex, let mode):
                if mode == .automatic {
                    try restore(fanIndex: fanIndex)
                    return HelperCodec.encode(.acknowledged(try driver.state(fanIndex: fanIndex)))
                }
                return HelperCodec.encode(.acknowledged(try driver.state(fanIndex: fanIndex)))

            case .restoreAuto(let fanIndex):
                try restore(fanIndex: fanIndex)
                return HelperCodec.encode(.acknowledged(try driver.state(fanIndex: fanIndex)))
            }
        } catch let error as FunFanError {
            return HelperCodec.failure(error)
        } catch {
            return HelperCodec.failure(.helperUnavailable)
        }
    }

    private func allStates() throws -> [FanState] {
        let count = driver.fanCount()
        return (0..<count).map { try? driver.state(fanIndex: $0) }.compactMap { $0 }
    }

    /// 下发目标转速：二次校验 → 写入 → 续租 → 起看门狗。
    private func applyTarget(fanIndex: Int, rpm: Double) throws -> Data {
        let current = try driver.state(fanIndex: fanIndex)
        let limits = current.limits

        // 二次校验：GUI 侧即便被绕过，非法目标也到不了硬件
        guard SafetyPolicy.isValidTarget(rpm, limits: limits) else {
            throw FunFanError.invalidTargetRpm(Int(rpm.rounded()))
        }

        let state = try driver.setTarget(fanIndex: fanIndex, rpm: rpm, limits: limits)

        touchedFans.insert(fanIndex)
        lease = ControlLease(ttl: leaseTTL)
        startWatchdog()
        return HelperCodec.encode(.acknowledged(state))
    }

    private func restore(fanIndex: Int) throws {
        try driver.restoreAuto(fanIndex: fanIndex)
        touchedFans.remove(fanIndex)
        if touchedFans.isEmpty {
            lease = nil
            watchdog?.cancel()
            watchdog = nil
        }
    }

    // MARK: - 看门狗

    private func startWatchdog() {
        guard watchdog == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, let lease = self.lease else { return }
            if lease.isExpired() {
                self.restoreAll(reason: "租约过期")
            }
        }
        timer.resume()
        watchdog = timer
    }

    /// 返还所有动过的风扇（过期 / 退出 / 致命错误时调用）。
    func restoreAll(reason: String) {
        guard !touchedFans.isEmpty else { return }
        for fan in touchedFans {
            try? driver.restoreAuto(fanIndex: fan)
        }
        touchedFans.removeAll()
        lease = nil
        watchdog?.cancel()
        watchdog = nil
        log("已返还系统自动（\(reason)）")
    }
}

/// listener 代理：接受连接并对客户端做代码签名校验。
final class ListenerDelegate: NSObject, NSXPCListenerDelegate {

    // 宿主监视（T20）需要拿到 service 来在自毁前返还风扇
    let service = HelperService()

    /// 客户端签名要求：从**自己的签名**里取 Team ID 反推，而不是构建期注入常量。
    ///
    /// 签名本身才是唯一事实来源；在脚本里再写一份 Team ID，换证书时必然漂移。
    /// 取不到（adhoc 开发签名）时返回 nil，即开发期不校验。
    /// `FUNFAN_REQUIRE_SIGNATURE=0` 可强制关闭（仅供排障）。
    private static let clientRequirement: String? = {
        let flag = ProcessInfo.processInfo.environment["FUNFAN_REQUIRE_SIGNATURE"]
        if flag == "0" { return nil }
        guard let team = CodeSigningInfo.ownTeamIdentifier() else {
            log("签名里没有 Team ID（adhoc），本次不校验客户端签名（仅开发期可接受）")
            return nil
        }
        let requirement = HelperSignature.clientRequirement(teamID: team)
        log("客户端签名要求：\(requirement ?? "（构造失败）")")
        return requirement
    }()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        if let requirement = Self.clientRequirement {
            // 不满足要求的连接会被系统在握手阶段直接掐断，
            // 连 listener 回调都不会进到业务代码里。
            connection.setCodeSigningRequirement(requirement)
        }

        connection.exportedInterface = NSXPCInterface(with: FunFanHelperXPCProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }

    func shutdown() {
        service.restoreAll(reason: "helper 退出")
    }
}

// MARK: - 宿主监视（T20：宿主消失自退场）

/// daemon 对「宿主 App 是否还在」的监视配置。
///
/// 安装形态判定（按事实来源排优先级）：
/// 1. daemon 自己长在 `.app/Contents/MacOS/` 里 → App 包内安装，
///    宿主 = 反推出的包路径（自己的位置就是事实）；
/// 2. 裸二进制 + 安装时记录了 `FUNFAN_APP_PATH` → 脚本直装，
///    宿主 = 安装脚本记录的路径；
/// 3. 其余（裸二进制且无记录，如 `make run` 直接喂的 CLI 场景）→
///    不知道宿主在哪，不监视——猜一个路径出来比不监视更危险。
enum HostWatchConfig {
    case disabled
    case enabled(variant: HelperSelfCleanup.InstallVariant, hostPath: String)

    static func resolve(executablePath: String, environment: [String: String]) -> HostWatchConfig {
        if let hostPath = HelperSelfCleanup.hostAppBundlePath(executablePath: executablePath) {
            return .enabled(
                variant: .appEmbedded(
                    plistPath: HelperConstants.installedPlistPath,
                    // 两条注册路径的日志落点不同，都试删（不存在的静默跳过）
                    logPaths: [HelperConstants.logPath, HelperConstants.Legacy.logPath]
                ),
                hostPath: hostPath
            )
        }
        if let recorded = environment["FUNFAN_APP_PATH"], !recorded.isEmpty {
            return .enabled(
                variant: .script(
                    binaryPath: HelperConstants.installedBinaryPath,
                    plistPath: HelperConstants.installedPlistPath,
                    logPath: HelperConstants.logPath
                ),
                hostPath: recorded
            )
        }
        return .disabled
    }
}

/// 宿主消失自退场执行器。
///
/// 节奏：每 60 s 查一次，**连续 3 次**（约 3 分钟）不在才动手——
/// 外置卷瞬时卸载、更新期换包都只会缺席一次，不值得拿 root 进程赌。
/// 自毁顺序：先返还风扇（安全不变量优先于清理）→ 删文件 → bootout → exit(0)。
final class HostWatchdog {
    static let interval: TimeInterval = 60
    static let threshold = 3

    private let hostPath: String
    private let plan: HelperSelfCleanup.Plan
    private let service: HelperService
    private let fileExists: (String) -> Bool
    private var state = HostWatchState()
    private var timer: DispatchSourceTimer?

    init(
        hostPath: String,
        plan: HelperSelfCleanup.Plan,
        service: HelperService,
        fileExists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) {
        self.hostPath = hostPath
        self.plan = plan
        self.service = service
        self.fileExists = fileExists
    }

    func start(queue: DispatchQueue) {
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + Self.interval, repeating: Self.interval)
        source.setEventHandler { [weak self] in self?.check() }
        source.resume()
        timer = source
    }

    private func check() {
        guard state.record(hostPresent: fileExists(hostPath), threshold: Self.threshold) else { return }
        selfDestruct()
    }

    private func selfDestruct() {
        timer?.cancel()
        service.restoreAll(reason: "宿主已消失，自退场")
        for step in plan.steps {
            switch step {
            case .deleteFile(let path):
                try? FileManager.default.removeItem(atPath: path)
            case .bootout(let label):
                runBootout(label: label)
            }
        }
        exit(0)
    }

    /// bootout 会给自己发 SIGTERM（signal handler 里返还风扇后 exit(0)），
    /// 所以 waitUntilExit 可能永远等不到返回——两条路径的终点都是进程结束。
    private func runBootout(label: String) {
        let args = HelperSelfCleanup.bootoutArguments(label: label)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: args[0])
        process.arguments = Array(args.dropFirst())
        try? process.run()
        process.waitUntilExit()
    }
}

// MARK: - 入口

let delegate = ListenerDelegate()

// 宿主监视：只在知道宿主路径时启用（判据见 HostWatchConfig.resolve）
if case .enabled(let watchVariant, let watchHostPath) = HostWatchConfig.resolve(
    executablePath: URL(fileURLWithPath: CommandLine.arguments[0])
        .resolvingSymlinksInPath()
        .path,
    environment: ProcessInfo.processInfo.environment
) {
    let hostWatchdog = HostWatchdog(
        hostPath: watchHostPath,
        plan: HelperSelfCleanup.plan(
            variant: watchVariant,
            label: HelperConstants.machServiceName
        ),
        service: delegate.service
    )
    hostWatchdog.start(
        queue: DispatchQueue(label: "\(HelperConstants.identifierRoot).helper.host-watch")
    )
}

// 进程退出必须返还——否则风扇会被留在手动模式
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)

let signalQueue = DispatchQueue(label: "cn.lovexiaov.fun.fan.helper.signals")
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT] {
    let source = DispatchSource.makeSignalSource(signal: sig, queue: signalQueue)
    source.setEventHandler {
        delegate.shutdown()
        exit(0)
    }
    source.resume()
    signalSources.append(source)
}

let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
