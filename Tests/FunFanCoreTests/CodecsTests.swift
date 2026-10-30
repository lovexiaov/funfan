import XCTest
@testable import FunFanCore

final class CodecsTests: XCTestCase {

    // MARK: flt（小端 float32）

    func testFLTRoundTrip() {
        for value in [0.0, 72.5, 3000.0, 20.25, 100.0] {
            let bytes = SMCDataCodec.encodeFLT(value)
            XCTAssertEqual(bytes.count, 4)
            guard let decoded = SMCDataCodec.decodeFLT(bytes) else {
                return XCTFail("flt decode returned nil for \(value)")
            }
            XCTAssertEqual(decoded, value, accuracy: 1e-4, "flt round trip failed for \(value)")
        }
    }

    func testFLTKnownBytes() {
        // 1.0f 的小端字节为 00 00 80 3F
        let bytes: [UInt8] = [0x00, 0x00, 0x80, 0x3F]
        XCTAssertEqual(SMCDataCodec.decodeFLT(bytes)!, 1.0, accuracy: 1e-6)
    }

    func testFLTRejectsShortInput() {
        XCTAssertNil(SMCDataCodec.decodeFLT([0x00, 0x01]))
    }

    // MARK: fpe2（大端定点 / 4）

    func testFPE2DecodeRPM() {
        // 3000 RPM -> raw = 3000*4 = 12000 = 0x2EE0
        let bytes: [UInt8] = [0x2E, 0xE0]
        XCTAssertEqual(SMCDataCodec.decodeFPE2(bytes)!, 3000.0, accuracy: 1e-6)
    }

    func testFPE2RoundTrip() {
        for value in [0.0, 1200.0, 3000.0, 6200.0] {
            let bytes = SMCDataCodec.encodeFPE2(value)
            XCTAssertEqual(bytes.count, 2)
            XCTAssertEqual(SMCDataCodec.decodeFPE2(bytes)!, value, accuracy: 0.25)
        }
    }

    // MARK: sp78（大端有符号 / 256）

    func testSP78Decode() {
        // 25.5°C -> raw = 25.5*256 = 6528 = 0x1980
        let bytes: [UInt8] = [0x19, 0x80]
        XCTAssertEqual(SMCDataCodec.decodeSP78(bytes)!, 25.5, accuracy: 1e-6)
    }

    // MARK: ui8 / ui16 / ui32

    func testUnsignedDecode() {
        XCTAssertEqual(SMCDataCodec.decodeUInt8([0x50])!, 80.0)
        XCTAssertEqual(SMCDataCodec.decodeUInt16([0x01, 0x02])!, 258.0)
        XCTAssertEqual(SMCDataCodec.decodeUInt32([0x00, 0x00, 0x01, 0x00])!, 256.0)
    }

    // MARK: 类型分派

    func testTypeDispatch() {
        XCTAssertEqual(SMCDataCodec.decode(type: "fpe2", bytes: [0x2E, 0xE0])!, 3000.0, accuracy: 1e-6)
        XCTAssertEqual(SMCDataCodec.decode(type: "sp78", bytes: [0x19, 0x80])!, 25.5, accuracy: 1e-6)
        XCTAssertEqual(SMCDataCodec.decode(type: "ui8 ", bytes: [0x64])!, 100.0)
        XCTAssertNil(SMCDataCodec.decode(type: "????", bytes: [0x01, 0x02]))
    }

    // MARK: FourCC

    func testFourCCRoundTrip() {
        for key in ["F0Ac", "TC0P", "Ftst", "F0md"] {
            XCTAssertEqual(FourCC.decode(FourCC.encode(key)), key)
        }
    }

    func testFanKeyNameBuilders() {
        XCTAssertEqual(SMCKeyName.fanActual(0), "F0Ac")
        XCTAssertEqual(SMCKeyName.fanTarget(1), "F1Tg")
        XCTAssertEqual(SMCKeyName.fanMin(0), "F0Mn")
        XCTAssertEqual(SMCKeyName.fanMax(0), "F0Mx")
        XCTAssertEqual(SMCKeyName.fanModeCandidates(0), ["F0Md", "F0md"])
        XCTAssertEqual(SMCKeyName.fanCount, "FNum")
        XCTAssertEqual(SMCKeyName.ftst, "Ftst")
    }
}
