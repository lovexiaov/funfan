# FunFan · UI 实现指南（Design → Dev Handoff）

> 配套设计稿：`docs/ui-prototype/funfan-design.html`（v1 视觉与信息架构）
> 配套规格：`docs/SPEC-FunFan.md` · 计划：`tasks/plan.md` · 任务：`tasks/todo.md`
> **状态说明**：本项目当前为**绿地（无源码）**。本指南中的「现状」均来自设计稿与 Spec/Plan 推导的**设计约束**；真实源码的 `文件:行号` 实测将在 T1–T18 实现后回填。若本指南与 Spec 有出入，以 Spec §8 成功标准与本文「实现约束」为准。

---

## 0. 改动分层（为何这个顺序）

UI 实现遵循「令牌 → 组件 → 页面 → 数据与算法」四层，自底向上，避免返工：

1. **令牌层**：先在 `FunFan/DesignTokens.swift` 落地颜色/字体/间距令牌，所有组件只引用令牌，不写裸色值。
2. **组件层**：基于令牌实现可复用组件（`FanRing`、`TempChip`、`BatteryCard`、`StrategySegmented`、`CurveChart`、`RuleRow`、`SettingRow`）。
3. **页面层**：四个画布（状态/曲线/规则/设置）由组件拼装，逻辑绑定到 `Stores`。
4. **数据与算法层**：`SensorStore`/`BatteryStore`/`RuleEngine`/`CurveEngine` 驱动上述视图，纯逻辑先单测（见 `tasks/todo.md` M2–M3）。

理由：令牌先行可保证深色/浅色主题一致；组件复用可把「圆角/间距变化」收口在令牌层；页面层只关心布局。

---

## 1. 五分钟接入

**构建命令（来自 Spec §3）**
```bash
make build      # xcodebuild -scheme FunFan -configuration Release build
make test       # xcodebuild test -scheme FunFan -destination 'platform=macOS'
make run        # 打开 build/Release/FunFan.app
make lint       # swiftlint / swift-format
./scripts/notarize.sh build/Release/FunFan.app
```

**源码地图（Spec §4）**
```
FunFan/App/        AppDelegate.swift · StatusItemController.swift   (菜单栏+生命周期+睡眠/合盖)
FunFan/Views/      MenuBarView · CurveEditorView · RulesView · SettingsView
FunFan/Stores/     SensorStore · BatteryStore · ControlStore · RulesStore
FunFanCore/SMC/    SMCService · SMCParamStruct · SMCKey · SensorCatalog · Codecs
FunFanCore/Control/ FanController · CurveEngine · RuleEngine · SafetyPolicy
FunFanHelper/      HelperMain · XPCService · LaunchDaemon.plist
```

**设计文件索引**
- 视觉原型：`docs/ui-prototype/funfan-design.html`（可浏览器直接打开，含交互演示）
- 本指南：`docs/ui-design-handoff.md`

---

## 2. 第 1 层 · 令牌落码

> 影响面：令牌变更波及**所有**组件与页面。务必先定令牌，再写组件。

| 设计令牌（CSS 变量） | Swift 建议名 | 取值 | 用途 |
|---|---|---|---|
| `--bg-panel` | `Color.ffPanel` | `#1C1C1E` | Popover/窗口底 |
| `--bg-elevated` | `Color.ffElevated` | `#2A2A2E` | 卡片底 |
| `--bg-inset` | `Color.ffInset` | `#141416` | 内嵌区/输入底 |
| `--bg-hover` | `Color.ffHover` | `white.opacity(0.06)` | 悬停 |
| `--text-primary` | `Color.ffText` | `#F5F5F7` | 主文字 |
| `--text-secondary` | `Color.ffText2` | `#A1A1A6` | 次文字 |
| `--text-tertiary` | `Color.ffText3` | `#6E6E73` | 辅助/标签 |
| `--separator` | `Color.ffSep` | `white.opacity(0.10)` | 分割线 |
| `--accent` | `Color.ffAccent` | `#46C8FF` | 主强调（风扇/冷却意象） |
| `--green/--amber/--red` | `Color.ffGreen/ffAmber/ffRed` | `#30D158 / #FF9F0A / #FF453A` | 温度三态 |
| `--radius-md / -sm` | `ffRadiusM / ffRadiusS` | `10 / 7` pt | 圆角 |
| 字体 | `Font.ffBody / .ffNum` | `.system(size:)` / 等宽数字 | 正文 / 数值 |

**迁移策略**：在 `FunFan/DesignTokens.swift` 中以 `extension Color { static let ffAccent = ... }` 与 `extension Font` 集中定义；`Assets.xcassets` 中建 Color Set 同时提供 Dark/Default 两态。组件禁止使用字面色值。

---

## 3. 第 2 层 · 组件

| 组件 | 对应 SwiftUI | 规格要点 |
|---|---|---|
| `FanRing` | `MenuBarView.swift` | 进度环展示实际 RPM 占比；SVG `stroke-dasharray` → SwiftUI `Circle().trim(from:to:)` + `stroke` |
| `TempChip` | `MenuBarView.swift` | 四宫格（CPU/GPU/SSD/环境）展示**均温**；按阈值着色（<60 绿 / 60–75 琥珀 / >75 红），色值取自令牌 |
| `CoreTempBreakdown` | `MenuBarView.swift` | 温度卡下「展开各核心」面板：依据 `SensorCatalog` 的 E/P/Super 簇与 GPU 簇分组，逐核列出温度并各自阈值着色；组均温由 `SensorStore` 计算 |
| `BatteryCard` | `MenuBarView.swift` | 电量% + 健康度 + 循环 + 充放电功率 + AC；数据来自 `BatteryStore` |
| `StrategySegmented` | `MenuBarView`+`ControlStore` | 自动/固定/曲线/规则四态切换；绑定 `ControlStore.strategy` |
| `CurveChart` | `CurveEditorView.swift` | `Path` 绘制温度→转速折线 + 安全下限虚线；节点可拖拽（demo 已演示纵向拖拽逻辑） |
| `RuleRow` + `RuleToggle` | `RulesView.swift` | 单规则行 + 启停开关；文案「当 [传感器] ≥ [阈值]°C（迟滞 x）→ 设定 y RPM」 |
| `SettingRow` | `SettingsView.swift` | 左标题+说明、右开关/按钮；分割线用 `--separator` |

**重点组件 — `CurveChart`**：用 `GeometryReader` 将温度域 (40–100°C) 映射到 X、转速域 (F0Mn–F0Mx) 映射到 Y；安全下限以红色虚线叠加；拖拽节点改 `Curve` 数据点后经 `CurveEngine` 重算并预览。交互逻辑已在设计稿 JS 中验证（纵向拖拽 + 折线重绘），可 1:1 移植。

---

## 4. 第 3 层 · 页面逐画布

### 4.1 状态（Popover 主界面）
- **目标态**：`docs/ui-prototype` 的 Status 屏——风扇环 + **温度四宫格（CPU/GPU 均温）** + 可展开的各核心明细 + 电池卡 + 策略切换。
- **涉及文件**：`MenuBarView.swift`、`Stores/SensorStore.swift`、`Stores/BatteryStore.swift`、`StatusItemController.swift`。
- **改造点**：Popover 宽约 320pt（设计稿为评审放大版）；菜单栏图标常驻（`NSStatusItem`），`.accessory` 激活策略无 Dock 图标；温度卡默认显示均温，点「展开各核心温度」按簇分组显示逐核温度。
- **验收**：监控数据每 2 Hz 刷新且免 root；CPU/GPU 既显示均温也支持按簇分开展示；温度超阈值时芯片与各核行均变色；策略切换即时生效。

### 4.2 曲线（独立窗口/Popover 扩展）
- **目标态**：Curve 屏——可拖拽折线 + 安全下限 + 静音/均衡/性能预设。
- **涉及文件**：`CurveEditorView.swift`、`Control/CurveEngine.swift`、`Types/Curve.swift`。
- **验收**：拖拽节点实时重绘；输出经 `SafetyPolicy` 下限 clamp；预设一键套用。

### 4.3 规则（独立窗口）
- **目标态**：Rules 屏——规则列表（启停开关）+ 新增表单。
- **涉及文件**：`RulesView.swift`、`Stores/RulesStore.swift`、`Types/FanRule.swift`、`Control/RuleEngine.swift`。
- **验收**：新增规则持久化至 `~/Library/Application Support/FunFan/rules.json`；开关即时启停；多规则触发取最大 RPM（设计稿已说明）。

### 4.4 设置（独立窗口）
- **目标态**：Settings 屏——传感器勾选 + 登录启动 + 退出返还 + doctor + 免责声明。
- **涉及文件**：`SettingsView.swift`、`AppDelegate.swift`（自启/返还）、`ControlStore`（冲突检测）。
- **验收**：勾选控制显示项；「运行 doctor」输出 SMC 键名与代系；免责声明常驻可见。

---

## 5. 第 4 层 · 数据与算法

- **监控数据流**：`SensorStore`(2 Hz 轮询 SMC `T*`) / `BatteryStore`(IOKit 事件驱动) → `ObservableObject` → 视图绑定。均**免 root**，不经 helper。
- **控制数据流**：`RuleEngine.evaluate(snapshot, rules, prev)` 纯函数（1 Hz）→ `commandedRpm?` → `SafetyPolicy.clamp` → `ControlStore` 经 XPC 下发 `FanController.setTargetRpm` → helper 写 `F0Tg`。
- **关键不变量**（来自 Spec §5/§7）：任何策略只「提高」、不压系统下限；绝不 0 RPM；退出/合盖/睡眠必返还系统自动。

---

## 6. 实施顺序（PR 拆分，对齐 `tasks/todo.md`）

| PR | 范围 | 对应任务 | 为什么这个顺序 |
|---|---|---|---|
| PR-1 | DesignTokens + 基础组件 | T1–T3（M1，纯逻辑先行） | 令牌与 SMC 抽象是地基 |
| PR-2 | SensorStore + BatteryStore + 视图绑定 | T4–T6（M2） | 监控数据驱动状态页 |
| PR-3 | CurveEngine/RuleEngine/SafetyPolicy + 曲线/规则视图 | T7–T10（M3） | 控制纯逻辑先单测 |
| PR-4 | FunFanHelper + XPC + 真实 FanController | T11–T12（M4） | 接通真实写入与 Ftst 解锁 |
| PR-5 | GUI 装配（菜单栏/Popover/设置/返还） | T13–T16（M5） | 聚合全部能力 |
| PR-6 | 签名/公证/冲突检测/doctor | T17–T18（M6） | 收尾分发 |

每个 PR 自带对应单测；PR-4 起需真机 + root 集成测试（标记 `@Test`，仅手动/真机 CI）。

---

## 7. 验收清单

**全局**
- [ ] 深色/浅色主题均由令牌驱动，无裸色值；对比度 ≥ WCAG AA（4.5:1）。
- [ ] 菜单栏常驻、无 Dock 图标；单实例锁生效。
- [ ] 监控全程免 root；仅写经 helper。

**逐画布**
- [ ] 状态页：风扇环/温度四宫格/电池卡/策略切换渲染正确，2 Hz 刷新。
- [ ] 曲线页：拖拽折线重绘、安全下限可见、预设生效。
- [ ] 规则页：增删改持久化、启停即时、冲突取最大 RPM 文案正确。
- [ ] 设置页：传感器勾选、自启、doctor、免责声明齐全。

**回归重点**
- [ ] 退出/合盖/睡眠后风扇返回系统自动（Spec §8 #8）。
- [ ] 与其他控制器并存不抢键（Spec §8 #9）。
- [ ] `make test` 全绿，核心单测覆盖 ≥ 80%。

---

## 8. 设计决策（本次已确认）

> 以下各项已由产品/设计确认，v1 按此实现。

| # | 问题 | 已确认结论 | 影响 |
|---|---|---|---|
| H1 | 菜单栏图标默认用风扇旋转 SVG 还是文字「F」？ | **风扇线性图标**（见原型 menubar） | 需补品牌图形资源 |
| H2 | 曲线/规则/设置是 Popover 内分页还是独立窗口？ | **状态用 Popover；曲线/规则/设置为独立窗口** | `StatusItemController` + 窗口管理 |
| H3 | 温度三态阈值（绿/琥珀/红）固定 60/75 还是用户可配？ | **固定 60/75°C**（后续可参数化） | `TempChip` 内常量 |
| H4 | 浅色主题是否 v1 必须？ | **v1 即支持双主题**（令牌已预留） | 少量适配 |
| H5 | 规则编辑器是否需要「按传感器类别（如 CPU 簇均温）」聚合选项？ | **v1 仅单传感器** | `FanRule.sensor` 模型简单化 |
| H6 | 各核心温度默认**折叠**还是默认展开？ | **默认折叠**（均温优先，按需展开） | `CoreTempBreakdown` 默认折叠 |

---

## 附录 A · 令牌速查
见 §2 表格（CSS 变量 ↔ Swift 名 ↔ 取值）。

## 附录 B · 主要改动文件清单
**新建（设计相关）**
- `FunFan/DesignTokens.swift`（令牌落地）
- `FunFan/Views/MenuBarView.swift`、`CurveEditorView.swift`、`RulesView.swift`、`SettingsView.swift`
- `FunFan/App/StatusItemController.swift`、`AppDelegate.swift`（生命周期/监听）
- `FunFan/Stores/*.swift`（数据绑定）

> 注：本附录仅列 UI 相关文件；SMC/Control/Helper 等见 `tasks/todo.md` 各任务 Files 字段。

---

## 附录 C · 已实现 UI 的落地偏差（与设计稿对照）

| 设计稿元素 | 代码实现 | 偏差原因 |
|---|---|---|
| 分段控件（自动/固定/规则） | `Views/Components.swift` → `StrategySegmented`（自建） | 原生 `Picker(.segmented)` 是 AppKit 宿主：① 高亮色不可控，偏离 accent 令牌；② 无法被 `ImageRenderer` 离屏渲染，设计走查拿不到像素 |
| 开关（规则启用/总开关） | `Views/Components.swift` → `FunFanToggle`（26×15 轨道 + 150 ms 缓动） | 同上；`.accessibilityAddTraits(.isToggle)` 需 macOS 14+，部署目标 13，改用 label + value + hint 表达开关语义 |
| 规则列表容器 | `ScrollView + VStack` | 惰性容器（`LazyVStack`）在离屏渲染下不填充内容，不利于走查；规则数量级很小，用 `VStack` 无损性能 |
| 规则窗口入口 | Popover 内「编辑规则…」→ 独立 `NSWindow` | 遵循已确认决策 H2 |
| Popover 底部「诊断」按钮（**设计稿没有**） | `Views/MenuBarView.swift` footer 内、位于「退出」左侧 | 新增：能力出错时用户要能一键导出系统信息（机型/系统/SMC 能力逐项实测 + 排查建议）。样式沿用 footer 现有的 10 pt `.plain` 次级按钮，不引入新控件；同时 footer 左侧文案在复制后临时替换为「已复制诊断信息」，不新增行高 |
| 曲线屏：可拖拽折线 + 安全下限 | `Views/CurveEditorView.swift`（自绘 `Path` + `Circle` 控制点） | 用 `SwiftUI` 基础图形重画而不是引入 Canvas/第三方图表：① 控制点需要逐个命中拖拽（22 pt 半径），Path + 手势最直接；② 安全下限画成**红色带 + 虚线**——「拖不进去的区域」可视化比一行说明文字有效得多 |
| 曲线屏：三档预设按钮 | 自绘（`RoundedRectangle` 背景 + 选中描边） | 与 `StrategySegmented` 同源：原生 bordered 按钮在 `ImageRenderer` 下只画得出黄底禁止符，走查拿不到真实布局 |
| 曲线屏底部工具栏按钮 | `Views/Components.swift` → `FunFanButton`（新增） | 同上。原生 `.bordered` + `.controlSize(.small)` 无法离屏渲染；自绘后视觉与截图都可控，且样式与 Popover 现有次级按钮一致 |
| 分段控件扩成四态（自动/固定/**曲线**/规则） | `ControlStore.Strategy` 增加 `.curve` | 曲线是独立策略而非规则的一种：规则是「命中才提速、否则返还」，曲线是「一直按映射给目标」，混在一起会让用户无法预期。320 pt 宽下四段标签（各 2 字）实测不截断 |
| 设置屏：传感器勾选 | **未实现**（改为只放生效的开关） | 当前 Popover 温度宫格是固定四项（CPU/GPU/SSD/环境），没有可勾选的动态列表；摆一个点了没反应的开关比不放更糟。等做了可配置仪表盘再补 |
| 设置屏：入口 | Popover 头部齿轮图标（`gearshape`） | 页面已有「编辑规则…/编辑曲线…」两处文字入口，footer 再塞三个文字按钮会挤；头部图标是 macOS 菜单栏工具的惯例位置 |
| 设置屏：诊断区 | `DiagnosticsStore.runSummary` + 「复制」 | 设计稿只写「运行 doctor」。这里拆成两件事：**自检**（一句话结论）给普通用户，**复制完整报告**（Markdown）给报 bug 的用户，避免让他们先读 40 行再发现自己只需要一句「有没有问题」 |
| 设置屏：退出返还 | 只读行（锁图标 + 「始终开启」） | 这是安全不变量而不是偏好项（Spec §7），做成可关闭的开关等于给了用户「让风扇留在手动转速」的机会 |
| Popover 风扇区「目标」行在自动模式显示 `—` | `Views/MenuBarView.swift` → `fanSection` | `restoreAuto` 刻意只写模式键、**绝不写** `F0Tg`（写目标反而会把风扇拉起来），所以自动模式下 `F0Tg` 会留着上一次的残留值。原来直接显示它，读起来像「模式=系统自动，但还在按 1850 跑」。改为自动时显示 `—`，CLI `status` 同步标注「（残留值，未生效）」 |
| 键盘焦点环（设计稿未涉及） | `Views/FocusRing.swift` → `.funfanFocusRing(cornerRadius:outset:)`，套在全部自绘控件上 | 自绘换来了离屏可渲染，但也失去了原生控件的焦点外观：系统只能给整块 view 套**直角矩形**焦点环。开启「全键盘控制」（`AppleKeyboardUIMode = 2`）后，每个窗口/浮层一出现焦点就落在首个可聚焦控件上，直角框会一直挂着，套在胶囊开关和圆角卡片上明显错位。改为按控件自身形状画环（accent 2 pt，外扩 2–4 pt），macOS 14+ 同时 `focusEffectDisabled()` 关掉系统矩形环避免叠双层；13 无该 API，退化为系统环。**没有关闭键盘导航**——关掉环等于让全键盘用户失去「焦点在哪」的唯一提示 |
| 展开面板「按簇分核明细」（设计稿 `CoreTempBreakdown` 的每核温度） | `MonitorStore.coreGroups` → `CoreGroup.sensors`（全部 SMC 探测点，真实键名）+ 顶部「芯片真实拓扑卡」 | 设计稿假设能逐核读温度，但 Apple Silicon 一个物理核簇暴露**多个** SMC 温度探测点（`Tp00/Tp01…` 是探测点编号不是「第几个核」）。Mac mini M4 实测 P 簇 18 个 `Tp*` 键对应仅 4 个 P 核——逐核展示必然对不上真实核数。改为：核心数由 `ChipTopology`（sysctl perflevel + IORegistry gpu-core-count）提供，单独用拓扑卡显示；温度区只列真实探测点并标注「温度探测点 N 个（非逐核）」，不再伪造成核。早期 `isCoreLevel` 硬编码映射表同步退役（跨机型错配且仍对不上） |
| 「环境」格在无 `TA*` 键的机型上显示「无传感器」 | `MonitorStore.ambientAvailability`（`SensorAvailability`）→ `MenuBarView.tempChip(_:_:unsupported:)` | 设计稿默认四宫格都有值。Mac mini M4 实测**没有**任何 `TA*` 键，原来一律显示 `—`，会被读成「读失败、等一下就好」，实际永远不会恢复。改为三态：有值显示度数 / 有键但本帧没读到显示 `—` / 机器压根没有该传感器显示「无传感器」并附 tooltip。「有没有」由键表计数回答，不用单帧读数判断（读失败会被过滤，否则唤醒瞬间会误报） |

**设计走查方法**
```
swift build --disable-sandbox
./.build/debug/FunFan --render rules    /tmp/rules.png  --scale 3 --scheme light
./.build/debug/FunFan --render curve    /tmp/curve.png  --scale 3 --scheme light
./.build/debug/FunFan --render settings /tmp/settings.png --scale 3 --scheme light
./.build/debug/FunFan --render popover  /tmp/pop.png    --scale 3 --scheme light
./.build/debug/FunFan --render editor   /tmp/editor.png --scale 3
```
`--scheme light|dark`（默认 dark）把对应 `Palette` 注入环境再渲染；**走查必须明暗各渲一遍**——2026-11 复审的教训就是全部截图只有深色，浅色的语义色失效（1.28–2.52:1）长期无人发现。`--flat` 供含 `ScrollView` 的画面用：以「不滚动、全部摊开」的方式渲染内容（走查专用，真机仍滚动）。

焦点环不在 `ImageRenderer` 的产出里（它不参与响应者链，拿不到键盘焦点），加 `--force-focus` 可以强制画出来走查几何：
```
./.build/debug/FunFan --render settings /tmp/focus.png --force-focus
./.build/debug/FunFan --render popover  /tmp/focus.png --force-focus
```
真实焦点一次只会落在一个控件上，这个开关是为了同时看到所有形状对不对。
离屏渲染（`ImageRenderer`）可校验纯 SwiftUI 的文本/图形/布局，但**不呈现** `ScrollView` 内容与 AppKit 宿主控件；需要完整真机像素时用真实截图（需关闭沙箱）：
```
screencapture -x /tmp/shot.png
```

`--render popover` 会先启动一轮真实采样再画（约 1.2 s），因此风扇转速、温度、传感器数都是真机值，不是占位符。这是唯一能核验「自动/手动两种模式下目标行取值不同」的方法——判定逻辑不在视图里，靠静态假数据看不出来。

## 附录 D · 明暗双主题重构（2026-11-01，落实 `ui-review-2026-11-01.md`）

| 偏差 / 决策 | 位置 | 原因 |
|---|---|---|
| 配色从 `Theme.accent` 静态常量改为 `Palette` 双套 + `@Environment(\.palette)` 注入 | `Theme.swift`（`Palette.resolve(_:)`）→ 全部视图 | 同一色值服务不了两种外观：四个语义色按深底调校，浅色实测 1.28–2.52:1。也不用 Assets Color Set / `NSColor` 动态色——它们靠 `NSAppearance.current` 解析，离屏渲染拿不到，浅色会再次变成「看不见的东西」。**视图里不再允许 `Theme.accent` 这类静态色**，只认 `palette` |
| accent 拆两档：`accentText`（文字，≥4.5:1）与 `accentFill`（环弧/曲线/选中底/焦点环，≥3:1） | `Palette` | 一色四义是复审定性的语义问题；拆档后「可点的字」与「图形填充」不再互抢 |
| 温度色（cool/warm/hot）与界面提示色（attention/error）分成两条轴 | `Palette` | 「CPU 62℃」和「免责声明」不再共用一个黄；红色只留给 ≥75℃ 与错误 |
| 数值一律 `textPrimary`，温度只体现在指示物（`TemperatureIndicator`：实心点/点+外环/三角，颜色之外还有形态） | `Components.swift`、`MenuBarView.swift` | 「一切正常=全绿」使默认画面颜色信息量为 0，且把主数据降级成彩色文本；形态差也让色觉障碍用户可分 |
| 字号收敛为 15/12/11（+数值等宽档），最低 11pt | `Theme.Typo` | 原 13 个档位、92 处 ≤11pt、24 处 ≤9pt；坐标轴从 8pt 提到 11pt |
| 卡片分层改由描边承担（浅色白卡 + `cardStroke`），不再只靠 `primary.opacity` 差 5% | `Palette.cardFill/cardStroke` | 浅色下卡片与底仅 1.10:1，边界不可见 |
| 设置页第一组新增「外观」三态（跟随系统/浅色/深色），写入 `SettingsStore.appearance` | `SettingsView.swift`、`SettingsStore.swift`、`AppDelegate.swift` | 复审要求 1 的「手动覆盖」此前完全缺失。**不要**用 `NSApp.appearance` 全局覆盖——会把菜单栏图标一起反转；做法是每个窗口根视图 `@ObservedObject settings` 并 `.environment(\.colorScheme, resolved)`，已开窗口即时跟随 |
| 环境格三态：available→度数 / pending→`—` / unsupported→「无传感器」+tooltip | `MonitorStore.ambientAvailability` → `MenuBarView.tempChip` | 见附录 C「环境格」条目；本机实测无 `TA*` 键，「—」会被误读为暂时读不到 |
| 曲线安全下限从红带改中性斜纹 + 虚线；当前温度线改中性虚线 | `CurveEditorView.swift` | 红色只留给真正过热（≥75℃）；红带会被误读成「危险区」而非「画不到的地方」 |
| 弹窗展开区限高 280pt 内滚动；走查看全量用 `--render popover-cores --flat` | `MenuBarView.expandedThermalDetail` | P 簇 41 探测点会把 320pt popover 撑到 1700pt+；`ImageRenderer` 渲染不出 `ScrollView`，摊开模式是走查与真机之间唯一一致的观察窗 |
| 设置窗口高度 540×800（`minHeight` 780） | `AppDelegate.swift`、`SettingsView.swift` | 内容自然高度 ≈790pt（外观组 + 免责声明完整显示）；旧 580 会裁掉免责声明。无 ScrollView，高度必须给足 |
