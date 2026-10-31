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
  - Verify（真机端到端，2026-10-31 实测）：新增 `--strategy curve` 启动参数后无人值守跑通全链路——
    · 接管：启动 1.5 s 后 `status` 由 `automatic/1000` 变为 `manualFixed/目标 2090`；
    · 随温度变化：8 路 `yes` 压满载，目标 2116→2206→2253→2293→2333 单调上升，停止加热后受热惯性继续到 2368 再回落 2210；实际转速与目标误差 0–3 RPM；
    · 崩溃返还：`kill -9` GUI 后 7 s 仍 `manualFixed`（helper 仍在写），第 8 s 租约到期转 `automatic`，转速回落 1000；
    · 反推 die 温度：空闲约 57.5℃ / 满载约 64.6℃（均衡曲线 78 RPM/℃ 的斜率反算，与实测目标变化一致）。
  - Files: `FunFanCore/Control/{CommandGate,CurveAutomation,CurvePreset}.swift`, `FunFanCore/Rules/CurvePersistence.swift`, `FunFan/Stores/CurveStore.swift`, `FunFan/Views/CurveEditorView.swift`
  - 设计取舍：① 安全下限**优先于斜率限制**——95℃ 时不允许「慢慢爬」，必须立刻满转（`testSafetyFloorBeatsSlewRate` 钉死）；② 死区/重断言逻辑从 `RuleAutomation` 抽到 `ControlCommandGate`，规则与曲线共用，避免两条策略抖动行为分叉；③ 原生 bordered 按钮在离屏渲染下只能画出禁止符，新增 `FunFanButton` 自绘。

- [x] T14c: SettingsView（设置窗口：登录启动 / 菜单栏显示 / 自检 / 免责声明）
  - Acceptance: 登录启动可注册/取消（走 `SMAppService`）；「菜单栏显示温度」立即生效；硬性安全项（退出/合盖返还）以只读方式常驻展示；一键自检给出「几项失败/降级」结论；免责声明常驻可见。
  - Verify: 离屏渲染核查设置窗口（三节布局、长文案换行、免责声明完整、无溢出）；真机启动（`--settings-window`）进程存活无崩溃，退出后风扇仍为 `automatic`。
  - Files: `FunFan/Stores/SettingsStore.swift`, `FunFan/Views/SettingsView.swift`, `FunFan/App/AppDelegate.swift`, `FunFan/Views/MenuBarView.swift`
  - 取舍：① **不做假开关**——设计稿提到「传感器勾选」，但当前温度宫格是固定四项、没有可勾选列表，与其摆一个点了没反应的开关，不如不放；② 开发态（裸二进制、无 `.app` 包）注册登录项必然失败，显式识别并说明原因，而不是把系统错误码丢给用户；③ 设置页不用 `ScrollView`（离屏渲染不填充内容），内容高度约 560 pt 直接铺开。
- [ ] T16b: 合盖检测 + 端到端规则自动调速验证（需先装 helper）
  - [x] 合盖检测：`LidPolicy`（判据纯函数，4 组单测）+ `LidMonitor`（在线显示列表 + 屏幕变化通知）+ `ControlStore.suspendForLid/resumeAfterLid`
  - [x] helper 安装：`scripts/install-helper.sh` 增加安装后 `codesign --force --sign -`（SPM 直出的 linker-signed 签名会被 launchd 拒绝，报 `Bootstrap failed: 5`）
  - [x] **行为链**（2026-10-31 真机实测，`--simulate-lid cycle` 注入信号，Mac mini 上无盖也能验）：
    · 接管 → 合盖：00:46:31.3 注入，之后 8 秒内即使采样继续也**没有任何重新接管**（`guard suspendedForLid` 生效）；
    · 合盖 → 开盖：00:46:39.7 注入，0.3 秒后恢复 `manualFixed / 目标 1971`；
    · 合盖期间采样自动降到 idle 档（5 s），减少塞包时的无谓 IPC。
  - [x] **修复时序漏洞**：`willSleep` 原来只调 `release()`（返还不置挂起标记），采样线程可能在睡眠通知后的最后几帧重新接管，把风扇锁在手动转速里睡过去。改为 `suspendForSleep()`，与合盖共用同一条「返还 + 挂起 + 清引擎」路径。
  - [ ] 合盖**判定**真机验证：需笔记本机型。本机 Mac mini 无内建屏、无电池，`isPortable=false` 使判定路径整体不生效，只能用模拟信号验行为。

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

> 进行中（2026-10-31）。本机**没有 Developer ID 证书**，所以「签名 + 公证 + 装订 + Gatekeeper 验收」
> 这条链只完成了「失败路径 + 提交前预检」的验证，成功路径要装好证书的机器复验。
>
> **2026-10-31 决定：不购买 Apple Developer Program 会员（$99/年），对外发未公证内测包。**
> 因此 T17b 的公证成功路径不再列为待办，改为「保留但长期不启用」。
> 分发方式写进 README「安装」一节（拖进 /Applications → 系统设置「仍要打开」→ 一次性放行），
> 发布命令是 `make publish-unsigned`。代价：用户首次启动多两步、每次升级重复一遍。

- [x] T17a: 把 SPM 产物打成可运行的 .app
  - Acceptance: 产出 dist/FunFan.app（Info.plist 带 LSUIElement、bundle id、版本；helper 与 daemon plist 内嵌）；可启动、无 Dock 图标。
  - Verify 实测：3.3 MB 包，内到外 adhoc 签名 `flags=0x10002(adhoc,runtime)`，`codesign --verify` 通过；
    `open` 后进程存活，`lsappinfo` 报 `type="UIElement"`；`CFBundleExecutable` 一致性自检通过；
    `spctl` 拒绝（adhoc 预期）；版本 1.0.0 (build=7 提交数)。
  - Files: `packaging/{Info.plist,FunFan.entitlements,FunFanHelper.entitlements,com.funfan.helper.plist}`, `scripts/build-app.sh`, `VERSION`, `Makefile`

- [x] T17b: Developer ID 签名 + 公证脚本
  - Acceptance: `make notarize` 完成签名 → DMG → 公证 → 装订 → Gatekeeper 验收；无证书时给出可执行诊断。
  - Verify 实测：`make notary-check` 在本机准确报「缺 Developer ID 证书 + 缺 funfan-notary 凭据」并退出 2，
    同时确认现有包已开硬运行时、无 `get-task-allow`；`make dmg` 产出 880 KB DMG，挂载内容为
    FunFan.app + Applications 软链。**公证成功路径未验证（本机无证书）**。
  - Files: `scripts/notarize.sh`, `scripts/make-dmg.sh`

- [x] T17c: helper 一次授权（SMAppService）
  - Acceptance: App 内安装/卸载特权组件；helper 只接受自家签名客户端；与旧脚本安装互斥。
  - Verify: 258 单测全绿（新增 11 个：签名要求串格式/单行/adhoc→nil/TeamID 去空白，状态映射与文案）。
    裸二进制 `--helper-status` 实测输出「系统注册能力：不可用 —— 当前以开发模式运行」并退出 2。
    **打包后的注册流程未在本机验证**：agent 沙箱内执行 .app 内可执行文件即被 SIGKILL
    （`sandbox_extension_issue_file_to_process` 失败），需用户终端复验 `dist/FunFan.app/Contents/MacOS/FunFan --helper-status`。
  - Files: `FunFanCore/Helper/*`, `FunFanCore/System/CodeSigningInfo.swift`, `FunFan/System/HelperInstaller.swift`, `FunFan/DevTools/HelperCLI.swift`

- [x] T18: 冲突检测 + doctor 自检 + 免责声明
  - Acceptance: 启动探测 `F0Md` 被第三方持有时友好提示并拒绝接管；`doctor` 自检打印关键键名/代系；`SettingsView` 含安全免责声明。
  - Verify 实测：`doctor` 新输出「机型标识 Mac16,10 / 芯片 Apple M4 / 架构 arm64 / 关键键 FNum、F0Tg、F0Md / F0md、Ftst」；
    冲突检测 10 个单测（只有手动模式算冲突、持有租约不算、未知模式按手动、进程名单只用于解释）；
    Popover 冲突提示条带「重新检测 / 仍要接管」；免责声明此前已在设置页落地。
    判据刻意**只看硬件事实**（`F0Md=1` 且我们没租约），不依赖对方进程是否在名单里 ——
    名单只用来把「有东西在控制」解释成「大概是 Macs Fan Control」。
  - 未验证：与 Macs Fan Control 真机共存（本机未装对方软件）。
  - Files: `FunFanCore/Control/ConflictDetector.swift`, `FunFan/System/RunningApps.swift`, `FunFan/Stores/ControlStore.swift`, `FunFan/Views/MenuBarView.swift`, `FunFanCtl/main.swift`

- [x] T18b: 一键安装后台组件（管理员授权回退）+ Popover 展开失效修复
  - Acceptance: 开发构建（adhoc / 裸二进制）也能在 UI 上点一下装好后台组件，不需要开终端敲 sudo；
    「展开各核心温度」点击生效且展开后 popover 高度跟随。
  - 为什么: SMAppService 在 adhoc 签名下能注册但启动不了，UI 上唯一的安装入口因此长期不可用；
    而把用户赶去终端是最容易被放弃的一步。
  - Verify 实测：
    - `HelperInstallScript` 11 个单测（plist 可被 `PropertyListSerialization` 解析、命令顺序、
      POSIX 单引号转义、AppleScript 转义顺序）；
      其中两条是**外部校验器**跑的：`/bin/bash -n` 过安装/卸载脚本语法、`/usr/bin/osacompile`
      真编译 AppleScript（转义写错会在这里炸，而不是在用户机器上）；
    - 裸二进制 `--helper-status` 实测输出「后台组件：已直装到 /Library/PrivilegedHelperTools」+
      「launchd 运行中：是」（本机装着脚本版，两套记账分开报）；
    - 离屏渲染：收起态 320×458 pt、展开态 320×589 pt（+131 pt），
      核心温度逐条正常、无重叠；设置页「已安装（直装…）+ 卸载」布局正常。
  - 未验证：管理员授权路径的**真实密码框与落盘**（agent 沙箱内 `sudo` 被拒、`osascript`
    弹框无法交互），需在用户终端跑一次「一键启用」确认。
  - Files: `FunFanCore/Helper/HelperInstallScript.swift`, `FunFan/System/HelperInstaller.swift`,
    `FunFan/Views/{MenuBarView,SettingsView}.swift`, `FunFan/App/AppDelegate.swift`,
    `FunFan/DevTools/{HelperCLI,RenderCheck}.swift`, `Tests/FunFanCoreTests/HelperInstallScriptTests.swift`

- [x] T19: 首个对外发布（alpha）
  - Acceptance: `VERSION` 提到 `1.0.0-alpha.1`，一条命令发出 GitHub Release（prerelease，非草稿），
    附件三件套齐全且与 tag 一致。
  - Verify 实测：
    - `bash scripts/release.sh --allow-unsigned --publish --notes release-notes/v1.0.0-alpha.1.md`
      跑通：单测 281 全绿 → adhoc 打包 → DMG 968K / ZIP 972K / SHA256SUMS → tag `v1.0.0-alpha.1` → 发布；
    - release 状态 `isDraft=false / isPrerelease=true`，三附件 `state=uploaded`；
    - **哈希三方一致**：GitHub 记录的 asset digest、本地 `SHA256SUMS.txt`、本地重算三者完全相同；
    - 挂载已发布的 DMG 复核：版本 `1.0.0-alpha.1` build 19、`FunFanHelper` 1.03 MB 在内、
      `codesign --verify --deep --strict` 通过；tag 指向 `84a11d6`＝HEAD。
  - 未验证：真实用户机器上的 Gatekeeper 放行流程（本机已放行过、隔离属性也清过，复现不出首次拦截）。
  - Files: `VERSION`, `release-notes/v1.0.0-alpha.1.md`, `README.md`

- [x] 调研：Homebrew 发布可行性（2026-10-31）
  - 结论：当前 adhoc 形态三条路全堵——官方 cask 2026-09-01 起强制签名+公证
    （Homebrew 5.0 弃用、`--no-quarantine` 已移除，本机 brew 7.0.11 实测
    help/manpage 0 匹配），adhoc+隔离在 Apple Silicon 弹「已损坏」；
    自建 tap 撞同一堵墙；formula 免证书但 `funfanctl` 依赖特权 helper，无意义。
    **前提决策：买不买 Developer ID（$99/年）**，不买则仅存档。
  - 产出：`docs/HOMEBREW.md`（路线对比 / 政策依据 / tap 搭法 / cask 模板 /
    行动清单）；待启用项：SMAppService daemon 的 cask 卸载路径需真机实测。
  - Verify 实测：本机 Homebrew 7.0.11 上确认 quarantine 绕过参数已不存在；
    官方文档（docs.brew.sh）逐页核对 Acceptable Casks / Package Acceptance
    Policy / Tap-Trust / Tap 创建指南现行条文。
  - Files: `docs/HOMEBREW.md`

---

## M7 · 展开面板核数诚实化（方案 A，2026-10-31）

> 背景：用户报「展开面板的 CPU/GPU 个数和实际对不上」。根因是 UI 用 **SMC 温度键数量**
> 倒推核心数，而 Apple Silicon 一个物理核簇会暴露多个温度探测点（`Tp00/Tp01…` 是探测点
> 编号不是「第几个核」）。Mac mini M4 实测 P 簇 18 个 `Tp*` 键对应仅 4 个 P 核，于是面板
> 显示 P=2/E=1/GPU=2，与真实 4/6/1（GPU 10 核）不符。

- 方案 A：核心数改由**系统接口**获取，SMC 温度键只用于贴温度，不再数核。
  - T-A `ChipTopology`（FunFanCore/Hardware）：P/E 走 `sysctl hw.perflevel0/1.physicalcpu`，
    GPU 走 IORegistry `AGXAccelerator` 的 `gpu-core-count`；`TopologyProviding` 协议可注入假数据单测。
  - T-B 退休 `isCoreLevel`：分组逻辑下沉 `CoreGroups.swift`，`CoreGroup.sensors` 列出簇内全部
    真实 SMC 探测点（真实键名），数量 = 真实键数；`SensorCatalog` 编造的「P-Core 0/
    GPU Cluster 0」命名改回真实键名。
  - T-C `MonitorStore` 暴露 `chipTopology`，`MenuBarView` 展开顶部加「芯片真实拓扑卡」
    （如 `Apple M4 · 4P + 6E · 10 核 GPU`），温度分组标注「温度探测点 N 个（非逐核）」。
  - T-D `funfanctl topology` 子命令，真机核对：`Apple M4 · CPU 10 核（性能 4 + 能效 6）· GPU 10 核`。
- 关键决策：**不再维护「逐核映射表」**。早期 `isCoreLevel` 标记硬编码表项来防虚构核数，但表会
  跨机型错配（如 `Tf04/Tf09` 与 `Tp01/Tp09` 同名「P-Core 0」重复计数），且仍对不上真实核数。
  改为「系统接口读真实核数 + SMC 仅展示探测点」，彻底消除误导。
- 提交：`6c591b7`（ChipTopology）、`ac88ca6`（退休 isCoreLevel）、`89891e9`（拓扑卡）、
  `a815b6c`（funfanctl topology）。
- Verify：
  - `swift test --disable-sandbox`：全绿（含 ChipTopologyTests 真实探针读 M4 硬件、SensorGranularityTests
    断言簇内探测点数=真实键数且键名不含「Core」）。
  - 本机 `funfanctl topology` 输出与本机 sysctl/IORegistry 完全一致（4P+6E+10GPU）。
  - UI 为真机可视项：需在用户终端 `make app` 后目检拓扑卡与探测点列表。

---

## 完成判据（全量）
满足 `docs/SPEC-FunFan.md` §8 全部 12 条 Success Criteria；`make test` 全绿（单测 ≥80% 覆盖）；`make build` 产出可分发 app。
