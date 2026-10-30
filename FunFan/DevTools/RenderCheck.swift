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
        render(target: target, output: output)
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
    private static func render(target: String, output: String) {
        let temporary = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("funfan-render-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("rules.json")

        let rules = RulesStore(persistence: RulePersistence(fileURL: temporary))
        let control = ControlStore()
        let monitor = MonitorStore()

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
        case "scrolltest":
            content = AnyView(VStack(spacing: 12) {
                Text("A: plain text visible")
                ScrollView { Text("B: inside scrollview") }
                    .frame(height: 40)
                Button("C: native button") {}
                Button("D: plain style") {}.buttonStyle(.plain)
            }.padding().frame(width: 420, height: 220))
        case "popover":
            content = AnyView(
                MenuBarView(
                    monitor: monitor, control: control, diagnostics: DiagnosticsStore(),
                    onOpenRules: {}, onQuit: {}
                )
                    .background(Color(nsColor: .windowBackgroundColor))
            )
        default:
            FileHandle.standardError.write(Data("unknown target: \(target)\n".utf8))
            exit(2)
        }

        let renderer = ImageRenderer(content: content.environment(\.colorScheme, .dark))
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
