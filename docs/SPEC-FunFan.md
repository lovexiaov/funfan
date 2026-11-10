# Spec: FunFan —— macOS 轻量风扇控制工具（Apple Silicon）

> 文档类型：开发规格（Spec），由调研文档 `macos-fan-control-research.md` 派生
> 模式：Agent 模式（可直接落地实现）
> 调研依据：同目录 `macos-fan-control-research.md`
> **UI 设计交叉引用**：视觉原型见 `docs/ui-prototype/funfan-design.html`，开发者落地指南见 `docs/ui-design-handoff.md`（两处若有出入，以实现指南的实测/设计约束为准）

---

## 0. 假设（Assumptions，开始前已确认/默认）
1. **平台**：v1 仅支持 **Apple Silicon（M1 及以上）** + **macOS 13 (Ventura) 及以上**（覆盖最新版本）。Intel 编解码保留但不测。
2. **分发形态**：店外分发（不上架 App Store），目标 **Developer ID 签名 + 公证**；开发期可用本地/adhoc 签名。
3. **控制语义**：固定 RPM / 传感器曲线 / 规则引擎三种策略**均只「提高 / 不压低系统默认下限」**；安全下限基于核心温度动态计算；退出/出错必返还系统自动。规则（含曲线）输出**绝不**将转速压到下限以下。
4. **功能范围（v1）**：① **系统状态实时监控**（均无需 root）：**硬件温度**（CPU/GPU/SSD/环境等主要传感器枚举与展示）+ **电池/电量**（电量%、健康度、循环次数、充放电功率、AC/充电状态，经 IOKit 电源 API）；② 固定 RPM；③ 传感器驱动曲线；④ **规则引擎**——基于温度阈值的自动调速（TG Pro 式规则，如「CPU ≥ 70℃ → 设定 3000 RPM」）；⑤ 预设（静音/均衡/性能）。CSV 日志、邮件/弹窗告警**不在 v1**（仅做状态展示与返还）。
5. **GUI 形态**：菜单栏常驻（无 Dock 图标）+ Popover；可选轻量设置窗口（含规则编辑、传感器选择、自启、关于/免责）。**面板开关语义**：点菜单栏图标在「显示 / 隐藏」之间切换（同一位置同一动作）；点面板外任意位置、右键图标、按 ESC、切走 App 均关闭。关闭时机**不依赖** `NSPopover.Behavior.transient`（其「按下即关」和 `NSStatusItem` 的 `.leftMouseUp` 动作时序打架，见 `AppDelegate` 注释与 `tasks/todo.md` M8）。
6. **特权模型**：`SMAppService.daemon` 安装 root helper，GUI 经 XPC 通信；GUI 进程**永不持有 root**；规则评估在 GUI 端完成，仅最终目标转速经 XPC 下发。

---

## 1. Objective（目标）
构建一款**简洁、轻量、带图形界面**的 macOS 风扇控制工具，在 Apple Silicon + 最新 macOS 上：
- **实时监控**风扇转速、**系统硬件温度**（CPU/GPU/SSD/环境等传感器，用户态、无需 root）与**电池状态**（电量%、健康度、循环次数、充放电功率、AC/充电状态，经 IOKit 电源 API、无需 root）；
- 以「固定 RPM / 传感器曲线 / **规则引擎**」三种策略**主动调速**，其中规则引擎可依据温度阈值**自动调整风扇速度**（如「CPU ≥ 70℃ → 3000 RPM」），从而实现无人值守的温控；
- 通过 `Ftst` 解锁序列接管 M3/M4 的风扇，并在 M1/M2/M5 上直接写入；
- 全程**安全优先**：安全下限、迟滞、斜率限制、睡眠/合盖/退出自动返还、冲突检测；
- 以最小资源占用常驻后台。

**用户故事**
- 作为高负载用户，我希望风扇在温度上升前**自动**提速（无需我手动干预），避免降频卡顿。
- 作为安静环境用户，我希望用「曲线 / 规则」在温度低时让系统自然静音、温度高时再接管。
- 作为规则型用户，我希望配置「当 CPU 超过 70℃ 就把风扇拉到 3000 RPM」，并带迟滞避免反复抖动。
- 作为普通用户，我希望安装后授权一次即可使用，退出后系统完全恢复，无任何残留风险。

**验收（Acceptance）**：见 §8 Success Criteria。

---

## 2. Tech Stack（技术栈）
| 层 | 选型 | 说明 |
|---|---|---|
| 语言 | **Swift 5.9+** | 原生、轻量 |
| UI | **SwiftUI**（macOS 13+） | 菜单栏 + Popover |
| 响应式 | **Combine** / async 定时器 | 1 Hz 控温、2 Hz 显示 |
| 硬件访问 | **IOKit `AppleSMC`**（用户态） | 80 字节 `SMCParamStruct`，selector=2 |
| 特权模型 | **`SMAppService.daemon`**（macOS 13+） | root helper 安装 |
| IPC | **XPC（`NSXPCConnection`）** | GUI ↔ helper，含代码签名校验 |
| 工程 | **Xcode 项目**（含多 target +  entitlements + 签名） | 单 App + Helper + Core 库 |
| 依赖 | **零第三方运行时依赖**（仅系统 IOKit） | 避免 Electron/重依赖 |
| 规则/配置 | **Swift `Codable` + JSON**（`~/Library/Application Support/FunFan/`），`UserDefaults` 存偏好 | 规则、曲线、预设可持久化 |
| 传感器归类 | 内置 **传感器名→语义映射表**（如 `TC0P`=CPU 封装、`Tg0p`=GPU、`Ts0p`=SSD），运行时叠加 **`T*` 动态枚举** | 设备差异自适应 |
| 电量/电池 | **IOKit `IOPMPowerSource`（`IOPS*`）+ `AppleSmartBattery` 注册表** | 电量%/健康/循环/充放电功率；无需 root、沙箱友好；AS 用 `AppleRaw*` 键 |
| 分发 | Developer ID 签名 + 公证（Notarytool） | 店外 |

---

## 3. Commands（命令）
```bash
# 构建 Release（含 helper）
make build
#   → xcodebuild -scheme FunFan -configuration Release build

# 运行测试（单测；集成测试需真机 + root）
make test
#   → xcodebuild test -scheme FunFan -destination 'platform=macOS'

# 本地运行（开发签名）
make run
#   → 打开 build/Release/FunFan.app

# 代码风格检查
make lint
#   → swiftlint（若引入）或 swift-format

# 公证（发布用，需账号凭据）
./scripts/notarize.sh build/Release/FunFan.app
```

---

## 4. Project Structure（目录结构）
```
FunFan/
├── FunFan.xcodeproj                # 主工程（多 target）
├── FunFan/                        # GUI 应用 target
│   ├── App/
│   │   ├── AppDelegate.swift       # 启动、状态栏、生命周期、睡眠/合盖监听
│   │   └── StatusItemController.swift  # NSStatusItem + Popover 桥接
│   ├── Views/
│   │   ├── MenuBarView.swift       # 实时转速/温度、快捷调速、当前策略状态
│   │   ├── CurveEditorView.swift   # 温度→转速曲线编辑
│   │   ├── RulesView.swift         # 规则列表 + 编辑器（传感器/阈值/比较/动作/迟滞）
│   │   └── SettingsView.swift      # 传感器选择、开机自启、关于/免责
│   ├── Models/                     # FanState, SensorReading, Curve, FanRule, Preset, BatteryState
│   └── Stores/                     # ObservableObject：
│       ├── SensorStore.swift       # 2 Hz 轮询温度/转速，维护最新读数+滑动均值
│       ├── BatteryStore.swift      # IOKit 电源 API 读电量/健康/循环/功率（事件驱动，无电池降级）
│       ├── ControlStore.swift      # 当前策略（手动/曲线/规则）、目标转速下发
│       └── RulesStore.swift        # 规则读写持久化 + 启停
├── FunFanCore/                     # 共享库（被 App 与 Helper 引用）
│   ├── SMC/
│   │   ├── SMCService.swift        # 打开/关闭连接、收发、键探测、键信息缓存、全键枚举
│   │   ├── SMCParamStruct.swift    # 80 字节结构体（显式对齐填充）
│   │   ├── SMCKey.swift            # 键名与类型枚举 + 探测
│   │   ├── SMCKeyEnumeration.swift # 按索引枚举全键（纯逻辑，异常槽位跳过）
│   │   └── Codecs.swift            # flt/fpe2/sp78/ioft/ui8 编解码（读 type 再解码）
│   ├── Monitor/
│   │   ├── SensorCatalog.swift     # `T*` 语义归类 + 温度键筛选（真实键名作标签）
│   │   ├── SensorModels.swift      # Descriptor/Reading/Snapshot + 类别与簇聚合
│   │   ├── CoreGroups.swift        # 按簇聚合温度组，列出真实 SMC 探测点（非核）
│   │   ├── SensorMonitor.swift     # 滑动均值引擎（注入样本源，纯逻辑）
│   │   ├── SMCTemperatureProvider.swift # 键表缓存 + 类别过滤 + 合理性过滤
│   │   └── SamplingPolicy.swift    # 自适应采样频率（引擎 1 / 显示 2 / 空闲 5 s）
│   ├── Battery/
│   │   ├── BatteryState.swift      # 状态模型 + 派生计算
│   │   ├── BatteryStore.swift      # IOPS + AppleSmartBattery 双源合并
│   │   └── BatteryDetailParser.swift # 注册表解析（纯函数）+ 读取器
│   ├── Control/
│   │   ├── FanController.swift     # 经 transport 下发（本地预检 + 缓存上下限）
│   │   ├── CurveEngine.swift       # 曲线插值、迟滞、斜率
│   │   ├── CurvePreset.swift       # 静音/均衡/性能预设（按占比定义，自适应机型区间）
│   │   ├── CurveAutomation.swift   # 曲线 → 安全下限 → 命令闸门
│   │   ├── RuleEngine.swift        # 规则评估：阈值/比较/迟滞/冲突取最大 RPM（含 FanRule 模型）
│   │   ├── RuleAutomation.swift    # 规则 → 命令闸门
│   │   ├── CommandGate.swift       # 死区/10 s 重断言/解除只发一次（规则与曲线共用）
│   │   └── SafetyPolicy.swift      # 动态下限、clamp、isValidTarget
│   ├── Rules/
│   │   ├── RulePersistence.swift   # rules.json 原子写 + 损坏降级 + 读时清洗
│   │   └── CurvePersistence.swift  # curve.json 原子写 + 几何清洗（不足 2 点视为无效）
│   ├── XPC/
│   │   └── FanControlContract.swift # 请求/应答/FanState/错误 payload + transport 协议
│   └── Types/                      # 错误类型、模型（Curve/Preset）
├── FunFanHelper/                   # 特权守护进程 target（root）
│   ├── HelperMain.swift            # SMAppService 注册入口
│   ├── XPCService.swift            # XPC listener + 代码签名要求
│   └── LaunchDaemon.plist          # 内嵌（BundleProgram）
├── Tests/
│   └── FunFanCoreTests/            # 编解码/曲线/规则/安全/迟滞/斜率/IPC round-trip
├── scripts/
│   ├── notarize.sh
│   └── build.sh
└── docs/
    ├── macos-fan-control-research.md
    └── SPEC-FunFan.md              # 本文件
```

### 4.1 温度监控与规则引擎设计要点

**温度监控（SensorStore + SensorCatalog）**
- `SensorCatalog`（温度监控核心，详见 §4.1）：**在 GUI 进程内直接读取、无需 root**（温度读取经 AppleSMC 只读路径，与风扇读取同源但只读）。策略为「逐代密钥表 + 三级回退」：
  1. **首选**：内置**逐代 SMC 密钥表**（M1–M5 各自一组键→友好名→类别），启动用 `sysctl` 读 CPU 品牌串识别代系后直接按键读值（参考 Stats / SiliconScope / swift-soc-metrics）。
  2. **回退 HID**：当某代/macOS 的 SMC 温度键被限制时，经 `IOHIDEventSystemClient`（UsagePage `0xff00`/Usage `0x5`）取热传感器（iStat 同款来源）。
  3. **兜底**：SMC 全 `T*` 枚举扫描（命名可信度低，仅兜底）。
  - 分类映射：`Tp*`/`Tf*`/`Te*`→CPU（细分 E/P/Super 簇）、`Tg*`→GPU、`Tm*`→Memory、`TB*`→Battery、`TA*`→环境；未匹配归 `other`。
  - **合理性过滤**：丢弃 (4,132)℃ 之外的值；睡眠切换偶发 `kIOReturnTimeout` 时 50 ms 后重试一次。
  - **类别可用性三态**：`TA*`（环境）等类别并非每台机器都有——Mac mini M4 实测 180 个温度键里 `TA*` 一个都没有。所以「本帧无读数」**不能**等同于「这台机器没有该传感器」（读失败、越界过滤、唤醒瞬间都会让当帧缺席）。两层分工：
    - `SMCTemperatureProvider.sensorCount(for:)` 回答「键表里有没有」，返回 `nil` = 尚未枚举（未知），`0` = 确实没有；
    - `SensorSnapshot.availability(for:sensorCount:)` 合成三态 `available(值) / pending / unsupported`。
    - UI 只对 `unsupported` 显示「无传感器」（+ tooltip 说明），`pending` 仍显示 `—`，避免误报闪烁。
  - 注意：`powermetrics`/`IOReport` 在 AS 上取不到具体摄氏度，温度**以 SMC 为准**。
- `SensorStore`：轮询 SMC 取各传感器实时值，维护「最新值 + 滑动均值（窗口可配，默认 30 s）」，供 UI 展示与规则评估；读操作无需 root。
- **UI 展示粒度**：CPU 与 GPU 同时提供 **均温**（四宫格主数值）与 **按簇明细**（CPU 细化 P 性能核 / E 能效核 / M5 Super 簇，GPU 单独一组），明细默认折叠、按需展开（见 UI 指南 `CoreTempBreakdown`）。展开面板顶部另有**芯片真实拓扑卡**（芯片名 + 性能核/能效核/GPU 核数），核心数来自系统接口而非温度键。
- **粒度诚实原则（实测教训）**：Apple Silicon 一个物理核簇会暴露**多个** SMC 温度探测点（`Tp00`/`Tp01`… 是探测点编号，不是「第几个核」）。真机实测 Mac mini M4 的 P 簇有 18 个 `Tp*` 键，对应却只有 4 个 P 核——拿温度键数量当核数必然对不上。因此：
  - 核心数改由 **`ChipTopology`（FunFanCore/Hardware）** 从系统接口读取：P/E 走 `sysctl hw.perflevel0/1.physicalcpu`，GPU 走 IORegistry `AGXAccelerator` 的 `gpu-core-count`；
  - SMC 温度键只作**温度探测点**展示，展开明细列出该簇全部探测点（真实键名 `Tp0W` 等），并标注「温度探测点 N 个（非逐核）」，绝不伪造成核数。
  - 早期用 `SensorDescriptor.isCoreLevel` 标记「内置表确认的逐核键」来防虚构的做法已退役（见提交 ac88ca6）——它既对不上真实核数，又依赖一份会跨机型错配的硬编码表。
- **采样范围与频率（性能约束，实测驱动）**：
  - 键信息（`dataSize`/`dataType`）开机内不变 → `SMCService` 缓存，读值只需 1 次 IPC（实测 IPC 1584 → 107 次/帧）。
  - 默认**不采样 `.other`** 类别（未识别传感器可达 52 个，占近三分之一成本且不展示）。
  - 自适应频率 `SamplingPolicy`：自动化接管（规则/曲线引擎）1 s（唯一的高频需求方，控制响应优先）、Popover 打开 2 s、仅菜单栏 2 s、空闲 5 s。面板打开的演进：0.5 s → 1 s（M13）→ 2 s（M14，温度是慢变量、UI 无感）。
  - **两层采样（M14）**：`SMCTemperatureProvider.fullScanEvery`（默认 1 = 每帧全量的旧行为；生产传 10）——每 N 帧做一次全量扫描并缓存各键读数，快帧只真读「上轮全扫中每类最热 K 个键」（`perCategoryHotKeys = 4`），其余键复用缓存值，**输出形状与全量一致**（消费方零改动，均温/hottest/明细列表稳定）。代价：非白名单键最多陈旧 N−1 帧。实测见 `FunFanProbe --tier`。

**规则数据模型（Codable，持久化至 `~/Library/Application Support/FunFan/rules.json`）**
```swift
struct FanRule: Codable, Identifiable {
    var id: UUID
    var name: String
    var enabled: Bool
    var subject: SensorSubject        // .key("Tp01") | .category(.cpu)
    var metric: Metric                // .instant | .average | .peak（空间聚合；时间平滑由 SensorMonitor 负责）
    var comparator: RuleComparator    // .greaterThanOrEqual | .greaterThan | .lessThanOrEqual | .lessThan
    var thresholdCelsius: Double
    var action: RuleAction            // .setRpm(Double) | .setPercent(Double)（相对 F0Mx）
    var hysteresisCelsius: Double     // 死区，避免阈值边缘抖动
}
```
> 命名注意：`Comparator` 与 Foundation 同名类型冲突，实现中定名 `RuleComparator`。

**RuleEngine 评估流程（每控制 tick 1 Hz）**
1. 取 `SensorStore` 当前快照；对每条 `enabled` 规则计算其 `metric` 值。
2. 结合该规则上一 tick 的「armed」状态与 `hysteresisCelsius` 判定**是否触发**（进入需越过阈值，退出需回落到 `阈值 − 迟滞`）。
3. 收集所有触发规则 → 按**目标 RPM 取最大**解析冲突 → 得到 `commandedRpm`。
4. 若无规则触发 → 返回 `nil`（交由 `ControlStore` 选择回落到「系统自动」或配置的 idle RPM）。
5. `commandedRpm` 经 `SafetyPolicy` 下限 clamp 后，由 `ControlStore` 经 XPC 下发 helper 写入 `F0Tg`。

**与现有策略的关系**：手动固定 RPM、传感器曲线、规则引擎三者为**互斥激活**的控制策略；曲线（`CurveEngine`）可视为「连续规则」，规则为「离散阈值动作」，二者共享同一安全下限与迟滞/斜率管线。

**调速依据温度（`TemperatureAggregation`，2026-11-10 新增）**
- 设置项：设置页「风扇调速 → 调速依据温度」：**最高温度**（默认）/ **平均温度**；持久化键 `FunFan.temperatureAggregation`，脏值回落 `peak`（更保守的一侧）。
- 口径定义集中在 `SensorSnapshot.controlCelsius(_:)`，两个口径的取值集合**刻意不同**：
  - `.peak` = **全部传感器**最大值。安全方向：SSD、电池里只要有一个真的烫了，也说明机箱在积热，漏掉一个就是漏掉一条告警；
  - `.average` = **CPU + GPU 全部探测点**的均温。调速方向：SSD/`other` 键数量多（M4 mini 上 SSD 29 个）而温度普遍偏低，混进平均会把「芯片均温」稀释十几度，风扇该提速时不提速；
  - 核心簇一个读数都没有时（机型特殊 / 唤醒那一帧）退回全量均温，而非返回 `nil`——返回 `nil` 会让风扇直接返还系统，负载中掉转速比口径偏差更糟。
- 生效面（同一个值喂给三处，避免「按均温调速、按最热画线」自相矛盾）：曲线插值输入、`SafetyPolicy` 动态下限锚点、`RuleEngine` 的 `dieCelsius`。**规则触发值不受影响**，仍由每条规则自己的 `subject` + `metric` 决定。
- **明写的代价**：选「平均温度」后安全下限也按均温计算，单个热点的瞬时高温不再单独把下限顶满。这是该选项的实际语义（想更保守就选最高温度），UI 副标题里已注明。
- 切换时清空两个引擎的迟滞/斜率状态：否则引擎会拿「上一轮峰值口径」的历史温度比对这一帧的均温，凭空多出十几度落差，迟滞判定失效。

**M3 实现与真机诊断（2026-10-30）**
- 已落地：`SafetyPolicy`（动态下限 + clamp + `isValidTarget` 二次校验）、`FanCurve`/`CurveEngine`（插值 + 迟滞 + 斜率）、`FanRule`/`RuleEngine`（迟滞 + 冲突取最大 + clamp）、`FanControlContract`（请求/应答/错误 payload + `FanControlTransport`）、`FanController`（本地预检 + 缓存上下限）。
- 真机只读演练：`F0Mn=1000`/`F0Mx=4900`，`die=73.6℃` → 安全下限 **2517**；曲线目标 3270（clamp 后不变）；规则「CPU≥60℃→60%」→ **2940**（= 4900×60%，高于下限）。
- **实测修正**：本机模式键为 **`F0Md`**（大写 d）——必须保留两候选探测；**`Ftst` 在本机不存在** → 该机型可直接写 `F0Tg`，无需解锁序列（与调研中「M3/M4 需 Ftst」的机型分布需在 M4 阶段按机型复测确认）。

### 4.2 电池/电量监控设计要点
- **可行性**：电池监控走 **IOKit 电源 API**（`IOPMPowerSource` / `IOPS*`），与 SMC 风扇/温度通道无关，**无需 root、无需 kext、沙箱友好**（实测 PowerID 在 `ENABLE_APP_SANDBOX=YES` 下仍可读取）。这是 Apple 文档化、跨代稳定的接口，比依赖逆向 SMC 键表的温度监控更可靠。
- **双数据源**：
  1. `IOPS*` 高层 API（`IOPSCopyPowerSourcesInfo` / `IOPSCopyPowerSourcesList` / `IOPSGetPowerSourceDescription`）：供电状态（`AC Power`/`Battery Power`）、电量比例、剩余/充满时间、`kIOPSPowerAdapterWattsKey` 适配器功率。
  2. `AppleSmartBattery` 注册表（`IOServiceMatching("AppleSmartBattery")` + `IORegistryEntryCreateCFProperty`）：原始容量（`CurrentCapacity`/`MaxCapacity`/`AppleRawMaxCapacity`/`DesignCapacity`）、`CycleCount`、`Amperage`(mA，放电为负)、`Voltage`(mV)、`Temperature`(厘摄氏度，÷100)、`IsCharging`/`ExternalConnected`/`FullyCharged`、`ChargerData`（充电电流/电压）。
- **Apple Silicon 键差异**：AS 容量键为 `AppleRawMaxCapacity` / `AppleRawCurrentCapacity`（Intel 为 `MaxCapacity`），读取时两者都尝试（先 raw 后回退）。
- **派生指标**：电量% = `current/max×100`；健康度 = `maxCapacity/designCapacity×100`；瞬时功率 W = `voltage(V) × amperage(A)`（符号表示充/放）。
- **事件驱动**：通过 `IOPSNotificationCreateRunLoopSource()` 注册回调，电源状态变化时触发读取，避免低效轮询；**无电池机型（Mac mini/Studio/Pro 台式机）优雅降级为空**。
- **与温度监控的关系**：电池温度既可由本模块从 `AppleSmartBattery.Temperature` 取得，也可由 `SensorCatalog` 的 `TB*` SMC 键取得（已在 §4.1 归类）；建议优先 SMC `TB*`（与其它温度统一展示），本模块不重复暴露。

---

## 5. Code Style（代码风格）
- **结构体对齐必须显式填充**：`SMCParamStruct` 严格 80 字节，所有整数字段小端，数据负载浮点小端；用 `#byteSize` 静态断言校验大小。
- **键探测优先，绝不写死**：机型差异大（如 `F0Md` vs `F0md`、`Ftst` 存在性），统一在 `SMCKey` 中按运行时 `GetKeyInfo` 探测。
- **读类型再解码**：每次读写前 `GetKeyInfo` 取 `dataType`，按 `flt`(小端 f32)/`fpe2`/`sp78`/`ioft`(小端 48.16，**按有符号解**)/`ui8` 解码。未知类型必须显式失败（`.decodeFailed`）并在诊断报告中列出键名+类型，绝不按长度猜。
- **写后确认**：写 `F0Tg` 后以观察 `F0Ac` 收敛判断生效，不依赖立即回读。
- **规则评估确定性**：`RuleEngine` 每次控制 tick（1 Hz）基于 `SensorStore` 快照做纯函数评估——输入（当前各传感器读数 + 规则集 + 上一 tick 状态）→ 输出（目标 RPM）。迟滞（hysteresis）状态作为引擎内部可变状态保存，但评估逻辑必须可单测、可重放（给定相同输入得相同输出）。
- **规则冲突解析（安全优先）**：当多条规则同时触发时，取**目标 RPM 最大者**（最激进散热优先），绝不做「取平均/取最小」；最终目标再经 `SafetyPolicy` 下限 clamp。默认仅「提高」语义下，所有规则动作 RPM 均 ≥ 安全下限。

```swift
// SMCParamStruct：显式填充确保 80 字节
struct SMCParamStruct {
    var key: UInt32 = 0          // 4
    var vers: (UInt8,UInt8,UInt8,UInt8,UInt8,UInt8) = (0,0,0,0,0,0) // 6
    var pLimitData: (UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                     UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8) = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0) // 16
    var keyInfo: (UInt32,UInt32,UInt8) = (0,0,0)  // 12: dataSize, dataType, attr
    var result: UInt8 = 0         // 1
    var status: UInt8 = 0         // 1
    var data8: UInt8 = 0          // 1  command byte
    var data32: UInt32 = 0        // 4
    var bytes: (UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8) = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0) // 32
    // 总计 = 4+6+16+12+1+1+1+4+32 = 77 → 补齐到 80
}
// 注：实际上下文需按 smc.h 对齐补齐；以静态 assert 锁定 sizeof == 80。
```

- 命名：类型 `UpperCamel`，函数/变量 `lowerCamel`，常量 `lowerCamel`；错误类以 `Error` 结尾。
- 错误处理：自定义枚举 `FunFanError`（如 `.smcAccessDenied`、`.thermalManagerRefused`、`.keyNotFound`），helper 返回规范化错误，GUI 映射为友好中文提示（4xx 类不重试、5xx 类最多重试 3 次）。

---

## 6. Testing Strategy（测试策略）
- **框架**：XCTest（Xcode 原生）。
- **位置**：`Tests/FunFanCoreTests/`。
- **单测（快速、不依赖硬件）**：
  - `CodecsTests`：`flt`/`fpe2`/`ui8` 编解码往返；大小端。`IOFTCodecTests`：真机 `ioft` 字节、48.16 精度、哨兵值判负、写入拒绝。
  - `CurveEngineTests`：曲线插值、安全下限（`commanded = max(curve(temp), floor(dieTemp))`）、迟滞、斜率限制。
  - `RuleEngineTests`：规则触发/不触发（阈值边界）、迟滞进入/退出、多规则冲突取最大 RPM、与 `SafetyPolicy` 联动的下限 clamp、规则全不触发时回落到系统自动或 idle RPM。
  - `SensorCatalogTests`：给定模拟 `T*` 键集，验证语义归类（CPU/GPU/SSD/环境）与动态枚举；未知键归为 `other`。
  - `SMCKeyEnumerationTests`：全键枚举（按索引取键、零/负计数、单索引失败跳过不中断）、温度键筛选与去重排序、未知代系键仍能归类。
  - `SensorGranularityTests`：回退键名 = 真实键名（不编造「Core」类标签）；簇均温仍包含全部传感器；`SensorSnapshot.coreGroups()` 列出簇内全部真实探测点，数量等于真实键数。
  - `ChipTopologyTests`：注入假 probe 验证 `totalCPUCores` 计算；真实探针在 macOS 下从 sysctl/IORegistry 读到非 nil 且核心数自洽。
  - `SMCTemperatureProviderTests` / `TemperatureProviderScopeTests`：键表缓存（只枚举一次）、合理性过滤、单键失败跳过、枚举失败下周期重试、默认排除 `.other`。
  - `SamplingPolicyTests`：三档间隔有序、到期判定、时钟回拨/长挂起立即采样、空闲 CPU 预算断言。
  - `BatteryStoreTests`：模拟 `AppleSmartBattery` 注册表与 `IOPS*` 快照，验证电量%/健康度/功率计算、AS/Intel 容量键回退（`AppleRawMaxCapacity`→`MaxCapacity`）、无电池机型降级、**台式机全 0 属性不得误判为有电池**、温度单位启发式。
  - `SMCParamStructTests`：静态断言 `MemoryLayout<SMCParamStruct>.size == 80`。
  - `IPCRoundTripTests`：XPC 协议序列化往返（用模拟 helper），含规则集序列化。
  - `LidDetectionTests`：合盖规则（`fanctl doctor` 自检返回键名而非空白）。
- **集成测试（需真机 + root + Apple Silicon）**：
  - 解锁序列在 M1/M2/M3/M4/M5 上分别验证；
  - 睡眠/唤醒后看门狗重申请；退出恢复自动；冲突检测。
- **覆盖率**：核心 `FunFanCore` 单测覆盖率 ≥ 80%；集成测试标记为 `@Test` 且仅在真机 CI/手动执行。
- **原则**：单测 mock SMC 层；集成测试用真实硬件，不 mock 服务层。

---

## 7. Boundaries（边界）
- **Always（始终）**：
  - 写操作只经 root helper；GUI 永不持 root。
  - 目标转速 clamp 到 `F0Mn–F0Mx`；**绝不写 `F0Mn`/`F0Mx`**；**绝不设 0 RPM**。
  - **规则引擎 / 曲线输出必须经 `SafetyPolicy` 下限 clamp**：任何策略（手动 RPM / 曲线 / 规则）都只「提高」、绝不把转速压到系统默认下限以下；下限基于核心温度动态计算并即时响应。
  - 退出/崩溃/`SIGTERM`/合盖/睡眠都必须返还系统自动。
  - **宿主消失自退场（T20）同样安全优先**：daemon 确认宿主 App 消失后自毁前，第一步必须是返还风扇；自毁仅在**连续多次**确认缺席后执行（防外置卷瞬时卸载/更新换包误判），并且不允许自毁逻辑写入任何持久化状态。
  - **用户策略只由用户改写**：`strategy` / `fixedRpm` 是意图，租约与 XPC 是运行时状态。心跳失败、helper 重启、超时、睡眠唤醒等**故障路径一律不得写回持久化的策略**，只允许「交还系统控制 + 有界退避重连」。把一次瞬时故障落盘成「自动」，用户下次重启就再也回不来（M9）。
  - 提交前跑 `make test`；键名/机型差异运行时探测。
- **Ask first（先确认再做）**：
  - 引入第三方依赖（当前计划为零依赖，新增需评审）。
  - 调整部署目标 macOS 版本。
  - 改变签名/公证流程或 helper 安装方式。
  - 将规则/曲线动作允许「低于系统默认下限」（降噪优先，安全风险——本 Spec 默认禁止）。
- **Never（绝不）**：
  - 不把风扇锁死在极低转速导致过热。
  - 不硬编码机型键名/范围。
  - 不提交真实证书/密钥/`.env`；不在代码中泄露。
  - 不绕过系统热保护（macOS 自身的降频/紧急关机仍生效）。
  - 不与其他控制器争抢 SMC 键（检测到冲突即拒绝接管）。

---

## 8. Success Criteria（成功标准，可测试）
1. **温度监控**：在 Apple Silicon 上无需 root 即可动态枚举并读取 CPU/GPU/SSD/环境等主要硬件温度的实时值（含滑动均值），UI 正确分类展示。
2. **转速监控**：无需 root 即可读取全部风扇实际/目标/最小/最大转速，UI 正确展示。
3. **电量监控**：无需 root 经 IOKit 电源 API 读取电量%、健康度、循环次数、充放电功率与 AC/充电状态，UI 正确展示；台式机（无电池）优雅降级；电量%/健康度计算正确。
4. **控制（M1/M2/M5）**：经 helper 写入目标 RPM 后，`F0Ac` 在数秒内收敛到目标；模式成功切手动。
5. **控制（M3/M4）**：首次接管经历 `Ftst` 解锁（约 3–6 s），成功后可持续调速；`Ftst` 在持有期间保持。
6. **规则自动调速**：配置「CPU ≥ 70℃ → 3000 RPM」类规则后，温度越过阈值时风扇**自动**提速到目标并保持；温度回落后按迟滞平滑回落或返还系统自动；无规则/温度未达阈值时不强制接管。
7. **安全**：任何曲线/手动/规则值都被安全下限限制（只能更快不能更慢于温度下限）；多规则冲突取最大 RPM；不可设 0 RPM；不可低于系统最小。
8. **健壮性**：睡眠/唤醒、合盖后自动重申请并保持期望状态；应用退出/崩溃后风扇回到系统自动；**租约/XPC 中断后按有界退避自动重连，且用户策略不被改写**（重启后仍是上次选的策略，除非用户自己改）；单实例锁生效。
9. **无冲突**：启动检测到其他风扇控制器持有时，友好提示并拒绝接管，仅恢复自身动过的风扇。
10. **轻量**：菜单栏常驻内存占用低（守护进程 + GUI 合计量级几十 MB）；**采样 CPU 占用可量化**——全量单帧 ≤ 22 ms（M4 实测 21.5 ms），两层采样快帧更低（`FunFanProbe --tier` 实测），空闲态 < 0.5% 单核、显示态 < 1.5% 单核（`SamplingPolicyTests` 已固化为断言）。
11. **分发**：`make build` 产出可运行 app；Developer ID 签名 + 公证后无 Gatekeeper 拦截；helper 经一次授权安装。
12. **兼容最新系统**：在调研时的最新 macOS（Sequoia/Tahoe 等）上通过上述 1–11；大版本升级后复测解锁序列与规则行为。

---

## 9. Open Questions（未决，待产品/负责人最终拍板）
| # | 问题 | 当前默认（本次已据需求更新） |
|---|---|---|
| Q1 | 是否获取付费 Developer ID 用于正式发布？ | 假设可获取；开发期用本地签名 |
| Q2 | 是否兼容 Intel Mac？ | v1 仅 Apple Silicon；`fpe2` 编解码保留但不测 |
| Q3 | 控制是否允许「低于系统默认」？ | v1 **仅提高/曲线/规则**，不允许压低（已据「温度→提速」需求默认） |
| Q4 | 是否需要规则/日志/告警（TG Pro 式）？ | **v1 已纳入规则引擎（温度阈值自动调速）**；CSV 日志与邮件/弹窗告警仍留后续版本 |
| Q5 | 设置窗口 vs 仅 Popover？ | v1 以 Popover 为主 + 轻量设置/规则窗口 |
| Q6 | 规则作用域与数据源？ | v1 规则仅基于**温度**传感器（CPU/GPU/SSD/环境任选）；不接入功率/电流等（后续可扩展） |
| Q7 | 规则触发后的回落行为？ | 温度低于阈值（减迟滞后）即**返还系统自动**（默认）；也可配置「维持 idle RPM」 |

---

## 10. 下一步（Plan / Tasks 输入）
本 Spec 通过后，进入 Phase 2（Plan）制定实现计划、Phase 3（Tasks）拆任务、Phase 4（Implement）按模块落地：
1. `FunFanCore/SMC` —— 硬件抽象层（键探测、编解码、**`T*` 温度动态枚举 + 语义归类 `SensorCatalog`**、只读监控）。
2. `FunFanCore/Control` —— 解锁序列、曲线引擎、**`RuleEngine` 规则引擎**、安全策略。
3. `FunFanHelper` —— `SMAppService` root daemon + XPC（含签名校验、TTL）。
4. `FunFan` GUI —— 菜单栏 + Popover + **温度监控展示** + **`RulesView` 规则编辑** + 设置窗口 + 睡眠/合盖监听。
5. 打包加固 —— 签名 + 公证 + 冲突检测 + `doctor` 自检 + 免责声明。
