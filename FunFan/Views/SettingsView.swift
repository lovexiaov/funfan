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

    @Environment(\.palette) private var palette
    @Environment(\.colorScheme) private var colorScheme

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
            Divider().overlay(palette.divider)
            // 不用 ScrollView：内容高度固定且可控，
            // 而 ScrollView 在 ImageRenderer 离屏渲染下不填充内容，设计走查会看到一片空白。
            VStack(alignment: .leading, spacing: 14) {
                appearanceSection
                generalSection
                helperSection
                diagnosisSection
                aboutSection
            }
            .padding(16)
            Spacer(minLength: 0)
        }
        .frame(minWidth: 520, minHeight: 780)
        .background(palette.panelFill)
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("设置")
                .font(Theme.Typo.title)
                .foregroundStyle(palette.textPrimary)
            Spacer()
            Text(settings.appVersion)
                .font(Theme.Typo.meta)
                .foregroundStyle(palette.textTertiary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    // MARK: - 外观

    /// 外观三态。
    ///
    /// 放在第一组是因为它影响整屏观感：用户一旦觉得「太白晃眼 / 太黑看不清」，
    /// 第一件事就是找它，不该埋在「通用」下面。切换立即生效——写进
    /// `SettingsStore.appearance`，由 `AppDelegate` 贴到每个窗口的 `appearance`。
    private var appearanceSection: some View {
        section("外观") {
            SettingRow(
                title: "主题",
                subtitle: appearanceSubtitle,
                isLast: true
            ) {
                SegmentedPicker(
                    options: SettingsStore.Appearance.allCases,
                    title: \.label,
                    selection: $settings.appearance
                )
                .frame(width: 208)
            }
        }
    }

    private var appearanceSubtitle: String {
        switch settings.appearance {
        case .system:
            return "跟随 macOS 的浅色 / 深色设置自动切换，当前为\(colorScheme == .dark ? "深色" : "浅色")"
        case .light:
            return "固定浅色，不再跟随系统"
        case .dark:
            return "固定深色，不再跟随系统"
        }
    }

    // MARK: - 通用

    private var generalSection: some View {
        section("通用") {
            SettingRow(
                title: "登录时启动",
                subtitle: loginItemSubtitle,
                isLast: false
            ) {
                FunFanToggle(isOn: loginItemBinding, size: 24, isEnabled: isLoginItemAvailable)
            }

            if let error = settings.loginItemError {
                Text(error)
                    .font(Theme.Typo.meta)
                    .foregroundStyle(palette.error)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }

            SettingRow(
                title: "菜单栏显示温度",
                subtitle: "在图标右侧显示当前最热的传感器温度；关闭后只保留图标",
                isLast: false
            ) {
                FunFanToggle(isOn: $settings.showsMenuBarTemperature, size: 24)
            }

            SettingRow(
                title: "退出 / 合盖时返还系统自动",
                subtitle: "始终开启：任何退出路径（正常退出、睡眠、合盖、helper 租约过期）都会把风扇交还系统，不会留在手动转速",
                isLast: true
            ) {
                Label("始终开启", systemImage: "lock.fill")
                    .font(Theme.Typo.meta)
                    .foregroundStyle(palette.textSecondary)
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
                subtitle: helperSubtitle,
                isLast: true
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
                    if installer.isInstalled || installer.status.needsUserApproval {
                        FunFanButton(
                            title: "卸载",
                            systemImage: "trash",
                            isEnabled: !installer.isBusy
                        ) {
                            installer.uninstall()
                        }
                    } else {
                        FunFanButton(
                            title: installer.isBusy ? "安装中…" : "一键安装",
                            systemImage: "lock.shield",
                            isEnabled: !installer.isBusy && HelperInstaller.canInstallAnyhow
                        ) {
                            installer.install()
                        }
                    }
                }
            }

            if let note = installer.note {
                helperNote(note, tone: installer.status.needsUserApproval ? .attention : .neutral)
            } else if let guidance = installer.status.guidance, !installer.isInstalled {
                helperNote(guidance, tone: .neutral)
            }

            if let error = installer.error {
                helperNote(error, tone: .error)
            }
        }
    }

    private var helperSubtitle: String {
        if installer.status.isInstalled {
            return "已由系统登记并在运行，升级 App 无需重新授权"
        }
        if installer.directInstallPresent {
            return "已安装（直装到 /Library/PrivilegedHelperTools，由 launchd 托管）"
        }
        if installer.status.needsUserApproval {
            return "已在系统登记，需要你去系统设置批准后才会启动"
        }
        if HelperInstaller.canInstallAnyhow {
            return HelperInstaller.isSupported
                ? "安装后即可控制风扇；系统只弹一次授权，之后随 App 升级"
                : "当前是开发构建（未签名），会弹一次管理员密码直装到 /Library"
        }
        return HelperInstaller.unsupportedReason
    }

    private enum NoteTone {
        case neutral, attention, error
    }

    private func helperNote(_ text: String, tone: NoteTone) -> some View {
        Text(text)
            .font(Theme.Typo.meta)
            .foregroundStyle(toneColor(tone))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
    }

    private func toneColor(_ tone: NoteTone) -> Color {
        switch tone {
        case .neutral: return palette.textSecondary
        case .attention: return palette.attention
        case .error: return palette.error
        }
    }

    // MARK: - 诊断

    private var diagnosisSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            section("诊断") {
                SettingRow(
                    title: "硬件自检",
                    subtitle: diagnosisSubtitle,
                    isLast: false
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
                    subtitle: "复制机型、系统、SMC 能力逐项实测与日志尾部到剪贴板，可直接贴进 issue",
                    isLast: true
                ) {
                    FunFanButton(title: "复制", systemImage: "doc.on.clipboard") {
                        diagnostics.copyReport()
                    }
                }
            }

            // 放在卡片**外面**：这是阻断性提示（现在根本控制不了风扇），
            // 塞在卡片尾部会被当成又一条设置项划过去。
            if !control.helperStatus.isReady {
                // 装好了但连不上，和根本没装，是两件完全不同的事。
                // 混成一句「未安装」会让刚装完的用户以为安装失败了。
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.attention)
                    Text(installer.isInstalled
                         ? "后台组件已安装，但当前没连上（刚装好通常几秒内会自动重连）。点「运行」硬件自检可看到具体原因。"
                         : "当前未连接特权后台组件，只能监控、无法控制风扇。先在上面点「一键安装」。")
                        .font(Theme.Typo.meta)
                        .foregroundStyle(palette.attention)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 2)
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
                    .foregroundStyle(palette.attention)

                VStack(alignment: .leading, spacing: 5) {
                    Text("免责声明")
                        .font(Theme.Typo.bodyStrong)
                        .foregroundStyle(palette.textPrimary)

                    Text("本工具通过 AppleSMC 直接写入风扇目标转速。所有写入都会先收敛到系统区间与动态安全下限，且绝不发送 0 RPM；但底层接口未公开，系统升级后可能失效或行为改变。请自行承担使用风险，出现异常请立即切回「自动」。")
                        .font(Theme.Typo.meta)
                        .foregroundStyle(palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("FunFan 不收集任何数据；诊断报告只在你点击「复制」时生成，并保存到本机 ~/Library/Application Support/FunFan/diagnostics。")
                        .font(Theme.Typo.meta)
                        .foregroundStyle(palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(palette.attentionWash)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(palette.attention.opacity(0.22), lineWidth: 0.5)
            )
        }
    }

    // MARK: - 布局辅助

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // 分组标题原来是「全页最淡」（tertiary）+ `.textCase(.uppercase)`，
            // 而 uppercase 对中文完全无效——等于最该醒目的一层没有任何修饰。
            // 现在用 11pt semibold + textSecondary，靠字重建立层级。
            Text(title)
                .font(Theme.Typo.metaStrong)
                .foregroundStyle(palette.textSecondary)

            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(palette.cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(palette.cardStroke, lineWidth: 0.5)
            )
        }
    }
}

// MARK: - 单行设置项

/// 左标题 + 说明，右侧控件；行间用细分割线（对应设计稿的 `SettingRow`）。
///
/// `isLast`：最后一行不画分割线——原来每条都画，最后一条下面总会多出一道悬空
/// 的线，看起来像「下面还有内容被截了」。
struct SettingRow<Trailing: View>: View {

    let title: String
    var subtitle: String?
    var isLast: Bool = false
    @ViewBuilder var trailing: () -> Trailing

    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Theme.Typo.body)
                        .foregroundStyle(palette.textPrimary)
                    if let subtitle {
                        Text(subtitle)
                            .font(Theme.Typo.meta)
                            .foregroundStyle(palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                trailing()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            if !isLast {
                Divider()
                    .overlay(palette.divider)
                    .padding(.leading, 12)
            }
        }
    }
}
