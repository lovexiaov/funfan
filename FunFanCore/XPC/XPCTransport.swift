import Foundation

/// GUI 侧的 XPC 传输实现（M4）。
///
/// 与 helper 的通信严格是「请求—应答」：GUI 永不持有 root，
/// 所有 SMC 写入都在 helper 进程内完成。
public final class XPCTransport: FanControlTransport {

    private let connection: NSXPCConnection
    private let timeout: TimeInterval

    public init(
        machServiceName: String = HelperConstants.machServiceName,
        timeout: TimeInterval = 3
    ) {
        self.timeout = timeout
        self.connection = NSXPCConnection(
            machServiceName: machServiceName,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(with: FunFanHelperXPCProtocol.self)
        connection.resume()
    }

    deinit {
        connection.invalidate()
    }

    /// 续租心跳。返回 false 表示 helper 已判定租约过期（GUI 应重新下发）。
    public func heartbeat() -> Bool {
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in }) as? FunFanHelperXPCProtocol else {
            return false
        }
        let semaphore = DispatchSemaphore(value: 0)
        var alive = false
        proxy.heartbeat { ok in
            alive = ok
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + timeout)
        return alive
    }

    public func send(_ request: FanControlRequest) throws -> FanControlReply {
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in }) as? FunFanHelperXPCProtocol else {
            throw FunFanError.helperUnavailable
        }

        let payload = HelperCodec.encode(request)
        let semaphore = DispatchSemaphore(value: 0)
        var result: Data?

        proxy.handle(payload) { replyData in
            result = replyData
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            throw FunFanError.helperUnavailable
        }
        guard let data = result, let reply = HelperCodec.decodeReply(data) else {
            throw FunFanError.helperUnavailable
        }
        return reply
    }
}
