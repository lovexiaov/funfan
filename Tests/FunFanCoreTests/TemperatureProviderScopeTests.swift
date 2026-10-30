import XCTest
@testable import FunFanCore

/// 采样范围控制：UI 只展示主要类别，没必要每 0.5 s 读 180 个键。
final class TemperatureProviderScopeTests: XCTestCase {

    /// 混合类别键集：`Ta*`/`Tz*` 等无法识别的键归 `.other`。
    private let keys = ["Tp01", "Te05", "Tg0G", "Ts0P", "TA0P", "Tm0P", "TB0T", "Tz99", "TZ01"]

    private func table() -> [String: Double] {
        [
            "Tp01": 60, "Te05": 55, "Tg0G": 48, "Ts0P": 45,
            "TA0P": 30, "Tm0P": 40, "TB0T": 28, "Tz99": 50, "TZ01": 51,
        ]
    }

    func testDefaultScopeExcludesOtherCategory() {
        let provider = SMCTemperatureProvider(
            keyLister: { self.keys },
            reader: { self.table()[$0] ?? 0 }
        )

        let keys = provider.readings().map(\.descriptor.key)

        XCTAssertFalse(keys.contains("Tz99"), "未识别传感器默认不采样，避免无谓 IPC")
        XCTAssertFalse(keys.contains("TZ01"))
        XCTAssertEqual(keys.count, 7)
    }

    func testCustomScope() {
        let provider = SMCTemperatureProvider(
            keyLister: { self.keys },
            reader: { self.table()[$0] ?? 0 },
            includedCategories: [.cpu]
        )

        XCTAssertEqual(provider.readings().map(\.descriptor.key).sorted(), ["Te05", "Tp01"])
    }

    func testAllCategoriesScopeIncludesOther() {
        let provider = SMCTemperatureProvider(
            keyLister: { self.keys },
            reader: { self.table()[$0] ?? 0 },
            includedCategories: Set(SensorCategory.allCases)
        )

        XCTAssertEqual(provider.readings().count, 9)
    }

    func testKnownDescriptorsRespectsScope() {
        let provider = SMCTemperatureProvider(
            keyLister: { self.keys },
            reader: { self.table()[$0] ?? 0 },
            includedCategories: [.gpu]
        )
        _ = provider.readings()

        XCTAssertEqual(provider.knownDescriptors.map(\.key), ["Tg0G"])
    }
}
