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
    /// 只用来显示「现在按几度在算」，不参与控制逻辑。
    @ObservedObject var monitor: MonitorStore
    @ObservedObject var update: UpdateStore

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
            // 标题之外的内容整块可滚动：设置项只会越加越多，固定高度 + 不可滚
            // 会把最下面的「免责声明」直接裁掉——那是最不该看不见的一段。
            //
            // 走查渲染（`FunFan --render settings --flat`）时摊平成普通 VStack：
            // `ImageRenderer` 不渲染 `ScrollView` 的内容，否则整页拍到一片空白。
            if flattenScroll {
                sections
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    sections
                    // 内容比窗口矮时也要能吸顶，否则卡片会垂直居中飘着
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 560)
        .background(palette.panelFill)
    }

    @Environment(\.renderFlattensScroll) private var flattenScroll

    private var sections: some View {
        VStack(alignment: .leading, spacing: 14) {
            appearanceSection
            temperatureSection
            generalSection
            helperSection
            diagnosisSection
            updateSection
            aboutSection
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
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

    // MARK: - 风扇调速

    /// 调速依据温度（最高温 / 均温）。
    ///
    /// 放在「外观」之后、「通用」之前：它直接改变风扇转速，比登录项这类
    /// 「装完就不再看」的开关重要得多，不该沉在通用组里。
    /// 副标题里带上实时读数——不然用户只能凭感觉判断两种口径差多少。
    private var temperatureSection: some View {
        section("风扇调速") {
            SettingRow(
                title: "调速依据温度",
                subtitle: temperatureSubtitle,
                isLast: true
            ) {
                SegmentedPicker(
                    options: TemperatureAggregation.allCases,
                    title: \.settingLabel,
                    selection: $control.temperatureAggregation
                )
                .frame(width: 208)
                .help("曲线映射与安全下限都按这里的口径计算")
            }
        }
    }

    private var temperatureSubtitle: String {
        let hottest = monitor.hottestCelsius.map { String(format: "%.0f℃", $0) }
        let average = monitor.coreAverageCelsius.map { String(format: "%.0f℃", $0) }

        switch control.temperatureAggregation {
        case .peak:
            let now = hottest.map { "当前最热 \($0)" } ?? "正在采样…"
            return "取全部传感器中的最高温，任一探测点过热即提速。\(now)"
        case .average:
            let now = average.map { "当前均温 \($0)" } ?? "正在采样…"
            // 把「安全下限也按均温算」写在明面上：这是这个选项唯一的代价，
            // 藏起来的话，用户只会觉得「选了均温以后机器比以前热」。
            return "取 CPU / GPU 全部探测点的均温，SSD、电池、环境不参与；安全下限同样按均温计算。\(now)"
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
                title: "键盘焦点环",
                subtitle: "用 Tab 全键盘操作时，在当前焦点控件外画一圈提示；默认关闭，不影响键盘导航本身",
                isLast: false
            ) {
                FunFanToggle(isOn: $settings.focusRingVisible, size: 24)
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
        if installer.needsBootRepair {
            return "已安装，但 launchd 未加载——重启后不会自启。点「一键安装」再装载一次即可修复（会再弹一次密码）"
        }
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
                    isLast: !installer.needsBootRepair
                ) {
                    FunFanButton(title: "复制", systemImage: "doc.on.clipboard") {
                        diagnostics.copyReport()
                    }
                }

                if installer.needsBootRepair {
                    // 重启后没自启（issue #1）：除「一键安装」再装载一次，也给一个
                    // 把证据交回来的入口——在 Finder 里选中刚自动生成的取证报告。
                    SettingRow(
                        title: "重启未自启取证报告",
                        subtitle: "后台组件已装但 launchd 未加载；点此在 Finder 打开自动生成的诊断报告（issue #1）",
                        isLast: true
                    ) {
                        FunFanButton(title: "打开报告", systemImage: "doc.text.magnifyingglass") {
                            diagnostics.shareBootRepairReport(bootTime: SystemProbe().systemBootTime())
                        }
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

    // MARK: - 更新

    /// 更新检查。
    ///
    /// 放在「关于」之前而不是塞进关于里：它有一个真实会改变状态的按钮和一条会
    /// 变色的提示，不是纯展示信息。但也不往上挪——它和风扇行为无关，
    /// 不该插在「调速依据温度」和「特权组件」之间打断控制相关的分组。
    private var updateSection: some View {
        section("更新") {
            if let info = update.availableRelease {
                availableUpdateCard(info)
            }

            SettingRow(
                title: "检查更新",
                subtitle: update.statusText,
                isLast: false
            ) {
                FunFanButton(
                    title: update.isChecking ? "检查中…" : "检查更新",
                    systemImage: "arrow.triangle.2.circlepath",
                    isEnabled: !update.isChecking && update.canCheck
                ) {
                    update.checkManually()
                }
            }

            SettingRow(
                title: "每天自动检查一次",
                subtitle: "启动时向 GitHub 查一次发布信息，只发送当前版本号，不含任何设备或使用信息。关闭时只有点上面的按钮才联网。",
                isLast: true
            ) {
                FunFanToggle(isOn: $update.autoCheckEnabled, size: 24)
            }
        }
    }

    /// 发现新版本时的高亮卡片。
    ///
    /// 用 accent 而不是 attention：有新版本是好消息，不是警告。
    /// 但下载说明必须写「拖进应用程序覆盖」——直接运行下载目录里的 `.app`
    /// 会触发 App Translocation，后台组件装不上（发布手册里的老坑）。
    private func availableUpdateCard(_ info: ReleaseInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.accentFill)
                // 不用字符串插值直接塞 SemanticVersion：它走 LocalizedStringKey
                // 的插值会告「本地化插值退化成 debug 描述」，显式取 description 更干净。
                Text("有新版本 " + info.version.description)
                    .font(Theme.Typo.metaStrong)
                    .foregroundStyle(palette.textPrimary)
                Spacer(minLength: 0)
            }

            Text(updateCardSubtitle(info))
                .font(Theme.Typo.meta)
                .foregroundStyle(palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                FunFanButton(title: "下载", systemImage: "arrow.down.circle") {
                    update.openDownloadPage()
                }
                FunFanButton(title: "忽略此版本", systemImage: "eye.slash") {
                    update.skipCurrentUpdate()
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(palette.accentWash)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(palette.accentFill.opacity(0.25), lineWidth: 0.5)
        )
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private func updateCardSubtitle(_ info: ReleaseInfo) -> String {
        var text = ""
        if let published = info.publishedAt {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "yyyy-MM-dd"
            text += "发布于 \(formatter.string(from: published))。"
        }
        text += "下载 DMG 后按里面的引导把 FunFan 拖进「应用程序」覆盖安装；忽略只跳过这一个版本，更新的版本还会提示。"
        return text
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
