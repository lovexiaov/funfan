import XCTest
@testable import FunFanCore

/// 第三方接管检测：只信「手动模式」这个硬件事实。
final class ConflictDetectorTests: XCTestCase {

    private func state(
        index: Int = 0,
        mode: FanMode,
        isManual: Bool,
        target: Double = 3000
    ) -> FanState {
        FanState(
            index: index,
            actualRpm: target,
            targetRpm: target,
            minRpm: 1000,
            maxRpm: 4900,
            mode: mode,
            isManual: isManual
        )
    }

    func testManualModeWithoutLeaseIsForeign() {
        let states = [state(mode: .manualFixed, isManual: true)]
        let evidence = ConflictDetector.foreignEvidence(in: states, holdingControl: false)

        XCTAssertEqual(evidence.count, 1)
        XCTAssertEqual(evidence.first?.fanIndex, 0)
        XCTAssertEqual(evidence.first?.mode, .manualFixed)
        XCTAssertEqual(evidence.first?.targetRpm, 3000)
    }

    func testOwnControlIsNotAConflict() {
        // 我们自己持有租约时的手动模式，恰恰是正常状态；
        // 若不排除，用户每次点头调速都会看到「有别的软件在控制」。
        let states = [state(mode: .manualFixed, isManual: true)]
        XCTAssertTrue(ConflictDetector.foreignEvidence(in: states, holdingControl: true).isEmpty)
    }

    func testAutomaticFansAreNeverEvidence() {
        let states = [
            state(index: 0, mode: .automatic, isManual: false),
            state(index: 1, mode: .automatic, isManual: false)
        ]
        XCTAssertTrue(ConflictDetector.foreignEvidence(in: states, holdingControl: false).isEmpty)
    }

    func testOnlyManualFanIsReportedAmongMany() {
        let states = [
            state(index: 0, mode: .automatic, isManual: false),
            state(index: 1, mode: .manualCurve, isManual: true, target: 2200)
        ]
        let evidence = ConflictDetector.foreignEvidence(in: states, holdingControl: false)
        XCTAssertEqual(evidence.map(\.fanIndex), [1])
        XCTAssertEqual(evidence.first?.targetRpm, 2200)
    }

    func testUnknownModeIsStillTreatedAsManual() {
        // 未知模式但 isManual=true：硬件说在手动，就按手动处理，
        // 宁可多拦一次也不要和别人的控制打架。
        let states = [state(mode: .unknown, isManual: true)]
        XCTAssertEqual(ConflictDetector.foreignEvidence(in: states, holdingControl: false).count, 1)
    }

    func testNoFansMeansNoConflict() {
        XCTAssertTrue(ConflictDetector.foreignEvidence(in: [], holdingControl: false).isEmpty)
    }

    func testSummaryMentionsFanAndTarget() {
        let evidence = ForeignControlEvidence(fanIndex: 0, mode: .manualFixed, targetRpm: 3000)
        XCTAssertTrue(evidence.summary.contains("Fan 0"))
        XCTAssertTrue(evidence.summary.contains("3000"))
    }
}

/// 识别第三方软件（只用于解释原因，不参与「是否冲突」的判定）。
final class KnownFanControllersTests: XCTestCase {

    func testMatchesByBundleIdentifier() {
        XCTAssertEqual(
            KnownFanControllers.name(bundleIdentifier: "com.crystalidea.macsfancontrol", processName: nil),
            "Macs Fan Control"
        )
        // bundle id 大小写不该影响判断
        XCTAssertEqual(
            KnownFanControllers.name(bundleIdentifier: "COM.CRYSTALIDEA.MACSFANCONTROL", processName: nil),
            "Macs Fan Control"
        )
    }

    func testMatchesByProcessNameWhenBundleIdentifierUnknown() {
        XCTAssertEqual(KnownFanControllers.name(bundleIdentifier: nil, processName: "MacsFanControl"), "Macs Fan Control")
        XCTAssertEqual(KnownFanControllers.name(bundleIdentifier: nil, processName: "TG Pro Helper"), "TG Pro")
        XCTAssertEqual(KnownFanControllers.name(bundleIdentifier: nil, processName: "iStat Menus"), "iStat Menus")
    }

    func testUnknownSoftwareReturnsNil() {
        XCTAssertNil(KnownFanControllers.name(bundleIdentifier: "com.example.coolfan", processName: "CoolFan"))
        XCTAssertNil(KnownFanControllers.name(bundleIdentifier: nil, processName: nil))
        XCTAssertNil(KnownFanControllers.name(bundleIdentifier: "", processName: ""))
    }
}
