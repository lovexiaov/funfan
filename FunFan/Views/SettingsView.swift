import SwiftUI
import FunFanCore

/// 设置窗口。
///
/// 原则：**只放真的会生效的开关**。
/// 设计稿里还提到「传感器勾选」，但当前 Popover 的温度宫格是固定四项
/// （CPU/GPU/SSD/环境），没有可勾选的动态列表——与其摆一个点了没反应的开关，
/// 不如不放，等真的做了可配置仪表盘再加。
struct SettingsView: View {

    @ObservedObject var settings: SettingsStore
    @ObservedObject var control: ControlStore
    @ObservedObject var diagnostics: DiagnosticsStore
    @ObservedObject var installer: HelperInstaller

    @State private var diagnosisSummary: String?
    @State private var isDiagnosing = false

    private var loginItemBinding: Binding<Bool> {
        Binding(
            get: { settings.loginItem.isOn },
            set: { settings.setLoginItem(enabled: $0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.4)
            // 不用 ScrollView：内容高度固定且可控（约 560 pt），
            // 而 ScrollView 在 ImageRenderer 离屏渲染下不填充内容，设计走查会看到一片空白。
            VStack(alignment: .leading, spacing: 14) {
                generalSection
                helperSection
                diagnosisSection
                aboutSection
            }
            .padding(16)
            Spacer(minLength: 0)
        }
        .frame(minWidth: 520, minHeight: 690)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("设置")
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            Text(settings.appVersion)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    // MARK: - 通用

    private var generalSection: some View {
        section("通用") {
            SettingRow(
                title: "登录时启动",
                subtitle: loginItemSubtitle
            ) {
                FunFanToggle(isOn: loginItemBinding, size: 24)
                    .opacity(isLoginItemAvailable ? 1 : 0.45)
            }

            if let error = settings.loginItemError {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.hot)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }

            SettingRow(
                title: "菜单栏显示温度",
                subtitle: "在图标右侧显示当前最热的传感器温度；关闭后只保留图标"
            ) {
                FunFanToggle(isOn: $settings.showsMenuBarTemperature, size: 24)
            }

            SettingRow(
                title: "退出 / 合盖时返还系统自动",
                subtitle: "始终开启：任何退出路径（正常退出、睡眠、合盖、helper 租约过期）都会把风扇交还系统，不会留在手动转速"
            ) {
                Label("始终开启", systemImage: "lock.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var isLoginItemAvailable: Bool {
        if case .unavailable = settings.loginItem { return false }
        return true
    }

    private var loginItemSubtitle: String {
        switch settings.loginItem {
        case .enabled:
            return "已注册为登录项，开机后自动在菜单栏运行"
        case .disabled:
            return "登录后自动启动 FunFan"
        case .unavailable(let reason):
            return reason
        }
    }

    // MARK: - 特权组件

    private var helperSection: some View {
        section("风扇控制组件") {
            SettingRow(
                title: "特权后台组件",
                subtitle: helperSubtitle
            ) {
                HStack(spacing: 7) {
                    if installer.status.needsUserApproval {
                        FunFanButton(
                            title: "去批准",
                            systemImage: "arrow.up.forward.app",
                            isEnabled: !installer.isBusy
                        ) {
                            installer.openApprovalSettings()
                        }
                    }
                    if installer.status.isInstalled || installer.status.needsUserApproval {
                        FunFanButton(
                            title: "卸载",
                            systemImage: "trash",
                            isEnabled: !installer.isBusy
                        ) {
                            installer.uninstall()
                        }
                    } else {
                        FunFanButton(
                            title: installer.isBusy ? "安装中…" : "安装",
                            systemImage: "lock.shield",
                            isEnabled: !installer.isBusy && HelperInstaller.isSupported
                        ) {
                            installer.install()
                        }
                    }
                }
            }

            if let guidance = installer.status.guidance {
                helperNote(guidance, color: installer.status.needsUserApproval ? Theme.warm : .secondary)
            }

            if let error = installer.error {
                helperNote(error, color: Theme.hot)
            }
        }
    }

    private var helperSubtitle: String {
        if !HelperInstaller.isSupported { return HelperInstaller.unsupportedReason }
        switch installer.status {
        case .enabled:
            return "已由系统登记并在运行，升级 App 无需重新授权"
        case .requiresApproval:
            return "已登记，但需要你在系统设置里批准后才会启动"
        case .notRegistered:
            return "安装后即可控制风扇；系统只弹一次授权，之后随 App 升级"
        case .notFound:
            return "系统找不到后台组件（见下方说明）"
        case .unknown:
            return "系统返回了未识别的状态（见下方说明）"
        }
    }

    private func helperNote(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
    }

    // MARK: - 诊断

    private var diagnosisSection: some View {
        section("诊断") {
            SettingRow(
                title: "硬件自检",
                subtitle: diagnosisSubtitle
            ) {
                FunFanButton(
                    title: isDiagnosing ? "检测中…" : "运行",
                    systemImage: "stethoscope",
                    isEnabled: !isDiagnosing
                ) {
                    runDiagnosis()
                }
            }

            SettingRow(
                title: "完整诊断报告",
                subtitle: "复制机型、系统、SMC 能力逐项实测与日志尾部到剪贴板，可直接贴进 issue"
            ) {
                FunFanButton(title: "复制", systemImage: "doc.on.clipboard") {
                    diagnostics.copyReport()
                }
            }

            if !control.helperStatus.isReady {
                Text("当前未连接特权 helper，只能监控、无法控制风扇。先在上面安装「特权后台组件」；开发期也可用 sudo bash scripts/install-helper.sh 直装。")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.warm)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 2)
                    .textSelection(.enabled)
            }
        }
    }

    private var diagnosisSubtitle: String {
        if let diagnosisSummary { return diagnosisSummary }
        return "逐项检查 SMC 访问、温度键可读率、风扇写入与 helper 状态"
    }

    private func runDiagnosis() {
        isDiagnosing = true
        diagnosisSummary = nil
        diagnostics.runSummary { summary in
            diagnosisSummary = summary
            isDiagnosing = false
        }
    }

    // MARK: - 关于

    private var aboutSection: some View {
        section("关于") {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.warm)

                VStack(alignment: .leading, spacing: 5) {
                    Text("免责声明")
                        .font(.system(size: 11, weight: .semibold))

                    Text("本工具通过 AppleSMC 直接写入风扇目标转速。所有写入都会先收敛到系统区间与动态安全下限，且绝不发送 0 RPM；但底层接口未公开，系统升级后可能失效或行为改变。请自行承担使用风险，出现异常请立即切回「自动」。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("FunFan 不收集任何数据；诊断报告只在你点击「复制」时生成，并保存到本机 ~/Library/Application Support/FunFan/diagnostics。")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.warm.opacity(0.08))
            )
        }
    }

    // MARK: - 布局辅助

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)

            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
        }
    }
}

// MARK: - 单行设置项

/// 左标题 + 说明，右侧控件；行间用细分割线（对应设计稿的 `SettingRow`）。
struct SettingRow<Trailing: View>: View {

    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12))
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                trailing()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider().opacity(0.25).padding(.leading, 12)
        }
    }
}
