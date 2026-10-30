import XCTest
@testable import FunFanCore

/// 写入侧的编解码测试。
///
/// 写入比读取危险：字节长度/字节序错了会写坏 SMC 状态，
/// 因此这里逐类型锁定「输出字节长度 == 键的 dataSize」与字节序。
final class WriteCodecTests: XCTestCase {

    // MARK: - flt（小端 float32）

    func testEncodeFLTProducesFourLittleEndianBytes() throws {
        let bytes = try XCTUnwrap(SMCDataCodec.encode(type: "flt ", value: 3000))
        XCTAssertEqual(bytes.count, 4)

        let bits = UInt32(bytes[0])
            | (UInt32(bytes[1]) << 8)
            | (UInt32(bytes[2]) << 16)
            | (UInt32(bytes[3]) << 24)
        XCTAssertEqual(Float(bitPattern: bits), 3000, accuracy: 0.001)
    }

    func testEncodeFLTRoundTripsThroughDecode() throws {
        let bytes = try XCTUnwrap(SMCDataCodec.encode(type: "flt ", value: 4900))
        XCTAssertEqual(try XCTUnwrap(SMCDataCodec.decodeFLT(bytes)), 4900, accuracy: 0.001)
    }

    // MARK: - fpe2（大端定点 / 4）

    func testEncodeFPE2DividesByFourBigEndian() throws {
        let bytes = try XCTUnwrap(SMCDataCodec.encode(type: "fpe2", value: 2000))
        XCTAssertEqual(bytes, [0x1F, 0x40], "2000 × 4 = 8000 = 0x1F40，大端")
    }

    func testEncodeFPE2RoundTripsThroughDecode() throws {
        let bytes = try XCTUnwrap(SMCDataCodec.encode(type: "fpe2", value: 1234.5))
        XCTAssertEqual(try XCTUnwrap(SMCDataCodec.decodeFPE2(bytes)), 1234.5, accuracy: 0.25)
    }

    func testEncodeFPE2DoesNotOverflowOnHugeValue() throws {
        let bytes = try XCTUnwrap(SMCDataCodec.encode(type: "fpe2", value: 1_000_000))
        XCTAssertEqual(bytes, [0xFF, 0xFF], "超范围应饱和到 UInt16 上界，不得回绕")
    }

    // MARK: - ui8 / ui16 / ui32

    func testEncodeUInt8IsSingleByte() throws {
        XCTAssertEqual(try XCTUnwrap(SMCDataCodec.encode(type: "ui8 ", value: 1)), [1])
        XCTAssertEqual(try XCTUnwrap(SMCDataCodec.encode(type: "ui8 ", value: 0)), [0])
    }

    func testEncodeUInt16IsBigEndian() throws {
        XCTAssertEqual(try XCTUnwrap(SMCDataCodec.encode(type: "ui16", value: 0x1234)), [0x12, 0x34])
    }

    func testEncodeUInt32IsBigEndian() throws {
        XCTAssertEqual(
            try XCTUnwrap(SMCDataCodec.encode(type: "ui32", value: 0x1234_5678)),
            [0x12, 0x34, 0x56, 0x78]
        )
    }

    // MARK: - 负数与边界

    func testEncodeUInt8ClampsNegativeToZero() throws {
        XCTAssertEqual(try XCTUnwrap(SMCDataCodec.encode(type: "ui8 ", value: -5)), [0])
    }

    // MARK: - 不支持的类型

    func testEncodeReturnsNilForUnsupportedType() {
        XCTAssertNil(SMCDataCodec.encode(type: "ch8*", value: 1))
        XCTAssertNil(SMCDataCodec.encode(type: "flag", value: 1))
    }

    /// 每一种可写类型都必须产出「与 dataSize 一致」的字节数，否则写入会被固件拒绝。
    func testEveryWritableTypeMatchesItsDataSize() throws {
        let expectations: [(type: String, dataSize: Int)] = [
            ("flt ", 4), ("fpe2", 2), ("ui8 ", 1), ("ui16", 2), ("ui32", 4), ("sp78", 2),
        ]
        for item in expectations {
            let bytes = try XCTUnwrap(
                SMCDataCodec.encode(type: item.type, value: 100),
                "类型 \(item.type) 应可编码"
            )
            XCTAssertEqual(bytes.count, item.dataSize, "类型 \(item.type) 的字节长度必须等于 dataSize")
        }
    }
}
