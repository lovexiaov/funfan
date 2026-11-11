import Foundation
import Combine
import AppKit
import FunFanCore

/// 检查更新的界面状态机。
///
/// 职责边界很窄：**只回答「有没有新版本」并提供一个下载链接**。
/// 不做下载、不做替换、不重启 App——原因见 `openDownloadPage` 的注释。
///
/// 另一条边界：这里不判断「哪个版本更新」。所有版本比较都在
/// `UpdateChecker` / `SemanticVersion` 里，且被单测钉死。GUI 只负责显示，
/// 一旦这里也写比较逻辑，就会出现「界面说有、实际没有」的两套结论。
/// `@unchecked Sendable` 的理由：唯一的跨线程路径是「网络回来之后把结果丢回主队列」。
/// 可变状态（`phase` / `inFlight`）只在主线程写，跨线程只传不可变的 `Phase` 值
/// （元素全是值类型）。加它是为了让编译器闭嘴，而不是因为这里真的有多线程共享状态。
final class UpdateStore: ObservableObject, @unchecked Sendable {

    enum Phase: Equatable {
        /// 还没查过（或用户忽略了那个版本）。
        case idle
        case checking
        case upToDate(SemanticVersion)
        case available(ReleaseInfo)
        case failed(UpdateFailure)
    }

    /// 当前运行的版本。开发态裸二进制取不到 Info.plist，此时为 nil。
    let currentVersion: SemanticVersion?
    let rawVersion: String?

    @Published private(set) var phase: Phase = .idle

    /// 每天自动检查一次（默认关，见 `UpdatePreferences`）。
    @Published var autoCheckEnabled: Bool {
        didSet {
            guard autoCheckEnabled != oldValue else { return }
            prefs.autoCheckEnabled = autoCheckEnabled
        }
    }

    private let prefs: UpdatePreferences
    private let checker: UpdateChecker
    private var inFlight = false

    init(
        preferences: UpdatePreferences = UpdatePreferences(),
        checker: UpdateChecker = UpdateChecker(),
        versionString: String? = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    ) {
        self.prefs = preferences
        self.checker = checker
        self.rawVersion = versionString
        self.currentVersion = versionString.flatMap(SemanticVersion.init(parsing:))
        self.autoCheckEnabled = preferences.autoCheckEnabled
    }

    // MARK: - 对外状态

    var availableRelease: ReleaseInfo? {
        if case .available(let info) = phase { return info }
        return nil
    }

    /// 面板横幅用：有新版本且用户没在检查中。
    var hasUpdate: Bool { availableRelease != nil }

    /// 开发态（拿不到版本号）不能检查：没有「当前版本」就没有「有没有更新」。
    var canCheck: Bool { currentVersion != nil }

    var isChecking: Bool {
        if case .checking = phase { return true }
        return false
    }

    /// 状态行文案（设置页副标题）。
    var statusText: String {
        switch phase {
        case .idle:
            guard let currentVersion else {
                return "当前是开发版（无版本号），无法比较版本。打包后的 App 才能检查更新。"
            }
            return "当前 \(currentVersion)。点右侧按钮向 GitHub 查一次最新版本。"
        case .checking:
            return "正在检查…"
        case .upToDate(let version):
            return "已是最新（\(version)）。"
        case .available:
            // 版本号已经在上方卡片里写了一遍，这里不再重复，只说「还能做什么」。
            // 不写「打开下载页」：有 dmg 直链时是直接下载，没有时才打开发布页。
            return "有新版本可用（当前 \(currentVersion.map { "\($0)" } ?? "未知")）。点上面的「下载」获取新版本。"
        case .failed(let failure):
            return failure.message
        }
    }

    // MARK: - 触发

    func checkManually() {
        start(trigger: .manual)
    }

    /// 启动时调用。只在开启自动检查、距上次成功检查超过 24h、
    /// 且失败退避已过期时才联网（见 `UpdatePreferences.shouldAutoCheck`）。
    func autoCheckIfDue(now: Date = Date()) {
        guard prefs.shouldAutoCheck(now: now) else { return }
        start(trigger: .auto)
    }

    /// 手动重试不该被自动检查的退避拦住，所以两条路径要分开记失败时间。
    private enum Trigger { case manual, auto }

    private func start(trigger: Trigger) {
        guard let currentVersion else {
            phase = .failed(.malformed("当前是开发版，没有可比较的版本号"))
            return
        }
        guard !inFlight else { return }
        inFlight = true
        phase = .checking

        let skipping = prefs.skippedVersion
        // `[weak self]` 写在外层：内层再单独持有 weak self 会与「外层隐式强引用」
        // 不一致（编译器会告 ImplicitStrongCapture）。这个 store 生命周期与 App 相同，
        // 但检查更新是唯一一个跨网络返回的路径，拿到结果时 App 可能已在退出。
        Task { [weak self, checker, prefs] in
            var nextPhase: Phase
            do {
                let outcome = try await checker.check(current: currentVersion, skipping: skipping)
                switch outcome {
                case .upToDate(let version):
                    nextPhase = .upToDate(version)
                case .available(let info):
                    nextPhase = .available(info)
                }
                // 只有成功才记「上次检查时间」。失败也记的话，一次断网会把
                // 24h 的节流额度白白吃掉，用户当天再也等不到自动重试。
                prefs.lastCheckedAt = Date()
            } catch let failure as UpdateFailure {
                nextPhase = .failed(failure)
            } catch {
                nextPhase = .failed(.network(error.localizedDescription))
            }

            // 自动检查失败做 30 分钟退避，避免故障窗口里每次启动都重试、每次都失败。
            // 成功就清掉，回到 24h 节流。手动点按钮完全不碰这个时间戳。
            switch trigger {
            case .auto:
                if case .failed = nextPhase {
                    prefs.lastAutoCheckFailedAt = Date()
                } else {
                    prefs.lastAutoCheckFailedAt = nil
                }
            case .manual:
                break
            }

            DispatchQueue.main.async { [weak self] in
                self?.inFlight = false
                self?.phase = nextPhase
            }
        }
    }

    // MARK: - 动作

    /// 打开下载页。
    ///
    /// **刻意只跳转，不自动下载安装**：产物是 adhoc 签名、未公证，自替换会绕过
    /// Gatekeeper 那一次「仍要打开」的人工放行，也会让 helper 的签名校验失效。
    /// 换版本必须由用户走一遍「挂载 DMG → 拖进应用程序」的路径，
    /// 这也是发布手册里唯一验证过的升级方式。
    ///
    /// 打开 `targetURL`：REST 增强源给了 `.dmg` 直链就直接下载，只有 Atom
    /// 结论源时退回发布页（它有安装说明、校验和与全部附件）。
    /// **不按约定拼 dmg 文件名**——命名一变就是 404。
    func openDownloadPage() {
        guard let url = availableRelease?.targetURL else { return }
        NSWorkspace.shared.open(url)
    }

    /// 「忽略此版本」：横幅立刻消失，直到出现**更新**的版本。
    func skipCurrentUpdate() {
        guard let info = availableRelease else { return }
        prefs.skippedVersion = info.version.description
        phase = .idle
    }

    // MARK: - 走查

    /// 只给离屏走查用（`--render settings --update available`）。
    ///
    /// 不做 `#if DEBUG` 限制：`RenderCheck.swift` 本身在 release 包里也参与编译，
    /// 加了条件编译两边就得各写一套。生产路径没有任何调用点。
    func preview(_ phase: Phase) {
        self.phase = phase
    }
}
