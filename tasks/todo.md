# Tasks: FunFan —— 实现任务清单（Phase 3）

> 配套：`tasks/plan.md`（Phase 2 计划）、`docs/SPEC-FunFan.md`（规格）
> 规则：每任务单一焦点、可单 session 完成、≤5 文件、含验收与验证步骤；按依赖排序。
> **每完成一个 T 任务（或一个可独立验证的改动）立即提交一次**，提交信息写清「做了什么 + 为什么 + 验证结果」。
> 阶段：M1 smc-core → M2 监控 → M3 控制/规则 → M4 helper → M5 GUI → M6 打包

---

## M1 · smc-core 地基

> ✅ 已完成并**真机验证**（2026-10-30）：`SMCParamStruct`=80B、逐字段偏移与 C 布局一致；AppleSMC 实测 `FNum=1`、Fan0 实际 1001 / min 1000 / max 4900 RPM、`Tp01` 58.9℃、`Tg0G` 45.8℃。`swift test --disable-sandbox` 15/15 通过。

- [x] T1: 实现 SMCParamStruct + SMCService 连接
  - Acceptance: 定义严格 80 字节 `SMCParamStruct`（显式填充对齐，含静态 assert `MemoryLayout.size == 80`）；`SMCService` 可打开/关闭 `AppleSMC` IOKit 连接，selector=2，`SMCCall` 收发。
  - Verify: `make test` 中 `SMCParamStructTests` 通过；编译无对齐警告。
  - Files: `FunFanCore/SMC/SMCParamStruct.swift`, `FunFanCore/SMC/SMCService.swift`

- [x] T2: 实现 SMCKey 探测 + GetKeyInfo + Codecs
  - Acceptance: `SMCKey` 提供键存在性探测（先 `GetKeyInfo`）；`Codecs` 按 `dataType` 解码 flt(小端 f32)/fpe2/ui8，编码逆向；绝不写死机型键。
  - Verify: `CodecsTests` 编解码往返 + 大小端全绿。
  - Files: `FunFanCore/SMC/SMCKey.swift`, `FunFanCore/SMC/Codecs.swift`, `Tests/FunFanCoreTests/CodecsTests.swift`

- [x] T3: 实现通用只读读取 + 单测固化
  - Acceptance: `SMCService.read(_ key:)` 按 `GetKeyInfo` 取类型再解码，返回 `Double/Int`；封装 `FunFanError`（`.keyNotFound`/`.smcAccessDenied`）。
  - Verify: `SMCParamStructTests` + `CodecsTests` 全绿；mock 键集下读返回正确值。
  - Files: `FunFanCore/SMC/SMCService.swift`(扩展), `FunFanCore/Types/Errors.swift`

## M2 · 监控层

> ✅ 主体完成（2026-10-30，TDD 红→绿，77/77 单测通过）。真机（M4 Pro 级、无电池台式机）验证：
> 全键枚举 1369 键 / 5–8 ms；温度键 180 → 采样 107（默认排除 `.other`）；IPC 1584→107 次/帧；稳态 19.5 ms/帧。
> 修复两个真机暴露的缺陷：① 台式机 `AppleSmartBattery` 全 0 被误判为「有电池」；② 前缀回退把所有 `Tp*` 当「P 核」，虚构出 41 个核。
> 待办：HID 回退（Intel-only，v1 不做）、`AppleSmartBattery` 明细需**带电池机型**复验、逐核密钥表补全（T4b）。

- [x] T4: 实现 SensorCatalog（温度键枚举 + 语义归类 + 三级回退）
  - Acceptance: 内置 M1–M5 逐代 `T*` 键→友好名→类别映射；三级回退（密钥表→全 `T*` 枚举→HID）；分类 `Tp/Tf/Te→CPU`、`Tg→GPU`、`Tm→Memory`、`TB→Battery`、`TA→环境`、其余 `other`；合理性过滤 5–131℃。
  - 实现结果: `SensorCatalog.descriptor(for:)` + `temperatureKeys(fromAllKeys:)`；新增 `isCoreLevel` 区分「内置表确认的逐核条目」与「前缀推断的聚合成员」，避免虚构核心数。
  - Verify: `SensorCatalogTests`、`SMCKeyEnumerationTests`、`SensorGranularityTests` 全绿；真机 180 温度键归类正确（cpu 57 / gpu 18 / ssd 29 / memory 3 / other 52）。
  - Files: `FunFanCore/Monitor/SensorCatalog.swift`, `FunFanCore/SMC/SMCKeyEnumeration.swift`, `FunFanCore/Monitor/SensorModels.swift`

- [x] T5: 实现 SensorStore（温度/转速轮询 + 滑动均值）
  - Acceptance: 轮询 SMC、维护最新值 + 可配窗口滑动均值；读操作免 root；失败重试。
  - 实现结果: `SensorMonitor`（纯逻辑引擎，注入样本源）+ `SlidingWindow`；`SMCTemperatureProvider`（键表缓存 + 类别过滤 + 合理性过滤 + 失败跳过）；`SamplingPolicy`（0.5/2/5 s 自适应）。
  - Verify: `SensorMonitorTests`、`SMCTemperatureProviderTests`、`TemperatureProviderScopeTests`、`SamplingPolicyTests` 全绿；真机 3 帧时序稳定（19–24 ms）。
  - Files: `FunFanCore/Monitor/SensorMonitor.swift`, `SMCTemperatureProvider.swift`, `SamplingPolicy.swift`

- [x] T6: 实现 BatteryStore（电量/健康/循环/功率，无电池降级）
  - Acceptance: `IOPS*` + `AppleSmartBattery` 双源；AS 容量键回退（`AppleRawMaxCapacity`→`MaxCapacity`）；派生电量%/健康度/功率；无电池降级。
  - 实现结果: `BatteryDetailParser`（纯函数解析注册表，含温度单位启发式）+ `AppleSmartBatteryReader` + `SystemBatteryProvider` 合并两源。
  - Verify: `BatteryMathTests`、`BatteryDetailTests`、`BatteryPresenceTests` 全绿；真机无电池 → `present=false` 正确降级。
  - Files: `FunFanCore/Battery/BatteryState.swift`, `BatteryStore.swift`, `BatteryDetailParser.swift`

- [ ] T4b: 补全逐代「逐核」密钥表（需真实机型 dump）
  - Acceptance: 对 M1–M5 各机型在负载下 dump 全部 `T*` 读数，按「同核多探测点」规律归纳出逐核键→核心号映射；`SensorCatalog.table` 补全；UI「展开各核心」能列出真实核心数。
  - 现状: 本机 41 个 P 簇传感器仅 3 个可确认逐核（`Tp01/Tp09/Te05`），其余按簇聚合展示——**这是诚实的数据边界，不虚构核号**。
  - Verify: 各机型 dump 结果与 `system_profiler` 核心数一致。

## M3 · 控制与规则引擎（纯逻辑，全单测）

> ✅ 完成（2026-10-30，TDD）：`SafetyPolicy` / `CurveEngine` / `RuleEngine` / XPC 契约 + `FanController`，129/129 单测通过。
> 真机只读演练（不写入）：`limits=1000–4900`、`die=73.6℃`、安全下限 **2517**、曲线目标 3270→clamp 3270、规则「CPU≥60℃→60%」→ **2940**。
> **诊断发现**：本机模式键为 **`F0Md`**（大写 d，证实必须运行时探测）；**`Ftst` 不存在** → 本机可直接写 `F0Tg`，无需解锁序列。

- [x] T7: 实现 SafetyPolicy（安全下限 clamp）
  - Acceptance: 任何策略输出经 `clamp(commanded, floor, F0Mx)`；下限基于核心温度动态算；绝不允许 0 RPM、绝不允许低于系统最小；F0Mn/F0Mx 禁写。
  - 实现结果: `FanLimits`（含 min>max 异常归一化）+ `SafetyProfile`（60℃→min，95℃→max 线性）+ `clamp` / `floorRpm` / `isValidTarget`。NaN/∞ 退回系统下限而非拉满。
  - Verify: `SafetyPolicyTests`（11 项）全绿。
  - Files: `FunFanCore/Control/SafetyPolicy.swift`

- [x] T8: 实现 CurveEngine（温度→转速插值 + 迟滞 + 斜率）
  - Acceptance: 曲线插值；迟滞死区；斜率限制；输出再经 `SafetyPolicy`。
  - 实现结果: `FanCurve`（自动排序、线性插值、区间外取端点）+ `CurveEngine`（首帧直落到目标、升温不延迟、降温需越过死区、slew rate 按 elapsed 缩放）。
  - Verify: `CurveEngineTests`（12 项）全绿，含确定性重放。
  - Files: `FunFanCore/Control/CurveEngine.swift`

- [x] T9: 实现 RuleEngine + FanRule 模型
  - Acceptance: `FanRule` Codable 持久化；`evaluate(snapshot, rules, limits)` 纯函数式：取值→判定（带迟滞）→冲突取**最大 RPM**→经 `SafetyPolicy` clamp→无触发返回 nil；可重放。
  - 实现结果: `SensorSubject`(.key/.category) + `Metric`(.instant/.average/.peak) + `RuleComparator`（**因与 Foundation.Comparator 冲突而改名**）+ `RuleAction`(.setRpm/.setPercent) + `RuleEngine`（仅持「已触发集合」一份状态）。
  - Verify: `RuleEngineTests`（19 项）全绿：阈值含等号、迟滞进/出、冲突取最大、percent 换算、下限抬升、传感器缺失清除状态、Codable 往返。
  - Files: `FunFanCore/Control/RuleEngine.swift`

- [x] T10: FanController 写入抽象 + XPC 协议 + IPC 往返单测
  - Acceptance: `FunFanXPC` 契约（setTargetRpm/restoreAuto/queryState/listFans/setMode）；payload Codable；`FanController` 经 transport 下发，默认 mock。
  - 实现结果: `FanControlRequest`/`FanControlReply`/`FanState`/`FanMode` + `FanControlErrorPayload`（`FunFanError` ↔ code/detail 双向映射）+ `FanControlTransport` 协议 + `FanController`（缓存上下限、下发前本地预检、失败透传）。
  - Verify: `IPCRoundTripTests`（10 项）全绿：请求/应答 JSON 往返、错误码唯一且可还原、0 RPM 拒绝且**不产生 IPC**。
  - Files: `FunFanCore/XPC/FanControlContract.swift`, `FunFanCore/Control/FanController.swift`

## M4 · 特权 helper（真机 + root 联调）

> ✅ 完成并**真机写入验证通过**（2026-10-30，TDD 红→绿，164/164 单测）。
> 真机实测（Mac16,10 / macOS 27.0.1，`sudo bash scripts/spin-test.sh`）：
> 目标 2950 RPM → 起飞过冲 3396 → **稳态 2949 RPM（偏差 1 RPM）**，返还后模式回到 automatic。
> 已实现：`SMCDataCodec.encode`（逐类型写入编码）、`SMCDevice` 抽象、`SMCService.writeKey`、
> `FanHardwareDriver`（探测式解锁→进手动→写目标→返还）、`ControlLease`（TTL）、
> `FunFanHelper`（XPC + 租约看门狗 + 退出返还）、`XPCTransport`、`funfanctl`（doctor/status/spin/set/restore）、
> `scripts/spin-test.sh`、`scripts/install-helper.sh`。
> 关键实证：`F0Md` 模式键、**无 `Ftst`**、`F0Tg` attr=0xD4（可写）而 `F0Ac`/`F0Mn`=0x84（只读）、
> 非 root 写入被拒（`smcAccessDenied`）——印证「监控免 root、写入必须 root」。
> **修正**：初版 `spin` 用「峰值 vs 目标」判定，把起飞过冲误判为失败；已改为「末 5 次均值 vs 目标 ±5%」。

- [x] T11: 实现 FunFanHelper root daemon + XPC listener
  - Acceptance: XPC listener（Mach service `com.funfan.helper`）；写操作带 TTL 租约看门狗（过期自动返还）；退出/信号返还；`LaunchDaemon.plist` 由安装脚本生成。
  - Verify: `swift build -c release` 产出 helper；`sudo bash scripts/install-helper.sh` 加载成功；`install-helper.sh status` 显示 running。
  - Files: `FunFanHelper/main.swift`, `FunFanCore/XPC/HelperProtocol.swift`, `FunFanCore/XPC/XPCTransport.swift`, `scripts/install-helper.sh`
  - 备注：v0 用 launchd 直装便于开发期验证；正式发布改为 App 内 `SMAppService.daemon`（需 Xcode 工程 + Developer ID）。

- [x] T12: 接通真实 FanController（探测式解锁 + F0Tg 写 + doctor）
  - Acceptance: 模式键 `F0Md`/`F0md` 运行时探测；`Ftst` 存在则解锁、不存在则直写；目标 clamp 到 `F0Mn–F0Mx` 且拒绝 0 RPM；写后以 `F0Ac` 收敛判定生效；`doctor` 输出键名/类型/属性/写入能力。
  - Verify: `FanHardwareDriverTests`（22 项）全绿；`sudo funfanctl spin` 观测 `F0Ac` 跟随。
  - Files: `FunFanCore/Control/FanHardwareDriver.swift`, `FunFanCtl/main.swift`, `Tests/FunFanCoreTests/FanHardwareDriverTests.swift`
  - 实测偏差：调研称「M3/M4 需要 Ftst」，但本机（M4 级）**无 Ftst** → 已实现为探测式，不写死。

## M5 · GUI（菜单栏常驻）

> 🔄 第一增量完成（2026-10-30）：菜单栏 + Popover + 实时监控 + 自动/固定控制已可运行。
> `swift run --disable-sandbox FunFan`（或 `make run`）→ 状态栏出现风扇图标 + CPU 温度。
> 实测：进程稳定运行、无报错；采样在后台队列（约 19 ms/帧），Popover 开/关自动切换 0.5 s / 2 s。
>
> ✅ T15 完成（2026-10-30）：规则 UI + 持久化 + 自动化下发闭环，187/187 单测绿。
> 新增：`FunFanCore/Rules/RulePersistence.swift`（原子写 + 读时清洗 + 去重补名）、
> `FunFanCore/Control/RuleAutomation.swift`（死区 40 RPM / 10 s 重断言 / 解除只发一次）、
> `SamplingPolicy.Visibility.automation`（规则接管时 1 Hz）、
> `FunFan/Stores/RulesStore.swift`、`FunFan/Views/RulesView.swift`、
> `FunFan/Views/Components.swift`（自建分段控件与开关，替代 AppKit 宿主控件）、
> `FunFan/DevTools/RenderCheck.swift`（`FunFan --render <目标> <png> [--scale N]` 离屏渲染走查）。
> 规则文件：`~/Library/Application Support/FunFan/rules.json`，首次启动写入两条保守模板
> （默认**不接管**，需用户在规则窗口打开「规则接管风扇」总开关）。
> 校验方式：`screencapture` 需关闭沙箱才能用；离屏渲染无法呈现 `ScrollView` 内容与原生 Button/Slider（已知限制）。

- [x] T13: 实现 AppDelegate + StatusItem + Popover（无 Dock）
  - Acceptance: `.accessory` 激活策略；`NSStatusItem` + Popover 桥接；睡眠前 `release()`、唤醒后 `restart()` 重建 SMC。
  - Verify: 进程存活且无 stderr；状态栏显示风扇图标 + CPU 温度。
  - Files: `FunFan/App/AppDelegate.swift`, `FunFan/main.swift`, `FunFan/Theme.swift`
  - 待补：单实例锁（`NSRunningApplication` 检测）、`.app` 打包（`LSUIElement`）。

- [x] T14a: 实现 MenuBarView + 实时数据绑定（监控面）
  - Acceptance: 风扇环（实际/目标/区间/模式）；温度宫格 CPU/GPU/SSD/环境均温；可展开「各核心温度」（CPU P/E/Super 簇 + GPU，仅显示逐核确认项）；电量卡（健康/循环/功率，无电池自动隐藏）。
  - Verify: 真机数据正确（CPU/GPU 均温、107 个传感器、采样耗时显示）。
  - Files: `FunFan/Views/MenuBarView.swift`, `FunFan/Stores/MonitorStore.swift`
  - 待补：`CurveEditorView`（曲线编辑）、`SettingsView`（设置窗口）。

- [x] T16a: 实现 ControlStore + 睡眠/唤醒/退出返还（控制面）
  - Acceptance: 经 XPC 下发；自动/固定两策略可用；helper 不可用时优雅降级为「仅监控」并提示安装命令；2 s 租约心跳，过期自动同步为自动模式。
  - Verify: helper 未安装时 UI 显示降级提示且不崩；安装后固定转速生效。
  - Files: `FunFan/Stores/ControlStore.swift`, `FunFan/App/AppDelegate.swift`

- [x] T15: 实现 RulesView + RulesStore（规则持久化）
  - Acceptance: `RulesView` 增删改规则（作用对象/取值方式/比较/阈值/动作/迟滞）；`RulesStore` 读写 `~/Library/Application Support/FunFan/rules.json` 并即时持久化；首启写入两条保守模板（默认不接管）。
  - Verify: `RulePersistenceTests`(12) + `RuleAutomationTests`(11) 绿；`rules.json` 落盘内容正确；真实截图核查规则窗口（标题/总开关/两条规则/条件动作摘要/行内控件）无截断重叠。
  - Files: `FunFan/Views/RulesView.swift`, `FunFan/Stores/RulesStore.swift`, `FunFanCore/Rules/RulePersistence.swift`
- [x] T14b: CurveEditorView + 曲线策略（温度→转速连续调速）
  - Acceptance: 曲线可拖拽编辑（控制点不可越过邻居、步进 0.5℃/10 RPM）；安全下限以红色区域可视化且拖不进去；静音/均衡/性能三档预设按机型区间自适应；编辑即时落盘 `curve.json`；切到曲线策略后按当前温度持续接管。
  - Verify: `CommandGateTests`(7) + `CurveAutomationTests`(8) + `CurvePersistenceTests`/`CurvePresetTests`(16) 全绿，总计 247；离屏渲染核查曲线窗口（网格/折线/控制点/安全下限/预设/底部工具栏无截断重叠）；Popover 四态分段（自动/固定/曲线/规则）在 320pt 下不截断。
  - Files: `FunFanCore/Control/{CommandGate,CurveAutomation,CurvePreset}.swift`, `FunFanCore/Rules/CurvePersistence.swift`, `FunFan/Stores/CurveStore.swift`, `FunFan/Views/CurveEditorView.swift`
  - 设计取舍：① 安全下限**优先于斜率限制**——95℃ 时不允许「慢慢爬」，必须立刻满转（`testSafetyFloorBeatsSlewRate` 钉死）；② 死区/重断言逻辑从 `RuleAutomation` 抽到 `ControlCommandGate`，规则与曲线共用，避免两条策略抖动行为分叉；③ 原生 bordered 按钮在离屏渲染下只能画出禁止符，新增 `FunFanButton` 自绘。

- [ ] T14c: SettingsView（设置窗口：登录启动 / 菜单栏显示 / doctor / 免责声明）
- [ ] T16b: 合盖检测 + 端到端规则自动调速验证（需先装 helper）
  - [x] 合盖检测：`LidPolicy`（判据纯函数，4 组单测）+ `LidMonitor`（在线显示列表 + 屏幕变化通知）+ `ControlStore.suspendForLid/resumeAfterLid`
  - [x] helper 安装：`scripts/install-helper.sh` 增加安装后 `codesign --force --sign -`（SPM 直出的 linker-signed 签名会被 launchd 拒绝，报 `Bootstrap failed: 5`）
  - [ ] 端到端：规则越阈值 → 实际提速 → 合盖返还（需真机合盖验证；当前开发机为 Mac mini，无合盖能力，此项待笔记本机型）

- [x] T18: 系统信息采集（诊断报告）
  - Acceptance: 一条命令/一次点击拿到「机型、系统、芯片、SMC 键总数、温度键与不可读项、风扇区间与模式键、电池、合盖、helper 安装状态」；每项能力给出 `ok/降级/不适用/失败` + 失败时的排查建议；可输出 Markdown（贴 issue）与 JSON（回归对比）；能力出错时自动落盘。
  - Verify: `DiagnosticReportTests`(15) 全绿；真机 `funfanctl diagnose` 输出正确（1369 键 / 180 温度键 / 174 可读 / helper 已装 / 台式机无合盖）；`make diagnose` 可用；GUI 底部「诊断」按钮复制成功（离屏渲染核对接线）。
  - Files: `FunFanCore/Diagnostics/{DiagnosticTypes,DiagnosticsProbing,SystemInfoCollector}.swift`, `FunFan/Stores/DiagnosticsStore.swift`, `FunFanCtl/main.swift`, `FunFan/Views/MenuBarView.swift`
  - 已知发现 → 已修复：6 个温度键（`TR0Z`/`TR1d`–`TR5d`）类型为 `ioft`，已补编解码（见 T18b）。

- [x] T18b: 补 `ioft` 编解码（48.16 定点，64 位小端）
  - Acceptance: `ioft` 键可读；未接探针的哨兵值（高字节全 1）不得被当成"合法高温"混进均温；写入路径仍明确拒绝该类型。
  - Verify: `IOFTCodecTests`(9) 全绿（真机 6 组字节 + iSMC issue #39 哨兵样本）；真机 `diagnose` 从「180 个可读 174」变为「180 个可读 180」，降级项仅剩「普通用户不可写」。
  - Files: `FunFanCore/SMC/Codecs.swift`(`decodeIOFT`), `FunFanCore/SMC/SMCService.swift`(`readRawBytes`), `FunFanCtl/main.swift`(`raw` 子命令), `Tests/FunFanCoreTests/IOFTCodecTests.swift`
  - 依据：Asahi Linux SMC 文档与 Linux `macsmc-hwmon`（`macsmc_hwmon_read_ioft_scaled`）均按 48.16 处理；**必须按有符号解**，否则哨兵值 2.8e14 会骗过合理性过滤。

## M6 · 打包加固

- [ ] T17: 签名 + 公证脚本 + entitlements + helper 一次授权
  - Acceptance: `scripts/build.sh`/`notarize.sh` 完成 Developer ID 签名 + 公证；App 与 helper 各自 entitlements；helper 安装一次授权。
  - Verify: `make build` + `./scripts/notarize.sh` 通过；Gatekeeper 不拦截。
  - Files: `scripts/build.sh`, `scripts/notarize.sh`, `FunFan/*.entitlements`, `FunFanHelper/*.entitlements`

- [ ] T18: 冲突检测 + doctor 自检 + 免责声明
  - Acceptance: 启动探测 `F0Md` 被第三方持有时友好提示并拒绝接管；`doctor` 自检打印关键键名/代系；`SettingsView` 含安全免责声明。
  - Verify: 与 Macs Fan Control 共存时不抢键；`doctor` 返回非空键名。
  - Files: `FunFan/Stores/ControlStore.swift`(冲突检测), `FunFan/`(doctor), `FunFan/Views/SettingsView.swift`(免责)

---

## 完成判据（全量）
满足 `docs/SPEC-FunFan.md` §8 全部 12 条 Success Criteria；`make test` 全绿（单测 ≥80% 覆盖）；`make build` 产出可分发 app。
