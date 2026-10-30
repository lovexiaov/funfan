import Foundation
import AppKit
import Combine
import ServiceManagement
import FunFanCore

/// 特权组件（root LaunchDaemon）的安装与状态。
///
/// 用 `SMAppService.daemon(plistName:)`：系统弹**一次**授权，之后升级 App
/// 不需要重新授权，卸载 App 时后台项也会一起清掉 —— 这正是 Spec §6 要的
/// 「helper 一次授权」。旧的 `scripts/install-helper.sh` 走
/// `/Library/LaunchDaemons` 直装，每次装都要 sudo，仅保留作开发期回退。
///
/// 前提条件（缺一不可，缺了就明确告诉用户缺哪个）：
/// 1. 从 .app 里运行 —— 裸二进制的 `Bundle.main.bundleIdentifier` 是 nil；
/// 2. 包内有 `Contents/Library/LaunchDaemons/com.funfan.helper.plist`；
/// 3. App 与 helper 签名一致 —— adhoc 能注册但系统多半拒绝启动，
///    正式分发必须 Developer ID。
final class HelperInstaller: ObservableObject {

    static let daemonPlistName = "com.funfan.helper.plist"

    @Published private(set) var status: HelperInstallStatus = .notFound
    @Published private(set) var error: String?
    @Published private(set) var isBusy = false

    private var service: SMAppService?

    init() {
        service = Self.makeService()
        status = Self.currentStatus()
    }

    // MARK: - 环境

    /// 构造系统的 daemon 注册器；不满足前提时返回 nil 并给出原因。
    static func makeService() -> SMAppService? {
        guard Bundle.main.bundleIdentifier != nil,
              Bundle.main.bundlePath.hasSuffix(".app") else { return nil }
        let plist = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchDaemons/\(daemonPlistName)")
        guard FileManager.default.fileExists(atPath: plist.path) else { return nil }
        return SMAppService.daemon(plistName: daemonPlistName)
    }

    static var isSupported: Bool { makeService() != nil }

    static var unsupportedReason: String {
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundlePath.hasSuffix(".app") else {
            return "当前以开发模式运行（裸二进制），系统无法注册后台组件。用 make app 打包后从 FunFan.app 启动。"
        }
        return "包内缺少 Contents/Library/LaunchDaemons/\(daemonPlistName)，这是个有问题的构建产物，请重新 make app。"
    }

    static func currentStatus() -> HelperInstallStatus {
        guard let service = makeService() else { return .notFound }
        return HelperInstallStatus(rawStatus: service.status.rawValue)
    }

    // MARK: - 操作

    /// 旧脚本把 helper 装在 /Library/PrivilegedHelperTools，用的是同一个 label。
    /// 两份同时存在会抢 Mach service，表现为「风扇忽上忽下」——必须先卸旧的。
    static var legacyInstallDetected: Bool {
        FileManager.default.fileExists(atPath: HelperConstants.installedBinaryPath)
    }

    func install() {
        guard let service else {
            error = Self.unsupportedReason
            return
        }
        if Self.legacyInstallDetected {
            error = "检测到旧式脚本安装（/Library/PrivilegedHelperTools/com.funfan.helper）。"
                + "请先执行 sudo bash scripts/install-helper.sh uninstall 卸掉，"
                + "再回来点安装——两种安装方式同名同服务，不能共存。"
            return
        }
        isBusy = true
        error = nil
        do {
            try service.register()
        } catch {
            self.error = Self.describe(error)
        }
        isBusy = false
        refresh()
    }

    func uninstall() {
        guard let service else {
            error = Self.unsupportedReason
            return
        }
        isBusy = true
        error = nil
        do {
            try service.unregister()
        } catch {
            self.error = Self.describe(error)
        }
        isBusy = false
        refresh()
    }

    func refresh() {
        status = Self.currentStatus()
    }

    /// 需要用户批准时，直接把人送到「登录项与扩展」页面 ——
    /// 让人自己去系统设置里翻三层菜单是最容易被放弃的一步。
    func openApprovalSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - 错误解释

    /// 把 `SMAppServiceErrorDomain` 的裸错误码翻译成「为什么 + 怎么办」。
    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        let head = "注册失败：\(ns.localizedDescription)（\(ns.domain) \(ns.code)）"

        // 这里的判断顺序按实测频率排：签名问题最常见，其次是被系统策略拦住。
        if ns.domain == "SMAppServiceErrorDomain" || ns.domain == NSCocoaErrorDomain {
            return head
                + "。常见原因：① App 未用 Developer ID 签名（adhoc 无法让系统信任后台组件）；"
                + "② App 放在桌面/下载等临时位置（先拖进「应用程序」再试）；"
                + "③ 之前用旧脚本在 /Library/LaunchDaemons 装过同名服务，先 sudo bash scripts/install-helper.sh uninstall。"
        }
        return head
    }
}
