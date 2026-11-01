import AppKit

// FunFan —— 菜单栏风扇监控与控制
//
// 以 SwiftPM 可执行文件方式运行（开发期）：
//   swift run --disable-sandbox FunFan
// 正式分发需打成 .app（含 Info.plist 的 LSUIElement）并签名公证。

// 偏好持久化取证（必须放在 `NSApplication.shared` 之前：连上窗口服务器后
// 进程在无人值守环境下会被直接干掉，取证就跑不成了）
if PrefsProbe.runIfRequested() {
    exit(0)
}

let app = NSApplication.shared

// 特权组件的命令行验收（不启动 UI，打印状态后直接退出）
if let code = HelperCLI.runIfRequested() {
    exit(code)
}

// 开发期视图渲染校验（不启动 UI，渲染后立即退出）
if CommandLine.arguments.contains("--render") {
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            _ = RenderCheck.runIfRequested()
        }
    }
    app.run()
}

let delegate = AppDelegate()
app.delegate = delegate
app.run()
