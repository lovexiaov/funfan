import XCTest
@testable import FunFanCore

/// 真实风扇驱动的单测（用 mock SMC 设备，不碰硬件）。
///
/// 覆盖 Spec 的关键工程约束：
/// - 模式键 `F0Md` / `F0md` 必须**运行时探测**，不能写死；
/// - `Ftst` 存在则走解锁、不存在则直写（本机实测无 Ftst）；
/// - 目标转速必须 clamp 到 `F0Mn–F0Mx`，绝不写 0；
/// - 返还系统自动只写模式键，绝不写 `F0Tg`。
final class FanHardwareDriverTests: XCTestCase {

    // MARK: - 夹具

    /// 内存版 SMC 设备：记录所有写入，便于断言「到底写了什么、按什么顺序」。
    final class MockSMCDevice: SMCDevice {
        var values: [String: (type: String, value: Double)] = [:]
        private(set) var writes: [(key: String, value: Double)] = []
        var throwingKeys: Set<String> = []
        /// 写入后 `F0Ac` 是否收敛到目标（模拟风扇响应）。
        var convergeOnWrite = true

        func keyExists(_ key: String) -> Bool { values[key] != nil }

        func keyInfo(_ key: String) throws -> SMCKeyInfo {
            guard let entry = values[key] else { throw FunFanError.keyNotFound(key) }
            let size: Int
            switch entry.type {
            case "flt ": size = 4
            case "fpe2", "sp78", "ui16": size = 2
            case "ui32": size = 4
            default: size = 1
            }
            return SMCKeyInfo(key: key, dataSize: size, dataType: entry.type, dataAttributes: 0)
        }

        func readKey(_ key: String) throws -> Double {
            guard let entry = values[key] else { throw FunFanError.keyNotFound(key) }
            return entry.value
        }

        func writeKey(_ key: String, value: Double) throws {
            guard values[key] != nil else { throw FunFanError.keyNotFound(key) }
            if throwingKeys.contains(key) { throw FunFanError.thermalManagerRefused }
            writes.append((key, value))
            values[key]?.value = value

            // 写目标转速时模拟风扇实际转速跟随
            if convergeOnWrite, key.hasSuffix("Tg"), key.hasPrefix("F"),
               let index = Int(key.dropFirst().prefix(1)) {
                let actualKey = "F\(index)Ac"
                if values[actualKey] != nil { values[actualKey]?.value = value }
            }
        }

        var writtenKeys: [String] { writes.map(\.key) }
    }

    private func standardDevice(hasUppercaseModeKey: Bool = true, hasFtst: Bool = false) -> MockSMCDevice {
        let device = MockSMCDevice()
        device.values["FNum"] = ("ui8 ", 1)
        device.values["F0Ac"] = ("flt ", 1000)
        device.values["F0Tg"] = ("flt ", 1000)
        device.values["F0Mn"] = ("flt ", 1000)
        device.values["F0Mx"] = ("flt ", 4900)
        device.values[hasUppercaseModeKey ? "F0Md" : "F0md"] = ("ui8 ", 0)
        if hasFtst { device.values["Ftst"] = ("ui8 ", 0) }
        return device
    }

    private let limits = FanLimits(minRpm: 1000, maxRpm: 4900)

    // MARK: - 探测

    func testProbePicksUppercaseModeKey() {
        let driver = FanHardwareDriver(device: standardDevice(hasUppercaseModeKey: true))
        XCTAssertEqual(driver.probe(fanIndex: 0).modeKey, "F0Md")
    }

    func testProbePicksLowercaseModeKey() {
        let driver = FanHardwareDriver(device: standardDevice(hasUppercaseModeKey: false))
        XCTAssertEqual(driver.probe(fanIndex: 0).modeKey, "F0md", "本机实测是 F0md，必须能探测到")
    }

    func testProbeReportsNoModeKeyWhenNeitherExists() {
        let device = standardDevice()
        device.values["F0Md"] = nil
        let driver = FanHardwareDriver(device: device)
        XCTAssertNil(driver.probe(fanIndex: 0).modeKey)
    }

    func testProbeDetectsFtst() {
        let driver = FanHardwareDriver(device: standardDevice(hasFtst: true))
        XCTAssertTrue(driver.probe(fanIndex: 0).hasFtst)

        let plain = FanHardwareDriver(device: standardDevice(hasFtst: false))
        XCTAssertFalse(plain.probe(fanIndex: 0).hasFtst)
    }

    // MARK: - 解锁

    func testUnlockWritesFtstWhenPresent() throws {
        let device = standardDevice(hasFtst: true)
        let driver = FanHardwareDriver(device: device)

        let didUnlock = try driver.unlockIfNeeded()

        XCTAssertTrue(didUnlock)
        XCTAssertEqual(device.writtenKeys, ["Ftst"])
        XCTAssertEqual(device.writes.first?.value, 1)
    }

    func testUnlockIsSkippedWhenFtstAbsent() throws {
        let device = standardDevice(hasFtst: false)
        let driver = FanHardwareDriver(device: device)

        let didUnlock = try driver.unlockIfNeeded()

        XCTAssertFalse(didUnlock)
        XCTAssertTrue(device.writes.isEmpty, "无 Ftst 的机型不应产生任何写入")
    }

    // MARK: - 进入手动

    func testEnterManualWritesModeOneToDetectedKey() throws {
        let device = standardDevice(hasUppercaseModeKey: false)
        let driver = FanHardwareDriver(device: device)

        try driver.enterManual(fanIndex: 0)

        XCTAssertEqual(device.writes.map(\.key), ["F0md"])
        XCTAssertEqual(device.writes.first?.value, 1)
    }

    func testEnterManualThrowsWhenNoModeKey() {
        let device = standardDevice()
        device.values["F0Md"] = nil
        let driver = FanHardwareDriver(device: device)

        XCTAssertThrowsError(try driver.enterManual(fanIndex: 0)) { error in
            XCTAssertEqual(error as? FunFanError, .keyNotFound("F0Md|F0md"))
        }
    }

    // MARK: - 设置目标转速

    func testSetTargetWritesClampedValue() throws {
        let device = standardDevice()
        let driver = FanHardwareDriver(device: device)

        let state = try driver.setTarget(fanIndex: 0, rpm: 3000, limits: limits)

        XCTAssertTrue(device.writes.contains { $0.key == "F0Tg" && $0.value == 3000 })
        XCTAssertEqual(state.targetRpm, 3000)
    }

    func testSetTargetClampsAboveMax() throws {
        let device = standardDevice()
        let driver = FanHardwareDriver(device: device)

        _ = try driver.setTarget(fanIndex: 0, rpm: 99_999, limits: limits)

        let written = try XCTUnwrap(device.writes.last { $0.key == "F0Tg" })
        XCTAssertEqual(written.value, 4900, "超过 F0Mx 必须收敛到上界")
    }

    func testSetTargetRaisesBelowMin() throws {
        let device = standardDevice()
        let driver = FanHardwareDriver(device: device)

        _ = try driver.setTarget(fanIndex: 0, rpm: 10, limits: limits)

        let written = try XCTUnwrap(device.writes.last { $0.key == "F0Tg" })
        XCTAssertEqual(written.value, 1000, "低于 F0Mn 必须抬到下限，绝不允许更慢")
    }

    func testSetTargetRejectsZeroRpm() {
        let device = standardDevice()
        let driver = FanHardwareDriver(device: device)

        XCTAssertThrowsError(try driver.setTarget(fanIndex: 0, rpm: 0, limits: limits)) { error in
            XCTAssertEqual(error as? FunFanError, .invalidTargetRpm(0))
        }
        XCTAssertFalse(device.writes.contains { $0.key == "F0Tg" }, "非法目标不得产生写入")
    }

    /// 顺序约束：先解锁（若需要）→ 再进手动 → 最后写目标。
    func testSetTargetOrderIsUnlockThenManualThenTarget() throws {
        let device = standardDevice(hasFtst: true)
        let driver = FanHardwareDriver(device: device)

        _ = try driver.setTarget(fanIndex: 0, rpm: 2000, limits: limits)

        XCTAssertEqual(device.writtenKeys.prefix(3), ["Ftst", "F0Md", "F0Tg"])
    }

    /// thermalmonitord 会回收解锁，因此每次下发都必须重新断言 Ftst。
    func testSetTargetReassertsFtstOnEveryCall() throws {
        let device = standardDevice(hasFtst: true)
        let driver = FanHardwareDriver(device: device)

        _ = try driver.setTarget(fanIndex: 0, rpm: 2000, limits: limits)
        _ = try driver.setTarget(fanIndex: 0, rpm: 2500, limits: limits)

        XCTAssertEqual(device.writes.filter { $0.key == "Ftst" }.count, 2)
    }

    func testSetTargetPropagatesRefusal() {
        let device = standardDevice()
        device.throwingKeys = ["F0Tg"]
        let driver = FanHardwareDriver(device: device)

        XCTAssertThrowsError(try driver.setTarget(fanIndex: 0, rpm: 2000, limits: limits)) { error in
            XCTAssertEqual(error as? FunFanError, .thermalManagerRefused)
        }
    }

    // MARK: - 返还系统自动

    func testRestoreAutoWritesModeZeroAndNeverTouchesTarget() throws {
        let device = standardDevice(hasUppercaseModeKey: false)
        let driver = FanHardwareDriver(device: device)

        try driver.restoreAuto(fanIndex: 0)

        XCTAssertEqual(device.writes.map(\.key), ["F0md"])
        XCTAssertEqual(device.writes.first?.value, 0)
        XCTAssertFalse(device.writes.contains { $0.key == "F0Tg" }, "返还时不得写目标转速")
    }

    func testRestoreAutoIsIdempotent() throws {
        let device = standardDevice()
        let driver = FanHardwareDriver(device: device)

        try driver.restoreAuto(fanIndex: 0)
        try driver.restoreAuto(fanIndex: 0)

        XCTAssertEqual(device.writes.filter { $0.key == "F0Md" }.count, 2)
    }

    // MARK: - 状态读取

    func testStateReadsAllFourKeysAndMode() throws {
        let device = standardDevice(hasFtst: false)
        device.values["F0Ac"]?.value = 2100
        device.values["F0Tg"]?.value = 2200
        device.values["F0Md"]?.value = 1
        let driver = FanHardwareDriver(device: device)

        let state = try driver.state(fanIndex: 0)

        XCTAssertEqual(state.actualRpm, 2100)
        XCTAssertEqual(state.targetRpm, 2200)
        XCTAssertEqual(state.minRpm, 1000)
        XCTAssertEqual(state.maxRpm, 4900)
        XCTAssertTrue(state.isManual)
        XCTAssertEqual(state.mode, .manualFixed)
    }

    func testStateReportsAutomaticWhenModeIsZero() throws {
        let device = standardDevice()
        let driver = FanHardwareDriver(device: device)

        XCTAssertEqual(try driver.state(fanIndex: 0).mode, .automatic)
    }
}
