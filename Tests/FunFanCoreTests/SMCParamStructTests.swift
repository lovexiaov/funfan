import XCTest
@testable import FunFanCore

final class SMCParamStructTests: XCTestCase {

    /// 关键工程约束：结构体必须严格 80 字节，否则 IOConnectCallStructMethod 收发错位。
    func testSizeIsExactly80Bytes() {
        XCTAssertEqual(MemoryLayout<SMCParamStruct>.size, 80)
    }

    /// 逐字段偏移必须与 Apple `smc.h` 的 C 布局完全一致，否则与固件交互会错位。
    func testFieldOffsetsMatchCLayout() {
        func offset(_ kp: PartialKeyPath<SMCParamStruct>) -> Int {
            MemoryLayout<SMCParamStruct>.offset(of: kp) ?? -1
        }
        XCTAssertEqual(offset(\SMCParamStruct.key), 0)
        XCTAssertEqual(offset(\SMCParamStruct.vers), 4)
        XCTAssertEqual(offset(\SMCParamStruct.pLimitData), 12)
        XCTAssertEqual(offset(\SMCParamStruct.keyInfo), 28)
        XCTAssertEqual(offset(\SMCParamStruct.result), 40)
        XCTAssertEqual(offset(\SMCParamStruct.status), 41)
        XCTAssertEqual(offset(\SMCParamStruct.data8), 42)
        XCTAssertEqual(offset(\SMCParamStruct.data32), 44)
        XCTAssertEqual(offset(\SMCParamStruct.bytes), 48)
    }

    func testKeyInfoSizeIs12() {
        XCTAssertEqual(MemoryLayout<SMCParamStruct.KeyInfo>.size, 12)
    }

    func testDefaultFieldsAreZero() {
        let s = SMCParamStruct()
        XCTAssertEqual(s.key, 0)
        XCTAssertEqual(s.data8, 0)
        XCTAssertEqual(s.result, 0)
    }

    func testCommandRawValues() {
        XCTAssertEqual(SMCCommand.readBytes.rawValue, 5)
        XCTAssertEqual(SMCCommand.writeBytes.rawValue, 6)
        XCTAssertEqual(SMCCommand.getKeyInfo.rawValue, 9)
    }
}
