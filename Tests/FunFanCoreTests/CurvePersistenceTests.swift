import XCTest
@testable import FunFanCore

/// 曲线持久化与预设。
///
/// 重点不在「能存能读」，而在**手改坏 JSON 之后不能让风扇失控**：
/// 越界温度、越界转速、单点曲线、重合点都必须被清洗掉。
final class CurvePersistenceTests: XCTestCase {

    private var directory: URL!
    private var fileURL: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("funfan-curve-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("curve.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var sample: FanCurve {
        FanCurve(points: [
            CurvePoint(celsius: 40, rpm: 1000),
            CurvePoint(celsius: 70, rpm: 2800),
            CurvePoint(celsius: 95, rpm: 4900),
        ])
    }

    // MARK: 读写

    func testLoadMissingFileReturnsNil() {
        XCTAssertNil(CurvePersistence(fileURL: fileURL).load())
    }

    func testLoadCorruptFileReturnsNil() throws {
        try Data("这不是 JSON".utf8).write(to: fileURL)
        XCTAssertNil(CurvePersistence(fileURL: fileURL).load())
    }

    func testRoundTrip() throws {
        let persistence = CurvePersistence(fileURL: fileURL)
        try persistence.save(sample)

        let loaded = try XCTUnwrap(persistence.load())
        XCTAssertEqual(loaded, sample)
    }

    func testDefaultPathIsUnderApplicationSupport() {
        let path = CurvePersistence.defaultFileURL().path
        XCTAssertTrue(path.hasSuffix("FunFan/curve.json"), path)
    }

    // MARK: 清洗

    func testSinglePointIsRejected() {
        XCTAssertNil(CurvePersistence.sanitize(FanCurve(points: [CurvePoint(celsius: 60, rpm: 2000)])))
        XCTAssertNil(CurvePersistence.sanitize(FanCurve(points: [])))
    }

    func testOutOfRangeValuesAreClamped() {
        let wild = FanCurve(points: [
            CurvePoint(celsius: -40, rpm: -500),
            CurvePoint(celsius: 500, rpm: 99_999),
        ])
        let cleaned = try? XCTUnwrap(CurvePersistence.sanitize(wild))
        XCTAssertEqual(cleaned?.points.first?.celsius, 20)
        XCTAssertEqual(cleaned?.points.first?.rpm, 0)
        XCTAssertEqual(cleaned?.points.last?.celsius, 110)
        XCTAssertEqual(cleaned?.points.last?.rpm, 12_000)
    }

    func testPointsAreSorted() {
        // 构造函数会排序，这里直接验证清洗后依旧有序（防手改 JSON 顺序打乱）
        let shuffled = FanCurve(points: [
            CurvePoint(celsius: 90, rpm: 4000),
            CurvePoint(celsius: 40, rpm: 1000),
            CurvePoint(celsius: 65, rpm: 2500),
        ])
        let cleaned = CurvePersistence.sanitize(shuffled)
        XCTAssertEqual(cleaned?.points.map(\.celsius), [40, 65, 90])
    }

    func testNearDuplicatePointsAreMerged() {
        let overlapping = FanCurve(points: [
            CurvePoint(celsius: 60, rpm: 2000),
            CurvePoint(celsius: 60.2, rpm: 2600),   // 与上一点间隔 < 0.5℃
        ])
        let cleaned = CurvePersistence.sanitize(overlapping)
        // 合并后只剩一个点 → 不足以构成曲线
        XCTAssertNil(cleaned)
    }

    func testTooManyPointsAreTruncatedKeepingEnds() {
        let many = FanCurve(points: (0..<20).map { index in
            CurvePoint(celsius: 30 + Double(index) * 3, rpm: 1000 + Double(index) * 200)
        })
        let cleaned = try? XCTUnwrap(CurvePersistence.sanitize(many))
        XCTAssertEqual(cleaned?.points.count, CurvePersistence.maxPoints)
        XCTAssertEqual(cleaned?.points.first?.celsius, 30)          // 首点保留
        XCTAssertEqual(cleaned?.points.last?.celsius, 87)           // 末点保留
    }

    func testNonFiniteValuesAreDropped() {
        let broken = FanCurve(points: [
            CurvePoint(celsius: .nan, rpm: 2000),
            CurvePoint(celsius: 60, rpm: .infinity),
            CurvePoint(celsius: 80, rpm: 4000),
        ])
        XCTAssertNil(CurvePersistence.sanitize(broken))   // 只剩 1 个有效点
    }
}

/// 预设：必须自适应机型区间、单调不减、能被识别回原预设。
final class CurvePresetTests: XCTestCase {

    private let mini = FanLimits(minRpm: 1000, maxRpm: 4900)
    private let laptop = FanLimits(minRpm: 1200, maxRpm: 6800)

    func testPresetsStayInsideLimits() {
        for preset in CurvePreset.allCases {
            for limits in [mini, laptop] {
                let curve = preset.curve(limits: limits)
                XCTAssertEqual(curve.points.count, preset.shape.count)
                for point in curve.points {
                    XCTAssertGreaterThanOrEqual(point.rpm, limits.minRpm)
                    XCTAssertLessThanOrEqual(point.rpm, limits.normalizedMax)
                }
            }
        }
    }

    func testPresetsAreMonotonic() {
        for preset in CurvePreset.allCases {
            let points = preset.curve(limits: mini).points
            for pair in zip(points, points.dropFirst()) {
                XCTAssertLessThanOrEqual(pair.0.rpm, pair.1.rpm, "\(preset.label) 曲线出现下降段")
            }
        }
    }

    /// 同一份预设在不同机型上应给出成比例的转速，而不是同一串绝对值。
    func testPresetsScaleWithFanRange() {
        let onMini = CurvePreset.balanced.curve(limits: mini)
        let onLaptop = CurvePreset.balanced.curve(limits: laptop)
        XCTAssertLessThan(onMini.points.last!.rpm, onLaptop.points.last!.rpm)
        // 最高点都应该是满转
        XCTAssertEqual(onMini.points.last!.rpm, mini.normalizedMax)
        XCTAssertEqual(onLaptop.points.last!.rpm, laptop.normalizedMax)
    }

    func testPerformanceIsMoreAggressiveThanQuiet() {
        let quiet = CurvePreset.quiet.curve(limits: mini)
        let performance = CurvePreset.performance.curve(limits: mini)
        // 60℃ 时性能档必须明显高于静音档
        XCTAssertGreaterThan(
            try XCTUnwrap(performance.rpm(at: 60)),
            try XCTUnwrap(quiet.rpm(at: 60))
        )
    }

    func testMatchingRecoversPreset() {
        for preset in CurvePreset.allCases {
            let curve = preset.curve(limits: mini)
            XCTAssertEqual(CurvePreset.matching(curve, limits: mini), preset)
        }
    }

    func testMatchingReturnsNilForCustomCurve() {
        let custom = FanCurve(points: [
            CurvePoint(celsius: 33, rpm: 1500),
            CurvePoint(celsius: 57, rpm: 5000),
        ])
        XCTAssertNil(CurvePreset.matching(custom, limits: mini))
    }
}
