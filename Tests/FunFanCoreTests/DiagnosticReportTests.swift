import XCTest
@testable import FunFanCore

/// 诊断报告：环境采集 + 能力判定 + 渲染。
///
/// 这块的价值在于「用户报 bug 时能不能一次性拿到足够信息」，
/// 所以测试重点不是排版，而是**判定是否正确、失败项是否被明确标出并给出排查方向**。
final class DiagnosticReportTests: XCTestCase {

    // MARK: - 夹具

    /// 假 SMC：内存字典，可指定键集合、属性位、以及「枚举直接失败」。
    final class FakeSMC: SMCDevice, SMCCapabilitySource {
        struct Entry {
            let type: String
            let value: Double
            let attr: UInt8
        }

        var values: [String: Entry] = [:]
        var declaredKeys: [String] = []
        var failEnumeration = false
        var unreadableKeys: Set<String> = []

        func keyExists(_ key: String) -> Bool { values[key] != nil }

        func keyInfo(_ key: String) throws -> SMCKeyInfo {
            guard let entry = values[key] else { throw FunFanError.keyNotFound(key) }
            let size: Int
            switch entry.type {
            case "flt ", "ui32": size = 4
            case "fpe2", "sp78", "ui16": size = 2
            default: size = 1
            }
            return SMCKeyInfo(key: key, dataSize: size, dataType: entry.type, dataAttributes: entry.attr)
        }

        func readKey(_ key: String) throws -> Double {
            guard !unreadableKeys.contains(key) else { throw FunFanError.decodeFailed(key: key, type: "flt ") }
            guard let entry = values[key] else { throw FunFanError.keyNotFound(key) }
            return entry.value
        }

        func writeKey(_ key: String, value: Double) throws {}

        func allKeys() throws -> [String] {
            if failEnumeration { throw FunFanError.smcAccessDenied }
            return declaredKeys
        }
    }

    struct FakeProbe: DiagnosticsProbing {
        var model = "Mac16,10"
        var battery = false
        var root = false
        var display = DisplayProbe(builtinOnline: false, externalOnline: true, totalOnline: 1)
        var helper = HelperDiagnosis(binaryInstalled: true, plistInstalled: true, logTail: ["[FunFanHelper] 已返还系统自动（租约过期）"])

        func macOSVersion() -> String { "27.0.1" }
        func osBuild() -> String { "26A434" }
        func architecture() -> String { "arm64" }
        func hardwareModel() -> String { model }
        func chipName() -> String { "Apple M4" }
        func isRoot() -> Bool { root }
        func hasBattery() -> Bool { battery }
        func displays() -> DisplayProbe { display }
        func helperDiagnosis() -> HelperDiagnosis { helper }
    }

    /// 一台「正常 Mac mini」：单风扇、有模式键、无 Ftst、温度键可读。
    private func workingSMC() -> FakeSMC {
        let smc = FakeSMC()
        smc.values = [
            "FNum": .init(type: "ui8 ", value: 1, attr: 0x84),
            "F0Ac": .init(type: "flt ", value: 1000, attr: 0x84),
            "F0Tg": .init(type: "flt ", value: 1000, attr: 0xD4),
            "F0Mn": .init(type: "flt ", value: 1000, attr: 0x84),
            "F0Mx": .init(type: "flt ", value: 4900, attr: 0x85),
            "F0Md": .init(type: "ui8 ", value: 0, attr: 0xD0),
            "Tp09": .init(type: "flt ", value: 64, attr: 0x84),
            "Tg0f": .init(type: "flt ", value: 54, attr: 0x84),
        ]
        smc.declaredKeys = Array(smc.values.keys)
        return smc
    }

    // MARK: - 环境快照

    func testSnapshotCapturesEnvironment() {
        let report = SystemInfoCollector.collect(
            reason: "手动诊断",
            probe: FakeProbe(),
            device: workingSMC(),
            now: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(report.system.macOSVersion, "27.0.1")
        XCTAssertEqual(report.system.osBuild, "26A434")
        XCTAssertEqual(report.system.hardwareModel, "Mac16,10")
        XCTAssertEqual(report.system.chipName, "Apple M4")
        XCTAssertEqual(report.system.fanCount, 1)
        XCTAssertEqual(report.system.fanRange, "1000–4900 RPM")
        XCTAssertEqual(report.system.smcKeyCount, 8)
        XCTAssertEqual(report.system.temperatureKeyCount, 2)
        XCTAssertFalse(report.system.isPortable)
        XCTAssertFalse(report.hasFailures)
    }

    // MARK: - 能力判定

    func testDesktopMarksLidUnsupportedButKeepsBatteryUnsupported() {
        let report = SystemInfoCollector.collect(
            reason: "台式机", probe: FakeProbe(model: "Mac16,10", battery: false), device: workingSMC()
        )

        XCTAssertEqual(status(report, "lid"), .unsupported)
        XCTAssertEqual(status(report, "battery"), .unsupported)
        XCTAssertEqual(status(report, "helper"), .ok)
    }

    func testLaptopInClamshellIsReportedClosed() {
        let probe = FakeProbe(
            model: "MacBookPro18,3",
            battery: true,
            display: DisplayProbe(builtinOnline: false, externalOnline: true, totalOnline: 1)
        )
        let report = SystemInfoCollector.collect(reason: "合盖", probe: probe, device: workingSMC())

        XCTAssertEqual(status(report, "lid"), .ok)
        let lid = report.capabilities.first { $0.id == "lid" }
        XCTAssertTrue(lid?.detail.contains("合盖") == true)
        XCTAssertEqual(status(report, "battery"), .ok)
    }

    func testLaptopWithHeadlessDisplaysIsDegraded() {
        let probe = FakeProbe(
            model: "MacBookPro18,3",
            battery: true,
            display: DisplayProbe(builtinOnline: false, externalOnline: false, totalOnline: 0)
        )
        let report = SystemInfoCollector.collect(reason: "无头", probe: probe, device: workingSMC())
        XCTAssertEqual(status(report, "lid"), .degraded)
    }

    func testNonRootMarksWriteDegraded() {
        let report = SystemInfoCollector.collect(
            reason: "非 root", probe: FakeProbe(root: false), device: workingSMC()
        )
        XCTAssertEqual(status(report, "fan.write"), .degraded)
        XCTAssertFalse(report.hasFailures)

        let asRoot = SystemInfoCollector.collect(
            reason: "root", probe: FakeProbe(root: true), device: workingSMC()
        )
        XCTAssertEqual(status(asRoot, "fan.write"), .ok)
    }

    func testMissingModeKeyIsFailureWithHint() {
        let smc = workingSMC()
        smc.values["F0Md"] = nil
        let report = SystemInfoCollector.collect(reason: "缺模式键", probe: FakeProbe(), device: smc)

        XCTAssertEqual(status(report, "fan.mode.0"), .failed)
        XCTAssertNotNil(report.capabilities.first { $0.id == "fan.mode.0" }?.hint)
        XCTAssertTrue(report.hasFailures)
    }

    func testFtstAbsenceIsNotAFailure() {
        let report = SystemInfoCollector.collect(reason: "无 Ftst", probe: FakeProbe(), device: workingSMC())
        let unlock = report.capabilities.first { $0.id == "fan.unlock" }
        XCTAssertEqual(unlock?.status, .ok)
        XCTAssertTrue(unlock?.detail.contains("无 Ftst") == true)
    }

    func testSMCOpenFailureShortCircuitsRemainingChecks() {
        let report = SystemInfoCollector.collect(
            reason: "沙箱内", probe: FakeProbe(),
            smcFactory: { throw FunFanError.smcAccessDenied }
        )

        XCTAssertEqual(status(report, "smc.open"), .failed)
        XCTAssertEqual(status(report, "smc.keys"), .failed)
        XCTAssertEqual(status(report, "fan.describe"), .failed)
        XCTAssertTrue(report.hasFailures)
        // 与 SMC 无关的能力仍然要给出结论，不能被一起判失败
        XCTAssertEqual(status(report, "helper"), .ok)
        XCTAssertEqual(status(report, "lid"), .unsupported)
    }

    func testEnumerationFailureIsFailed() {
        let smc = workingSMC()
        smc.failEnumeration = true
        let report = SystemInfoCollector.collect(reason: "枚举失败", probe: FakeProbe(), device: smc)

        XCTAssertEqual(status(report, "smc.keys"), .failed)
        XCTAssertEqual(status(report, "smc.temperature"), .failed)
    }

    func testPartiallyUnreadableTemperaturesIsDegraded() {
        let smc = workingSMC()
        smc.unreadableKeys = ["Tg0f"]
        let report = SystemInfoCollector.collect(reason: "部分不可读", probe: FakeProbe(), device: smc)

        XCTAssertEqual(status(report, "smc.temperature"), .degraded)
        XCTAssertFalse(report.hasFailures)
    }

    func testHelperMissingIsDegradedNotFailed() {
        let probe = FakeProbe(helper: HelperDiagnosis())
        let report = SystemInfoCollector.collect(reason: "未装 helper", probe: probe, device: workingSMC())
        XCTAssertEqual(status(report, "helper"), .degraded)
    }

    func testHalfInstalledHelperIsFailure() {
        let probe = FakeProbe(helper: HelperDiagnosis(binaryInstalled: true, plistInstalled: false))
        let report = SystemInfoCollector.collect(reason: "半装", probe: probe, device: workingSMC())
        XCTAssertEqual(status(report, "helper"), .failed)
        XCTAssertTrue(report.capabilities.first { $0.id == "helper" }?.hint?.contains("install-helper.sh") == true)
    }

    // MARK: - 渲染

    func testMarkdownHasSectionsAndPutsFailuresFirst() {
        let smc = workingSMC()
        smc.values["F0Md"] = nil
        let report = SystemInfoCollector.collect(
            reason: "模式键缺失",
            probe: FakeProbe(),
            device: smc,
            context: ["lastError": "keyNotFound(F0Md)"],
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let text = report.markdown
        XCTAssertTrue(text.contains("# FunFan 诊断报告"))
        XCTAssertTrue(text.contains("触发原因：模式键缺失"))
        XCTAssertTrue(text.contains("## 系统"))
        XCTAssertTrue(text.contains("## 能力"))
        XCTAssertTrue(text.contains("Mac16,10"))
        XCTAssertTrue(text.contains("1 项失败"))
        // 失败项应排在不适用项之前
        let failedIndex = text.range(of: "风扇 0 模式键")?.lowerBound
        let unsupportedIndex = text.range(of: "合盖检测")?.lowerBound
        if let failedIndex, let unsupportedIndex {
            XCTAssertLessThan(failedIndex, unsupportedIndex)
        } else {
            XCTFail("报告缺少关键行")
        }
        // 附加上下文与 helper 日志都要带上
        XCTAssertTrue(text.contains("keyNotFound(F0Md)"))
        XCTAssertTrue(text.contains("已返还系统自动"))
    }

    func testJSONRoundTrip() throws {
        let report = SystemInfoCollector.collect(reason: "序列化", probe: FakeProbe(), device: workingSMC())
        let json = report.json
        XCTAssertTrue(json.contains("\"schemaVersion\" : 1"))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(DiagnosticReport.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.schemaVersion, DiagnosticReport.schemaVersion)
        XCTAssertEqual(decoded.capabilities.count, report.capabilities.count)
        XCTAssertEqual(decoded.system.hardwareModel, "Mac16,10")
    }

    func testSaveWritesMarkdownFile() throws {
        let report = SystemInfoCollector.collect(
            reason: "落盘", probe: FakeProbe(), device: workingSMC(),
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("funfan-diagnostics-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = try XCTUnwrap(SystemInfoCollector.save(report, to: directory))
        XCTAssertTrue(url.lastPathComponent.hasSuffix(".md"))
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("FunFan 诊断报告"))
    }

    // MARK: - 便捷

    private func status(_ report: DiagnosticReport, _ id: String) -> CapabilityStatus? {
        report.capabilities.first { $0.id == id }?.status
    }
}
