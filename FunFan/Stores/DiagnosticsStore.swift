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

    private var capturedThisSession: Set<String> = []

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
}
