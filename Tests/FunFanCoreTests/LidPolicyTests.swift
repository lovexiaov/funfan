import XCTest
@testable import FunFanCore

/// T16b：合盖判定（`LidPolicy`）。
///
/// 本机无法在单测里真的合盖，因此把「信号 → 结论」的映射做成纯函数来测，
/// 由 GUI 侧 `LidMonitor` 负责采集信号（NSScreen / 休眠通知）。
final class LidPolicyTests: XCTestCase {

    func testLaptopWithBuiltinDisplayOnlineIsOpen() {
        XCTAssertFalse(LidPolicy.isClosed(
            builtinDisplayOnline: true, externalDisplayOnline: false, isPortable: true))
        XCTAssertFalse(LidPolicy.isClosed(
            builtinDisplayOnline: true, externalDisplayOnline: true, isPortable: true))
    }

    func testLaptopWithoutBuiltinDisplayIsClosed() {
        // 合盖 + 外接屏：系统不睡，但内建面板断电下线
        XCTAssertTrue(LidPolicy.isClosed(
            builtinDisplayOnline: false, externalDisplayOnline: true, isPortable: true))
    }

    func testNoBuiltinAndNoExternalIsNotTreatedAsClosed() {
        // 只有虚拟屏/远程会话、或无头：内建屏看不见但没有外接屏，
        // 不能判成合盖，否则规则会永久停摆
        XCTAssertFalse(LidPolicy.isClosed(
            builtinDisplayOnline: false, externalDisplayOnline: false, isPortable: true))
    }

    func testDesktopNeverReportedClosed() {
        // 台式机没有内建屏，绝不能被判成「一直合着盖」
        XCTAssertFalse(LidPolicy.isClosed(
            builtinDisplayOnline: false, externalDisplayOnline: true, isPortable: false))
        XCTAssertFalse(LidPolicy.isClosed(
            builtinDisplayOnline: true, externalDisplayOnline: true, isPortable: false))
    }

    func testPortableModelDetection() {
        // 现代 Apple Silicon 是 Mac16,10 这种编号（本机就是 Mac mini M4），
        // 光看型号分不出笔记本还是台式机，只能靠电池
        XCTAssertFalse(LidPolicy.isPortable(model: "Mac16,10", hasBattery: false))
        XCTAssertTrue(LidPolicy.isPortable(model: "Mac16,10", hasBattery: true))
        // 老机型标识作为兜底（电池读取失败也能认出来）
        XCTAssertTrue(LidPolicy.isPortable(model: "MacBookPro18,3", hasBattery: false))
        XCTAssertTrue(LidPolicy.isPortable(model: "MacBookAir10,1", hasBattery: false))
        // 台式机
        XCTAssertFalse(LidPolicy.isPortable(model: "Mac14,12", hasBattery: false))  // Mac mini
        XCTAssertFalse(LidPolicy.isPortable(model: "Mac13,1", hasBattery: false))   // Mac Studio
        XCTAssertFalse(LidPolicy.isPortable(model: "", hasBattery: false))          // sysctl 读失败
    }
}
