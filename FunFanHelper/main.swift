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

/// 特权侧的风扇服务实现。
final class HelperService: NSObject, FunFanHelperXPCProtocol {

    private let smc: SMCService
    private let driver: FanHardwareDriver
    private let queue = DispatchQueue(label: "com.funfan.helper.serial")

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
        FileHandle.standardError.write("[FunFanHelper] 已返还系统自动（\(reason)）\n".data(using: .utf8)!)
    }
}

/// listener 代理：接受连接并对客户端做代码签名校验。
final class ListenerDelegate: NSObject, NSXPCListenerDelegate {

    private let service = HelperService()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // 开发期（adhoc/未签名）放宽；发布期必须启用签名要求，只允许本 App 连接。
        // 用法：FUNFAN_REQUIRE_SIGNATURE=1 启动时强制校验（由安装脚本设置）。
        if ProcessInfo.processInfo.environment["FUNFAN_REQUIRE_SIGNATURE"] == "1" {
            connection.setCodeSigningRequirement(
                "identifier \"com.funfan.app\" and anchor apple generic"
                + " and certificate leaf[subject.OU] = \"TEAMID\""
            )
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

// MARK: - 入口

let delegate = ListenerDelegate()

// 进程退出必须返还——否则风扇会被留在手动模式
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)

let signalQueue = DispatchQueue(label: "com.funfan.helper.signals")
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
