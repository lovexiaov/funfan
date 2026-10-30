import XCTest
@testable import FunFanCore

/// `ioft`（48.16 定点，64 位小端）编解码。
///
/// 全部字节取自真机或公开 issue 的原始 dump，不用人工构造的"漂亮数字"，
/// 目的是一旦哪天解码改错，测试能直接崩在这些真实样本上。
final class IOFTCodecTests: XCTestCase {

    // MARK: 真机样本（Mac16,10 / M4 Mac mini）

    /// `funfanctl raw --type ioft` 的原始字节 → 期望 ℃。
    private let macMiniSamples: [(key: String, bytes: [UInt8], celsius: Double)] = [
        ("TR0Z", [0xec, 0xd1, 0x33, 0x00, 0x00, 0x00, 0x00, 0x00], 51.8200),
        ("TR1d", [0xea, 0x2d, 0x2a, 0x00, 0x00, 0x00, 0x00, 0x00], 42.1794),
        ("TR2d", [0x4f, 0x82, 0x24, 0x00, 0x00, 0x00, 0x00, 0x00], 36.5090),
        ("TR3d", [0xa7, 0x97, 0x29, 0x00, 0x00, 0x00, 0x00, 0x00], 41.5924),
        ("TR4d", [0xbe, 0xe9, 0x28, 0x00, 0x00, 0x00, 0x00, 0x00], 40.9131),
        ("TR5d", [0x17, 0x72, 0x2a, 0x00, 0x00, 0x00, 0x00, 0x00], 42.4457),
    ]

    func testRealMachineSamples() {
        for sample in macMiniSamples {
            guard let value = SMCDataCodec.decodeIOFT(sample.bytes) else {
                return XCTFail("\(sample.key) 解码返回 nil")
            }
            XCTAssertEqual(value, sample.celsius, accuracy: 0.0001, "\(sample.key) 解码不符")
        }
    }

    /// 所有真机样本都必须落在温度合理区间内，否则会被 provider 的 5…131 过滤掉，
    /// 等于「支持了类型但还是少传感器」。
    func testRealMachineSamplesPassPlausibilityFilter() {
        for sample in macMiniSamples {
            let value = SMCDataCodec.decodeIOFT(sample.bytes)!
            XCTAssertTrue((5.0...131.0).contains(value), "\(sample.key) = \(value)℃ 越界")
        }
    }

    // MARK: 哨兵值（iSMC issue #39，M4 MacBook Air）

    /// 未接/不可用的探针会返回高字节全 1。
    /// 按有符号解得负温度，从而被合理性过滤丢弃——这正是我们依赖的行为。
    func testUnavailableProbeDecodesNegative() {
        let tr1d: [UInt8] = [0xf8, 0x3f, 0xea, 0xff, 0xff, 0xff, 0xff, 0xff]
        let tr3d: [UInt8] = [0xbb, 0xff, 0xe9, 0xff, 0xff, 0xff, 0xff, 0xff]

        XCTAssertEqual(SMCDataCodec.decodeIOFT(tr1d)!, -21.7507, accuracy: 0.001)
        XCTAssertEqual(SMCDataCodec.decodeIOFT(tr3d)!, -22.0002, accuracy: 0.001)

        XCTAssertFalse((5.0...131.0).contains(SMCDataCodec.decodeIOFT(tr1d)!))
        XCTAssertFalse((5.0...131.0).contains(SMCDataCodec.decodeIOFT(tr3d)!))
    }

    /// 同一 issue 里同机型正常的两个探针，必须解出正常温度。
    func testSameMachineHealthyProbes() {
        let tr2d: [UInt8] = [0x41, 0x27, 0x2e, 0x00, 0x00, 0x00, 0x00, 0x00]
        let tr4d: [UInt8] = [0xa8, 0x0d, 0x31, 0x00, 0x00, 0x00, 0x00, 0x00]

        XCTAssertEqual(SMCDataCodec.decodeIOFT(tr2d)!, 46.1533, accuracy: 0.001)
        XCTAssertEqual(SMCDataCodec.decodeIOFT(tr4d)!, 49.0533, accuracy: 0.001)
    }

    // MARK: 定点精度与边界

    func testFractionalPrecision() {
        // 最小正增量 = 1/65536
        let one: [UInt8] = [0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        XCTAssertEqual(SMCDataCodec.decodeIOFT(one)!, 1.0 / 65_536, accuracy: 1e-12)

        // 0.5℃ = 32768
        let half: [UInt8] = [0x00, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        XCTAssertEqual(SMCDataCodec.decodeIOFT(half)!, 0.5, accuracy: 1e-12)

        // 100℃ = 6_553_600 = 0x0064_0000 → 小端 00 00 64 00
        let hundred: [UInt8] = [0x00, 0x00, 0x64, 0x00, 0x00, 0x00, 0x00, 0x00]
        XCTAssertEqual(SMCDataCodec.decodeIOFT(hundred)!, 100.0, accuracy: 1e-9)
    }

    /// 高 4 字节必须被当作整数部分，不能被忽略成"只读低 32 位"。
    func testUpperBytesAreIntegerPart() {
        // 0x0000_0100_0000_0000 / 65536 = 65536℃（超出温度范围，但能证明没截断）
        let bytes: [UInt8] = [0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00]
        XCTAssertEqual(SMCDataCodec.decodeIOFT(bytes)!, 65_536.0, accuracy: 1e-6)
    }

    func testRejectsShortInput() {
        XCTAssertNil(SMCDataCodec.decodeIOFT([]))
        XCTAssertNil(SMCDataCodec.decodeIOFT([0xec, 0xd1, 0x33, 0x00]))
    }

    // MARK: 分派与写入

    func testDispatchByTypeCode() {
        let bytes: [UInt8] = [0xec, 0xd1, 0x33, 0x00, 0x00, 0x00, 0x00, 0x00]
        XCTAssertEqual(SMCDataCodec.decode(type: "ioft", bytes: bytes)!, 51.82, accuracy: 1e-4)
        // 类型码必须精确匹配：少写/多写一个字符都不能命中
        XCTAssertNil(SMCDataCodec.decode(type: "iof", bytes: bytes))
        XCTAssertNil(SMCDataCodec.decode(type: "ioft ", bytes: bytes))
    }

    /// ioft 只读：写入路径必须直接拒绝，绝不能凭猜测编码。
    func testEncodeIsUnsupported() {
        XCTAssertNil(SMCDataCodec.encode(type: "ioft", value: 50))
    }
}
