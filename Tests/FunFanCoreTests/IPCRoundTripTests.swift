import XCTest
@testable import FunFanCore

/// T10：XPC 契约序列化往返 + FanController 与 transport 的交互契约。
///
/// helper 尚未实现（M4），此层用 mock transport 固化「GUI 下发 / helper 执行」的协议边界。
final class IPCRoundTripTests: XCTestCase {

    // MARK: - 请求/应答编解码

    func testRequestRoundTrip() throws {
        let requests: [FanControlRequest] = [
            .listFans,
            .queryState(fanIndex: 0),
            .setTargetRpm(fanIndex: 0, rpm: 3200),
            .restoreAuto(fanIndex: 0),
            .setMode(fanIndex: 0, mode: .manualRules),
        ]

        for request in requests {
            let data = try JSONEncoder().encode(request)
            let decoded = try JSONDecoder().decode(FanControlRequest.self, from: data)
            XCTAssertEqual(decoded, request)
        }
    }

    func testReplyRoundTrip() throws {
        let state = FanState(
            index: 0, actualRpm: 1000, targetRpm: 3200,
            minRpm: 1000, maxRpm: 4900, mode: .manualRules, isManual: true
        )
        let replies: [FanControlReply] = [
            .states([state]),
            .acknowledged(state),
            .failed(FanControlErrorPayload(error: .invalidTargetRpm(0))),
        ]

        for reply in replies {
            let data = try JSONEncoder().encode(reply)
            let decoded = try JSONDecoder().decode(FanControlReply.self, from: data)
            XCTAssertEqual(decoded, reply)
        }
    }

    /// 错误必须可跨进程序列化（helper 把失败原因回传给 GUI 展示）。
    func testErrorPayloadPreservesCode() throws {
        let payload = FanControlErrorPayload(error: .thermalManagerRefused)

        XCTAssertEqual(payload.code, "thermalManagerRefused")
        XCTAssertFalse(payload.message.isEmpty)

        let decoded = try JSONDecoder().decode(
            FanControlErrorPayload.self, from: JSONEncoder().encode(payload)
        )
        XCTAssertEqual(decoded.error, .thermalManagerRefused)
    }

    func testAllErrorCasesMapToUniqueCodes() {
        let errors: [FunFanError] = [
            .smcAccessDenied, .keyNotFound("Tp01"), .dataTypeUnsupported("flt "),
            .decodeFailed(key: "Tp01", type: "flt "), .thermalManagerRefused,
            .helperUnavailable, .invalidTargetRpm(0),
        ]
        let codes = errors.map { FanControlErrorPayload(error: $0).code }

        XCTAssertEqual(Set(codes).count, errors.count)
    }

    // MARK: - FanController 与 transport 的交互

    func testSetTargetSendsExpectedRequest() throws {
        let transport = MockTransport(state: .init(
            index: 0, actualRpm: 1000, targetRpm: 1000,
            minRpm: 1000, maxRpm: 4900, mode: .automatic, isManual: false
        ))
        let controller = FanController(transport: transport)

        _ = try controller.setTarget(rpm: 3200, fanIndex: 0)

        XCTAssertEqual(transport.sent, [.setTargetRpm(fanIndex: 0, rpm: 3200)])
    }

    func testRestoreAutoSendsExpectedRequest() throws {
        let transport = MockTransport()
        let controller = FanController(transport: transport)

        try controller.restoreAuto(fanIndex: 0)

        XCTAssertEqual(transport.sent, [.restoreAuto(fanIndex: 0)])
    }

    func testFailureIsPropagatedAsError() {
        let transport = MockTransport(reply: .failed(FanControlErrorPayload(error: .thermalManagerRefused)))
        let controller = FanController(transport: transport)

        XCTAssertThrowsError(try controller.setTarget(rpm: 3000, fanIndex: 0)) { error in
            XCTAssertEqual(error as? FunFanError, .thermalManagerRefused)
        }
    }

    /// 下发前本地预检：0 RPM 直接拒绝，**不产生 IPC**（省一次往返，也防误操作）。
    func testInvalidTargetIsRejectedBeforeIPC() throws {
        let transport = MockTransport(state: .init(
            index: 0, actualRpm: 1000, targetRpm: 1000,
            minRpm: 1000, maxRpm: 4900, mode: .automatic, isManual: false
        ))
        let controller = FanController(transport: transport)

        _ = try controller.refreshState(fanIndex: 0)   // 已知上下限
        transport.clearSent()

        XCTAssertThrowsError(try controller.setTarget(rpm: 0, fanIndex: 0))
        XCTAssertThrowsError(try controller.setTarget(rpm: 9999, fanIndex: 0))
        XCTAssertTrue(transport.sent.isEmpty, "非法目标不应下发")
    }

    func testRefreshStateCachesLimits() throws {
        let transport = MockTransport(state: .init(
            index: 0, actualRpm: 1200, targetRpm: 1200,
            minRpm: 1100, maxRpm: 4500, mode: .automatic, isManual: false
        ))
        let controller = FanController(transport: transport)

        let state = try controller.refreshState(fanIndex: 0)

        XCTAssertEqual(state.minRpm, 1100, accuracy: 1e-9)
        XCTAssertEqual(controller.cachedLimits(for: 0)?.maxRpm, 4500)
        // 1100–4500 区间外应被拒
        XCTAssertThrowsError(try controller.setTarget(rpm: 1050, fanIndex: 0))
    }
}

// MARK: - Mock

private final class MockTransport: FanControlTransport {
    private(set) var sent: [FanControlRequest] = []
    private let reply: FanControlReply?

    init(state: FanState? = nil, reply: FanControlReply? = nil) {
        if let reply {
            self.reply = reply
        } else if let state {
            self.reply = .acknowledged(state)
        } else {
            self.reply = .acknowledged(FanState(
                index: 0, actualRpm: 1000, targetRpm: 1000,
                minRpm: 1000, maxRpm: 4900, mode: .automatic, isManual: false
            ))
        }
    }

    func send(_ request: FanControlRequest) throws -> FanControlReply {
        sent.append(request)
        guard let reply else { throw FunFanError.helperUnavailable }
        return reply
    }

    func clearSent() {
        sent.removeAll()
    }
}
