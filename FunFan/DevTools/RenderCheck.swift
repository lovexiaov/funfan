import SwiftUI
import AppKit
import FunFanCore

/// 仅供 `FunFan --render` 使用：把展开区的 `ScrollView` 摊平。
///
/// `ImageRenderer` 不会渲染 `ScrollView` 的内容（它没有 intrinsic size，
/// 离屏渲染出来是一整片空白）。这不是产品 bug，但会让「展开后内容是否放得下、
/// 方块会不会换行、探测点会不会截断」这类问题在走查里完全看不见。
/// 打开这个开关就用普通 `VStack` 代替 `ScrollView`，能拍到完整内容。
private struct FlattenScrollKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var renderFlattensScroll: Bool {
        get { self[FlattenScrollKey.self] }
        set { self[FlattenScrollKey.self] = newValue }
    }
}

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

    /// `--scheme light|dark`：显式指定外观。
    ///
    /// **为什么必须要有这个开关**：原来这里写死 `.dark`，项目所有走查截图都是深色，
    /// 而浅色模式下的语义色实测只有 1.28–2.52:1（正文需 4.5）—— 问题存在了很久
    /// 却一直「看不见」。有了它，浅色才成为可验收的交付物，而不是靠用户偶然发现。
    private static func schemeValue() -> ColorScheme {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--scheme"), args.count > index + 1 else { return .dark }
        return args[index + 1] == "light" ? .light : .dark
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
                    installer: HelperInstaller(),
                    monitor: monitor
                )
                .frame(width: 540, height: 960)
            )
        case "popover":
            content = AnyView(
                MenuBarView(
                    monitor: monitor, control: control, diagnostics: DiagnosticsStore(),
                    installer: HelperInstaller(),
                    ui: PopoverUIState(),
                    onOpenRules: {}, onOpenCurve: {}, onOpenSettings: {}, onQuit: {}
                )
                    .background(Palette.resolve(schemeValue()).panelFill)
            )
        case "popover-cores":
            // 展开态：验证「点了展开之后」的内容真的在可视区内（曾经的 bug 是
            // 展开后高度不涨，内容画到了 popover 外面）
            content = AnyView(
                MenuBarView(
                    monitor: monitor, control: control, diagnostics: DiagnosticsStore(),
                    installer: HelperInstaller(),
                    ui: PopoverUIState(showCores: true),
                    onOpenRules: {}, onOpenCurve: {}, onOpenSettings: {}, onQuit: {}
                )
                    .background(Palette.resolve(schemeValue()).panelFill)
            )
        default:
            FileHandle.standardError.write(Data("unknown target: \(target)\n".utf8))
            exit(2)
        }

        // `--dump-cores`：把本机真实分组与每个探测点读数打到 stdout。
        // 用途：核对「展开各核心温度」里的探测点数、键名、簇均温是否与实现一致。
        // 设计稿改动（docs/ui-prototype/funfan-design-v2.html）必须以这份真值为准，
        // 肉眼看截图数不清 75 个点。
        if CommandLine.arguments.contains("--dump-cores") {
            if let topo = monitor.chipTopology {
                print("TOPO \(topo.chipName) P=\(topo.performanceCores) E=\(topo.efficiencyCores) G=\(topo.gpuCores)")
            }
            print("SENSORS \(monitor.sensorCount)")
            print("AVG cpu=\(String(format: "%.1f", monitor.cpuAverage ?? -1)) gpu=\(String(format: "%.1f", monitor.gpuAverage ?? -1)) ssd=\(String(format: "%.1f", monitor.ssdAverage ?? -1)) ambient=\(String(format: "%.1f", monitor.ambientAverage ?? -1))")
            for group in monitor.coreGroups {
                print("GROUP [\(group.title)] n=\(group.sensorCount) avg=\(String(format: "%.1f", group.average))")
                print("  " + group.sensors.map { "\($0.key)=\(String(format: "%.1f", $0.celsius))" }.joined(separator: " "))
            }
        }

        // 顺序要紧：`funfanTheme()` 在内侧读 `colorScheme`，`environment` 必须在外侧，
        // 否则它读到的是系统外观而不是 `--scheme` 指定的那一套。
        let base = AnyView(content.funfanTheme().environment(\.colorScheme, schemeValue()))
        // settings 页整页是 `ScrollView`，不摊平就拍成一片空白——这页的走查价值
        // 恰恰在「所有分组是否放得下」，所以这个 target 默认摊平。
        let flat = (CommandLine.arguments.contains("--flat") || target == "settings")
            ? AnyView(base.environment(\.renderFlattensScroll, true))
            : base
        // 强制把焦点环画出来（ImageRenderer 不参与响应者链，本来拿不到焦点）
        let themed = CommandLine.arguments.contains("--force-focus")
            ? AnyView(flat.environment(\.forceFocusRing, true))
            : flat
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
