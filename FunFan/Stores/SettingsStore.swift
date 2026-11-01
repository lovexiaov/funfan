import Foundation
import Combine
import AppKit
import SwiftUI
import ServiceManagement

/// 设置项：外观 + 登录启动 + 菜单栏显示内容。
///
/// 原则：只做**真的会生效**的事，不做「看起来能配但没人读」的假开关：
/// 1. 外观三态（跟随系统 / 浅色 / 深色）落到窗口 `appearance`，
///    SwiftUI 侧的 `colorScheme` 随之改变，色令牌自动换套；
/// 2. 登录启动走 `SMAppService`（macOS 13+ 的系统登录项 API）；
/// 3. 菜单栏是否显示温度写进 `UserDefaults`，`AppDelegate` 每次刷新标题时读它。
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

    /// 外观三态。
    ///
    /// 为什么不提供更多选项（比如「自动+反色」「高对比」）：macOS 本身已有
    /// 全局设置，这里只解决「这个 App 想单独设成深/浅」的现实需求。
    enum Appearance: String, CaseIterable, Identifiable {
        case system
        case light
        case dark

        var id: String { rawValue }

        var label: String {
            switch self {
            case .system: return "跟随系统"
            case .light: return "浅色"
            case .dark: return "深色"
            }
        }

        /// `nil` 表示交还给系统（窗口 `appearance` = nil）。
        var nsAppearance: NSAppearance? {
            switch self {
            case .system: return nil
            case .light: return NSAppearance(named: .aqua)
            case .dark: return NSAppearance(named: .darkAqua)
            }
        }

        var colorScheme: ColorScheme? {
            switch self {
            case .system: return nil
            case .light: return .light
            case .dark: return .dark
            }
        }
    }

    /// 菜单栏显示温度的偏好键（`AppDelegate` 读同一个键）。
    static let showsTemperatureKey = "FunFan.menuBarShowsTemperature"
    static let appearanceKey = "FunFan.appearance"

    @Published private(set) var loginItem: LoginItem = .disabled
    @Published private(set) var loginItemError: String?

    /// 外观变化后由 `AppDelegate` 把它贴到所有窗口上。
    ///
    /// 刻意**不**用 `NSApp.appearance`：那是全局覆盖，会把菜单栏图标、
    /// 系统弹出的文件对话框一起反转，用户会觉得整个系统都变了。
    var onAppearanceChange: ((Appearance) -> Void)?

    @Published var appearance: Appearance {
        didSet {
            guard appearance != oldValue else { return }
            defaults.set(appearance.rawValue, forKey: Self.appearanceKey)
            onAppearanceChange?(appearance)
        }
    }

    @Published var showsMenuBarTemperature: Bool {
        didSet {
            guard showsMenuBarTemperature != oldValue else { return }
            defaults.set(showsMenuBarTemperature, forKey: Self.showsTemperatureKey)
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if defaults.object(forKey: Self.appearanceKey) == nil {
            defaults.set(Appearance.system.rawValue, forKey: Self.appearanceKey)
        }
        self.appearance = Appearance(rawValue: defaults.string(forKey: Self.appearanceKey) ?? "") ?? .system

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
