import XCTest
@testable import FunFanCore

/// T15：规则持久化——必须是「坏文件也不崩、异常值不写入硬件」的安全实现。
final class RulePersistenceTests: XCTestCase {

    private var directory: URL!
    private var fileURL: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("funfan-rules-\(UUID().uuidString)", isDirectory: true)
        fileURL = directory.appendingPathComponent("rules.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func rule(
        name: String = "CPU 高温",
        subject: SensorSubject = .category(.cpu),
        comparator: RuleComparator = .greaterThanOrEqual,
        threshold: Double = 70,
        action: RuleAction = .setPercent(60),
        hysteresis: Double = 3
    ) -> FanRule {
        FanRule(
            name: name,
            subject: subject,
            comparator: comparator,
            thresholdCelsius: threshold,
            action: action,
            hysteresisCelsius: hysteresis
        )
    }

    // MARK: - 往返

    func testSaveThenLoadRoundTripsAllFields() throws {
        let store = RulePersistence(fileURL: fileURL)
        let original = [
            rule(name: "CPU 高", subject: .category(.cpu), threshold: 70, action: .setPercent(60)),
            rule(name: "单键", subject: .key("Tg0G"), comparator: .greaterThan, threshold: 62, action: .setRpm(3200), hysteresis: 4),
        ]

        try store.save(original)
        let loaded = store.load()

        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0].id, original[0].id)
        XCTAssertEqual(loaded[0].name, "CPU 高")
        XCTAssertEqual(loaded[0].subject, .category(.cpu))
        XCTAssertEqual(loaded[0].action, .setPercent(60))
        XCTAssertEqual(loaded[1].subject, .key("Tg0G"))
        XCTAssertEqual(loaded[1].comparator, .greaterThan)
        XCTAssertEqual(loaded[1].thresholdCelsius, 62)
        XCTAssertEqual(loaded[1].hysteresisCelsius, 4)
    }

    func testSaveCreatesParentDirectory() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))

        try RulePersistence(fileURL: fileURL).save([rule()])

        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    // MARK: - 坏输入

    func testLoadMissingFileReturnsEmpty() {
        XCTAssertEqual(RulePersistence(fileURL: fileURL).load(), [])
    }

    func testLoadCorruptJSONReturnsEmptyWithoutThrowing() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{ this is not json".utf8).write(to: fileURL)

        XCTAssertEqual(RulePersistence(fileURL: fileURL).load(), [])
    }

    // MARK: - 清洗（防止坏数据写出危险转速）

    func testSanitizeClampsThresholdIntoPhysicalRange() {
        let store = RulePersistence(fileURL: fileURL)
        let crazy = [
            rule(name: "太低", threshold: -40),
            rule(name: "太高", threshold: 900),
        ]

        let cleaned = store.sanitize(crazy)

        XCTAssertEqual(cleaned[0].thresholdCelsius, 0)
        XCTAssertEqual(cleaned[1].thresholdCelsius, 120)
    }

    func testSanitizeClampsHysteresisAndPercent() {
        let cleaned = RulePersistence(fileURL: fileURL).sanitize([
            rule(threshold: 70, action: .setPercent(320), hysteresis: -5),
            rule(threshold: 70, action: .setRpm(-100), hysteresis: 99),
        ])

        XCTAssertEqual(cleaned[0].hysteresisCelsius, 0)
        XCTAssertEqual(cleaned[0].action, .setPercent(100))
        XCTAssertEqual(cleaned[1].hysteresisCelsius, 30)
        XCTAssertEqual(cleaned[1].action, .setRpm(0))
    }

    func testSanitizeDropsDuplicatedIDsAndRepairsEmptyName() {
        let duplicated = rule(name: "A")
        let copy = rule(name: "B")

        var second = copy
        second.id = duplicated.id

        let cleaned = RulePersistence(fileURL: fileURL).sanitize([
            duplicated,
            second,
            rule(name: "   "),
        ])

        XCTAssertEqual(cleaned.count, 2, "重复 ID 必须去掉，否则 UI 的 ForEach 会错乱")
        XCTAssertEqual(cleaned[0].id, duplicated.id)
        XCTAssertFalse(cleaned[1].name.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    func testSanitizeKeepsDisabledState() {
        var disabled = rule(name: "停用")
        disabled.enabled = false

        let cleaned = RulePersistence(fileURL: fileURL).sanitize([disabled])

        XCTAssertEqual(cleaned.count, 1)
        XCTAssertFalse(cleaned[0].enabled)
    }

    // MARK: - 首次启动模板

    func testSampleRulesAreUsableAndSafe() {
        let samples = RulePersistence.sampleRules

        XCTAssertFalse(samples.isEmpty)
        for rule in samples {
            XCTAssertTrue(rule.enabled)
            XCTAssertGreaterThan(rule.thresholdCelsius, 40, "阈值过低会长期占用手动控制")
            XCTAssertLessThan(rule.thresholdCelsius, 110)
        }
    }

    func testLoadAppliesSanitize() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bad = rule(name: "", threshold: 500, action: .setPercent(500), hysteresis: -1)
        let data = try JSONEncoder().encode([bad])
        try data.write(to: fileURL)

        let loaded = RulePersistence(fileURL: fileURL).load()

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].thresholdCelsius, 120)
        XCTAssertEqual(loaded[0].action, .setPercent(100))
        XCTAssertEqual(loaded[0].hysteresisCelsius, 0)
        XCTAssertFalse(loaded[0].name.isEmpty)
    }
}
