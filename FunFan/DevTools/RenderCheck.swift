import SwiftUI
import AppKit
import FunFanCore

/// 开发期渲染校验：把 SwiftUI 视图离屏渲染成 PNG。
///
/// 为什么需要它：本机 `screencapture` 受屏幕录制权限限制不可用，
/// 而 `ImageRenderer` 不依赖屏幕，能真实反映布局（尺寸、截断、间距）。
///
/// 用法：
///   FunFan --render rules    /tmp/rules.png
///   FunFan --render editor   /tmp/editor.png
///   FunFan --render popover  /tmp/popover.png
@MainActor
enum RenderCheck {

    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--render"), args.count > index + 2 else { return false }

        let target = args[index + 1]
        let output = args[index + 2]

        // popover 的内容依赖实时采样（风扇、温度）。这里有两条硬约束：
        //   1. 采样结果经 `DispatchQueue.main.async` 回填，而本函数本身就运行在
        //      主队列的 block 里——主队列串行，不返回就永远轮不到回填；
        //   2. 所以不能「就地等 runloop」，必须先把控制权交还事件循环再渲染。
        guard target == "popover" || target == "popover-cores" else {
            render(target: target, output: output, liveMonitor: nil)
            return true
        }
        let monitor = MonitorStore()
        monitor.setVisibility(.popoverOpen)
        monitor.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            render(target: target, output: output, liveMonitor: monitor)
        }
        return true
    }

    private static func scaleValue() -> Int {
        if let index = CommandLine.arguments.firstIndex(of: "--scale"),
           CommandLine.arguments.count > index + 1,
           let value = Int(CommandLine.arguments[index + 1]) {
            return max(1, min(value, 4))
        }
        return 2
    }

    @MainActor
    private static func render(target: String, output: String, liveMonitor: MonitorStore?) {
        let temporary = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("funfan-render-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("rules.json")

        let rules = RulesStore(persistence: RulePersistence(fileURL: temporary))
        let control = ControlStore()
        let monitor = liveMonitor ?? MonitorStore()

        let content: AnyView
        switch target {
        case "rules":
            content = AnyView(RulesView(rules: rules, control: control).frame(width: 560, height: 460))
        case "editor":
            content = AnyView(
                RuleEditorView(
                    rule: RulesStore(persistence: RulePersistence(fileURL: temporary)).rules[0],
                    limits: FanLimits(minRpm: 1000, maxRpm: 4900),
                    onSave: { _ in },
                    onCancel: {}
                )
            )
        case "curve":
            let curveFile = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("funfan-render-\(UUID().uuidString)", isDirectory: true)
                .appendingPathComponent("curve.json")
            let store = CurveStore(
                persistence: CurvePersistence(fileURL: curveFile),
                limits: FanLimits(minRpm: 1000, maxRpm: 4900)
            )
            content = AnyView(CurveEditorView(store: store, control: control, monitor: monitor))
        case "scrolltest":
            content = AnyView(VStack(spacing: 12) {
                Text("A: plain text visible")
                ScrollView { Text("B: inside scrollview") }
                    .frame(height: 40)
                Button("C: native button") {}
                Button("D: plain style") {}.buttonStyle(.plain)
            }.padding().frame(width: 420, height: 220))
        case "settings":
            content = AnyView(
                SettingsView(
                    settings: SettingsStore(),
                    control: control,
                    diagnostics: DiagnosticsStore(),
                    installer: HelperInstaller()
                )
                .frame(width: 540, height: 700)
            )
        case "popover":
            content = AnyView(
                MenuBarView(
                    monitor: monitor, control: control, diagnostics: DiagnosticsStore(),
                    installer: HelperInstaller(),
                    onOpenRules: {}, onOpenCurve: {}, onOpenSettings: {}, onQuit: {}
                )
                    .background(Color(nsColor: .windowBackgroundColor))
            )
        case "popover-cores":
            // 展开态：验证「点了展开之后」的内容真的在可视区内（曾经的 bug 是
            // 展开后高度不涨，内容画到了 popover 外面）
            content = AnyView(
                MenuBarView(
                    monitor: monitor, control: control, diagnostics: DiagnosticsStore(),
                    installer: HelperInstaller(),
                    initialShowCores: true,
                    onOpenRules: {}, onOpenCurve: {}, onOpenSettings: {}, onQuit: {}
                )
                    .background(Color(nsColor: .windowBackgroundColor))
            )
        default:
            FileHandle.standardError.write(Data("unknown target: \(target)\n".utf8))
            exit(2)
        }

        let base = AnyView(content.environment(\.colorScheme, .dark))
        // 强制把焦点环画出来（ImageRenderer 不参与响应者链，本来拿不到焦点）
        let themed = CommandLine.arguments.contains("--force-focus")
            ? AnyView(base.environment(\.forceFocusRing, true))
            : base
        let renderer = ImageRenderer(content: themed)
        renderer.scale = Double(scaleValue())

        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else {
            FileHandle.standardError.write(Data("render failed\n".utf8))
            exit(1)
        }

        do {
            try png.write(to: URL(fileURLWithPath: output))
            print("rendered \(target) → \(output) (\(Int(image.size.width))×\(Int(image.size.height)) pt)")
        } catch {
            FileHandle.standardError.write(Data("write failed: \(error)\n".utf8))
            exit(1)
        }
        exit(0)
    }
}
