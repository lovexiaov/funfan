import AppKit

// FunFan —— 菜单栏风扇监控与控制
//
// 以 SwiftPM 可执行文件方式运行（开发期）：
//   swift run --disable-sandbox FunFan
// 正式分发需打成 .app（含 Info.plist 的 LSUIElement）并签名公证。

let app = NSApplication.shared

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
