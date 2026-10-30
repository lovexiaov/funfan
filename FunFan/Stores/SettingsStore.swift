import Foundation
import Combine
import AppKit
import ServiceManagement

/// 设置项：登录启动 + 菜单栏显示内容。
///
/// 只做两件**真的会生效**的事，不做「看起来能配但没人读」的假开关：
/// 1. 登录启动走 `SMAppService`（macOS 13+ 的系统登录项 API）；
/// 2. 菜单栏是否显示温度写进 `UserDefaults`，`AppDelegate` 每次刷新标题时读它。
///
/// 开发态（未打包成 .app）注册登录项必然失败，这里显式识别并说明原因，
/// 而不是把系统错误码丢给用户。
final class SettingsStore: ObservableObject {

    enum LoginItem: Equatable {
        case enabled
        case disabled
        /// 环境不支持（开发态裸二进制 / 未签名打包）。
        case unavailable(reason: String)

        var isOn: Bool { self == .enabled }
    }

    /// 菜单栏显示温度的偏好键（`AppDelegate` 读同一个键）。
    static let showsTemperatureKey = "FunFan.menuBarShowsTemperature"

    @Published private(set) var loginItem: LoginItem = .disabled
    @Published private(set) var loginItemError: String?

    @Published var showsMenuBarTemperature: Bool {
        didSet {
            guard showsMenuBarTemperature != oldValue else { return }
            defaults.set(showsMenuBarTemperature, forKey: Self.showsTemperatureKey)
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // 默认开启：菜单栏图标旁的温度是这个工具最主要的「一眼可见」信息
        if defaults.object(forKey: Self.showsTemperatureKey) == nil {
            defaults.set(true, forKey: Self.showsTemperatureKey)
        }
        self.showsMenuBarTemperature = defaults.bool(forKey: Self.showsTemperatureKey)
        refreshLoginItem()
    }

    // MARK: - 登录启动

    /// 裸二进制（`.build/debug/FunFan`）没有 bundle，`SMAppService` 注册不了。
    private var isBundledApp: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")
    }

    func refreshLoginItem() {
        guard isBundledApp else {
            loginItem = .unavailable(reason: "当前以开发模式运行（未打包成 .app），系统无法注册登录项")
            return
        }
        loginItem = SMAppService.mainApp.status == .enabled ? .enabled : .disabled
    }

    func setLoginItem(enabled: Bool) {
        applyLoginItem(enabled)
    }

    private func applyLoginItem(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemError = nil
        } catch {
            loginItemError = "设置失败：\(error.localizedDescription)"
        }
        refreshLoginItem()
    }

    // MARK: - 展示信息

    var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        switch (short, build) {
        case let (short?, build?): return "\(short) (\(build))"
        case let (short?, nil): return short
        default: return "开发版"
        }
    }
}
