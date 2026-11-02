import AppKit
import Combine
import Foundation
import FunFanCore

/// 诊断采集（GUI 侧）。
///
/// 两个入口：
/// 1. **能力出错时自动落盘**——用户报 bug 时直接去诊断目录取文件，不用再让他跑命令；
/// 2. **手动「诊断」按钮**——复制整份报告到剪贴板，粘到 issue 里即可。
///
/// 自动采集按「原因」去重，一次启动内同一原因只采一次，避免异常反复触发写盘。
final class DiagnosticsStore: ObservableObject {

    /// 给 UI 的一行反馈（复制成功 / 已保存到哪）。
    @Published private(set) var lastMessage: String?

    /// 重启后自启失败报告的文件路径（生成后置位，供「查看报告」选中）。
    @Published private(set) var bootRepairReportURL: URL?

    /// 是否该弹「已生成取证报告」的提示（AppDelegate 订阅它弹窗，一次启动只弹一次）。
    @Published private(set) var bootRepairPrompt: Bool = false

    private var capturedThisSession: Set<String> = []

    /// 重启取证报告在本启动周期内是否已生成（去重，避免反复写盘/弹窗）。
    private var bootRepairCaptured = false

    /// 能力出错时调用（helper 不可用、SMC 读取失败…）。
    func captureOnFailure(_ reason: String, context: [String: String] = [:]) {
        guard !capturedThisSession.contains(reason) else { return }
        capturedThisSession.insert(reason)

        DispatchQueue.global(qos: .utility).async {
            let url = SystemInfoCollector.write(reason: reason, context: context)
            DispatchQueue.main.async {
                self.lastMessage = url.map { "已保存诊断报告：\($0.lastPathComponent)" }
                    ?? "诊断报告保存失败"
            }
        }
    }

    /// 设置窗口用：跑一次诊断只给结论（不复制、不落盘）。
    ///
    /// 与「诊断」按钮的区别：那个是为了报 bug（复制全文），这个是为了自检——
    /// 用户只想知道「有没有问题」，不想读 40 行 Markdown。
    func runSummary(completion: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let report = SystemInfoCollector.collect(reason: "设置窗口自检")
            let failed = report.capabilities.filter { $0.status == .failed }.count
            let degraded = report.capabilities.filter { $0.status == .degraded }.count

            var text: String
            if failed > 0 {
                text = "\(failed) 项失败\(degraded > 0 ? "、\(degraded) 项降级" : "")"
            } else if degraded > 0 {
                text = "无失败，\(degraded) 项降级"
            } else {
                text = "全部正常"
            }
            if let keys = report.system.temperatureKeyCount {
                text += " · 温度键 \(keys) 个"
            }
            DispatchQueue.main.async { completion(text) }
        }
    }

    /// 手动触发：复制 Markdown 到剪贴板，同时落盘一份（用户事后还能找到）。
    func copyReport(reason: String = "用户手动复制诊断信息") {
        DispatchQueue.global(qos: .userInitiated).async {
            let report = SystemInfoCollector.collect(reason: reason)
            let url = SystemInfoCollector.save(report, to: SystemInfoCollector.defaultDirectory())
            DispatchQueue.main.async {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(report.markdown, forType: .string)
                self.lastMessage = url == nil ? "已复制诊断信息" : "已复制诊断信息，并保存到诊断目录"
            }
        }
    }

    // MARK: - 重启后自启失败取证（issue #1）

    /// 重启后后台组件没随系统启动：自动落一份取证报告，并置位提示。
    ///
    /// 一次启动只生成一次（去重）。报告里带上启动时间、距现在多少分钟，
    /// 方便我们判断「是不是刚重启完」以及「重启后多久才被发现」。
    func generateBootRepairReport(bootTime: Date?) {
        guard !bootRepairCaptured else { return }
        bootRepairCaptured = true
        let capturedBoot = bootTime
        DispatchQueue.global(qos: .utility).async {
            var context: [String: String] = ["issue": "#1"]
            if let boot = capturedBoot {
                let iso = ISO8601DateFormatter()
                context["bootTime"] = iso.string(from: boot)
                context["minutesSinceBoot"] = String(format: "%.0f", Date().timeIntervalSince(boot) / 60)
            }
            let url = SystemInfoCollector.write(
                reason: "重启后后台组件未自启（issue #1 取证）",
                context: context
            )
            DispatchQueue.main.async {
                self.bootRepairReportURL = url
                self.bootRepairPrompt = true
            }
        }
    }

    /// 关掉「已生成取证报告」提示。
    func dismissBootRepairPrompt() {
        bootRepairPrompt = false
    }

    /// 用户主动要报告：已有就直接在 Finder 选中，没有就现生成再选中。
    ///
    /// 报告很小（毫秒级生成），首次生成后用半秒兜底再选中，避免选中一个还没写好的路径。
    func shareBootRepairReport(bootTime: Date?) {
        if let url = bootRepairReportURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
        generateBootRepairReport(bootTime: bootTime)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let url = self?.bootRepairReportURL else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}
