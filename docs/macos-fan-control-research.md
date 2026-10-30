# macOS 风扇控制软件开发调研文档

> 项目代号：**FunFan**
> 目标：开发一款**简洁、轻量、带图形界面**的 macOS 风扇控制工具，完整支持 **Apple M 系芯片（Apple Silicon）** 与**最新 macOS 系统**。
> 文档性质：技术可行性调研 / 方案选型依据
> 调研日期：2026-10-30

---

## 0. 调研说明

### 0.1 调研目的
在动手编码前，先澄清“在 Apple 芯片 + 最新 macOS 上做风扇控制”这件事**是否可行、用什么技术、有哪些坑、最优路径是什么**，避免盲目开工导致返工或触碰系统安全边界。

### 0.2 调研范围
- 现有开源/商业风扇控制软件与方案（实现原理、技术栈、Apple Silicon 适配情况）。
- SMC（System Management Controller）访问原理、读写协议、关键键名与数据编解码。
- 系统权限与硬件访问限制（kext / DriverKit / 用户态 IOKit / root 提权）。
- 轻量 GUI 架构思路（菜单栏常驻 + SwiftUI）。
- 各方案优缺点对比与推荐实现路径。

### 0.3 调研假设（如与预期不符请告知）
1. 交付形态为**可分发运行的桌面 GUI 应用**（非仅命令行/研究原型），且不依赖用户关闭系统安全（如 SIP）。
2. 目标平台为 **macOS 13 (Ventura) 及以上**（覆盖最新版本 Tahoe/Sequoia 等），Apple Silicon 为主，Intel 作为可选兼容。
3. 控制语义以**“提高/按曲线调速/按温度规则自动调速、必要时返还系统自动”**为主，不追求把风扇锁死在极低转速（安全风险）；本项目的核心诉求即**监控硬件温度并据规则自动调速**。
4. 不在 App Store 上架（因 SMC 直访违反沙箱，见 §4）。
5. 文档中的“控制”指对**带风扇机型**（MacBook Pro、Mac Studio、Mac mini 等）；MacBook Air 无风扇，仅支持温度与电量监测。

---

## 1. 背景与核心挑战

### 1.1 为什么需要风扇控制
- Apple Silicon 的默认散热策略偏“静音优先”，在持续高负载（编译、渲染、虚拟机、外接高分辨率显示器）下风扇介入偏晚，导致温度堆积、CPU/GPU 降频（kernel_task 占用飙升）。
- 用户诉求通常是：**提前/主动提速以压制温度、换取稳定性能**，或在特定场景（如录音、会议）下接受略高温度以降噪。
- 官方不提供任何用户态风扇调速入口，只能第三方实现。

### 1.2 核心难点（一句话版）
> Apple 芯片把 SMC 集成进 SoC，并用 `thermalmonitord` 守护进程把风扇锁在“系统模式”；第三方要做控制，必须在**用户态经 IOKit 访问 AppleSMC**，并在 M3/M4 上**绕过/协商掉 thermalmonitord 的回收逻辑**（社区称之为 Ftst 解锁），同时以 **root 特权**写入——而这一切又不能用 kext、也不能上架 App Store。

---

## 2. Apple Silicon 与 SMC 架构

### 2.1 Intel vs Apple Silicon：SMC 的位置变了
| 维度 | Intel Mac | Apple Silicon / T2 Mac |
|---|---|---|
| SMC 实体 | 主板上独立 SMC 芯片 | 集成进 T2 芯片 / M 系 SoC 内部（固件实现） |
| 用户态访问入口 | `AppleSMC.kext` IOKit 服务 | 同样的 `AppleSMC` IOKit 服务（Apple 保留了用户态 shim） |
| 风扇数据编码 | 整数 `fpe2` / `sp78`（大端定点） | IEEE-754 浮点 `flt`（**小端**） |
| 模式键大小写 | `F0Md` | M1–M4 多为 `F0Md`；**M5 变为 `F0md`**（需运行时探测） |
| 手动控制门槛 | 写 `FS!` 强制位域 | 写模式键 +（M3/M4）`Ftst` 解锁 |

关键点：**Apple 在 Apple Silicon 上保留了“用户态经 IOKit 读写 AppleSMC”的接口**，这是第三方工具能在不装 kext 的前提下工作的根本原因。

### 2.2 用户态访问协议（核心）
通过 `IOKit` 打开 `AppleSMC` 服务，用 `IOConnectCallStructMethod`（selector = 2）做结构化读写：

```c
io_service_t service = IOServiceGetMatchingService(
    kIOMasterPortDefault, IOServiceMatching("AppleSMC"));
io_connect_t conn;
IOServiceOpen(service, mach_task_self(), 0, &conn);

SMCParamStruct input = {0}, output = {0};
size_t out_size = sizeof(SMCParamStruct);   // 80 字节（含对齐填充）
input.key = key_fourcc;                     // 四字符键，如 'F0Tg' 大端
input.data8 = kSMCReadKey;                 // 5=读 6=写 9=取键信息
IOConnectCallStructMethod(conn, 2, &input, sizeof(input), &output, &out_size);
```

- **结构体大小必须严格 80 字节**（不同实现含填充可能到 80–90，但内核期望固定布局）。Swift 直接定义嵌套结构体易因内存对齐偏差几字节导致调用静默失败，这是社区踩过的最大坑之一。
- 读写流程：**先 `kSMCGetKeyInfo`(9) 取键的 size+type → 再 `kSMCReadKey`(5) / `kSMCWriteKey`(6)**。
- 务必**先读键的 data type 再解码**：Apple Silicon 上温度与风扇 RPM 多为 `flt`（小端 f32）；Intel 上才是 `fpe2`/`sp78`。但同一台 Apple Silicon 上**并非只有 `flt`**——实测 Mac mini M4 的 180 个温度键里有 6 个是 `ioft`（8 字节小端 48.16 定点），只按 `flt` 解会静默丢掉这批传感器。

| 类型码 | 长度 | 解码方式 | 典型用途 |
|---|---|---|---|
| `flt ` | 4 | 小端 IEEE-754 f32 | 温度、风扇 RPM |
| `fpe2` | 2 | 大端定点 ÷ 4 | Intel 风扇 RPM |
| `sp78` | 2 | 大端有符号 ÷ 256 | Intel 温度 |
| `ioft` | 8 | **小端 48.16 定点 ÷ 65536，按有符号解** | Apple Silicon 探针温度（`TR0Z`/`TR1d`…） |
| `ui8 `/`ui16`/`ui32` | 1/2/4 | 大端无符号 | 风扇数量、模式键 |

### 2.3 与风扇/温度相关的关键 SMC 键
| 键 | 类型 | 含义 |
|---|---|---|
| `FNum` | ui8 | 风扇数量 |
| `F0Ac` / `F1Ac` | flt | 风扇实际转速（只读，用于“确认生效”） |
| `F0Tg` / `F1Tg` | flt | 风扇目标转速（**可写**） |
| `F0Mn` / `F0Mx` | flt | 固件推荐的最小/最大转速（**只读取，绝不写入**） |
| `F0Md` / `F0md` | ui8 | 风扇模式键：自动 / 手动（大小写因机型而异，需探测） |
| `Ftst` | ui8 | 诊断/测试标志（M1–M4）；写 1 可抑制 `thermalmonitord` 回收 |
| `FS!` | flag | Intel 专用强制位域 |
| `TC0P` / `Tp01` / `Tf26` … | flt | CPU/GPU/各部件温度（`T*` 命名空间，机型差异大） |

> 注意：`F0Tg` 写入后**立即回读可能仍是旧值**（寄存器最终一致），应以观察 `F0Ac` 收敛来判断控制是否真正生效。

---

## 3. 实现原理：从“读取”到“控制”

### 3.1 读取（监控）：无需 root
- 任意进程都能**读** SMC 键，因此温度/转速监控不需要权限。
- 也可读取系统自带 `powermetrics`（需 `sudo` 才全量，但部分传感器用户态 SMC 即可取）。
- 开源只读范例：**Fanny**（菜单栏/通知中心小组件，纯展示）、**Stats**（开源监控，含风扇读数）。

### 3.2 控制：需要 root + 模式切换
控制的核心三步：
1. 将模式键切换为**手动**（如 `F0Md = 1`/手动值）——这是“接管”风扇的前提。
2. 将目标转速写入 `F0Tg`（必须 clamp 在 `F0Mn`–`F0Mx` 之间，且**永远不写** `F0Mn`/`F0Mx`）。
3. 退出/出错时把模式交还“自动”，让 macOS 重新接管。

### 3.3 最大障碍：thermalmonitord 的回收
- macOS 的 `thermalmonitord` 守护进程会主动把风扇维持在“系统模式”（常见表述为 mode 3 / system）。
- **M1/M2/M5（及 Intel）**：直接写模式键为手动通常即可生效。
- **M3/M4**：固件会**拒绝**手动模式写入，返回 SMC 错误 `0x82`（部分情境 `0x92`），因为 `thermalmonitord` 正在持有风扇。

### 3.4 社区解锁序列（本调研最重要的技术结论）
多个 2024–2026 年的开源/研究项目（见 §5）独立验证了同一套“Ftst 解锁”流程：

```
尝试直接写 模式键 = 手动
  ├─ 成功 → 写入目标转速 F0Tg → 完成
  └─ 被拒（SMC 0x82，thermalmonitord 持有）
        → 写 Ftst = 1            （抑制 thermalmonitord 回收逻辑）
        → 等待 ~3 秒让热管理“让出”
        → 重试模式写入（最多约 300×100ms）
        → 成功后写 F0Tg 目标转速
        → 持有手动控制期间 Ftst 必须保持为 1
```

关键工程细节（来自实际项目经验）：
- **睡眠/唤醒、合盖**会把固件中的 `Ftst` 清零，系统重新夺回风扇。因此**不能一次性写入就完事**，必须在控制线程里设**看门狗**：每次轮询发现“期望状态 ≠ 硬件状态”就自动重跑解锁序列。
- **M5** 上模式键大小写变为 `F0md`，且 `Ftst` 可能**不存在**——这些键都必须**运行时探测**而非写死。
- **退出恢复**：正常退出、异常崩溃（Drop guard / `catch_unwind`）、收到 `SIGTERM` 都要把风扇返还系统；仅当用户显式选择“保留手动”时才跳过。
- **安全下限（floor）**：曲线引擎计算 `commanded = max(用户曲线(temp), 安全下限(核心温度))`，即曲线只能让风扇**更快**、不能更慢于温度驱动的下限；下限不施加斜率限制、即时响应。
- **迟滞（hysteresis）与斜率限制（slew）**：避免温度在阈值边缘时风扇频繁抖动（flapping），以及转速突变带来的噪音。
- **用户态只读、root 才写**：SMC 固件本身按键做权限校验，写操作强制要求 root。

---

## 3.5 温度监控可行性（专题补充，2026-10-30 追加）

> 本节针对「监控系统硬件温度」做专项可行性调研，是对 §3.1 只读监控的深化。

### 3.5.1 结论：完全可行，且与风扇读取同源、且无需 root
- 温度读取与风扇读取走**完全相同的 AppleSMC IOKit 路径**（80 字节 `SMCParamStruct`，selector=2，先 `GetKeyInfo`(9) 取 type 再 `ReadKey`(5)）。
- **读取是只读操作，任意非特权进程即可执行，不需要 root、不需要 kext、不需要 entitlements**。多个独立项目（go-smc、macmon、FanGlass、SiliconScope、swift-soc-metrics、Stats、iStat Menus）均在非特权进程内成功读到温度。
- **关键推论**：FunFan 的 `SensorStore` 可直接在 **GUI 进程内**轮询温度，**完全不需要经 root helper / XPC**；root helper 仅用于风扇**写入**。这进一步降低了监控路径的复杂度与权限面。
- 无风扇机型（M1/M2 MacBook Air 等）无 `F*Ac` 键，但温度键仍存在——温度监控对这些机型完全有效（与 §0.3 #5 一致）。

### 3.5.2 核心难点是「键名逐代变化」，而非权限
- 温度键是近乎任意的 4 字符 FourCC，**每一代芯片键名都变**，且同代不同档位（Pro/Max/Ultra）暴露的键集合也不同，甚至同一 FourCC 在不同 SoC 含义不同。
- 已知各代 CPU 核心温度键前缀示例（来自 Stats / SiliconScope / swift-soc-metrics / fand 实测）：
  - **M1**：E-core `Tp09`/`Tp0T`，P-core `Tp01`/`Tp05`/`Tp0D`…，GPU `Tg05`
  - **M2**：E-core `Tp1h`/`Tp1t`，P-core `Tp01`/`Tp05`…，GPU `Tg0f`/`Tg0j`
  - **M3**：E-core `Te05`/`Te0L`，P-core `Tf04`/`Tf09`/`Tf0A`…，GPU `Tf14`/`Tf18`
  - **M4**：E-core `Te05`/`Te0H`，P-core `Tp01`/`Tp05`…，GPU `Tg0G`/`Tg1U`
  - **M5**：新增 Super 簇 `Tp0O`/`Tp0R`，GPU `Tg0*`/`Tg1*`
- 因此「全键扫描再猜哪个是几号核」不可靠；业界标准做法是**为每代维护一张「键→友好名→类别」的密钥表**，启动时用 `sysctl` 读 CPU 品牌串（如 `Apple M1 Max`）识别代系，再直接按键读值。表中没有的键（某 Max 不存在的 Memory 传感器）读回为空即跳过。
- 分类规则（前缀映射）：`Tp*`/`Tf*`/`Te*`→CPU（细分 E/P/Super 簇），`Tg*`→GPU，`Tm*`→Memory，`TB*`→Battery，`TA*`→环境；未匹配归 `other`。

### 3.5.3 三级数据源回退（最佳实践，来自 SiliconScope / swift-soc-metrics）
1. **首选**：手工维护的逐代 SMC 密钥表（快、命名准）。
2. **回退 HID**：当某些 M1/M2 或 macOS 版本 SMC 键被限制时，走 `IOHIDEventSystemClient`（PrimaryUsagePage=`0xff00`, PrimaryUsage=`0x5`）读取热传感器（iStat 同款来源），得到 die/SoC/NAND/电池等原始 PMU 标签。
3. **兜底 SMC 全 `T*` 扫描**：仅在以上都失败时使用，命名可信度低。

### 3.5.4 其它要点
- **数据校验**：SMC 温度值可能异常，应做合理性过滤（如丢弃 (4,132)℃ 之外的值）；睡眠切换期间读偶发 `kIOReturnTimeout`，应 50 ms 后重试一次。
- **不要指望 `powermetrics` / `IOReport` 取温度**：Apple Silicon 上 `powermetrics --samplers smc` 不返回具体摄氏度（仅 `thermal level` 0–4 状态码）；IOReport 的温度通道在 M5 缺失、M4 读 0——温度应仍以 SMC 为准。
- **实测精度可信**：swift-soc-metrics 在 M5 Max / M4 Max 上以 SMC 读取的 GPU 裸温随负载变化（44→72℃ / 35→54℃）与 Metal burn 吻合。

---

## 3.6 电池/电量监控可行性（专题补充，2026-10-30 追加）

> 本节针对「监控电量/电池」做专项可行性调研。

### 3.6.1 结论：完全可行，且比温度监控更稳、更省权限
- 电池监控走 **IOKit 电源 API**（`IOPMPowerSource` / `IOPS*`），与 SMC 风扇/温度通道**无关**，**无需 root、无需 kext、沙箱友好**。实测 PowerID 在 `ENABLE_APP_SANDBOX = YES` 下仍可读取电池。这是 Apple 文档化、跨代稳定的接口，比依赖逆向 SMC 键表的温度监控更可靠。

### 3.6.2 双数据源
1. **`IOPS*` 高层 API**：`IOPSCopyPowerSourcesInfo` / `IOPSCopyPowerSourcesList` / `IOPSGetPowerSourceDescription` → 供电状态（`AC Power`/`Battery Power`）、电量比例、剩余/充满时间、`kIOPSPowerAdapterWattsKey` 适配器功率。
2. **`AppleSmartBattery` 注册表**：`IOServiceMatching("AppleSmartBattery")` + `IORegistryEntryCreateCFProperty` → 原始容量（`CurrentCapacity`/`MaxCapacity`/`AppleRawMaxCapacity`/`DesignCapacity`）、`CycleCount`、`Amperage`(mA，放电为负)、`Voltage`(mV)、`Temperature`(厘摄氏度，÷100)、`IsCharging`/`ExternalConnected`/`FullyCharged`、`ChargerData`（充电电流/电压）。Stats 的电池模块两者皆用。

### 3.6.3 要点
- **Apple Silicon 键差异**：AS 容量键为 `AppleRawMaxCapacity` / `AppleRawCurrentCapacity`（Intel 为 `MaxCapacity`），读取时两者都尝试。
- **派生指标**：电量% = `current/max×100`；健康度 = `maxCapacity/designCapacity×100`；瞬时功率 W = `voltage(V) × amperage(A)`（符号表充/放）。
- **事件驱动**：`IOPSNotificationCreateRunLoopSource()` 注册回调，电源状态变化时才读取，避免轮询。
- **降级**：台式机（Mac mini/Studio/Pro）无电池，应优雅降级为空。

---

## 4. 系统权限与硬件访问限制

### 4.1 第三方 kext：在 Apple Silicon 上基本不可行
- Apple Silicon 加载第三方内核扩展需进入“降低安全性（Reduced Security）”启动模式并 `csrutil enable --without kext`。
- 这对普通分发 unacceptable：用户需关机进恢复模式操作，且 Apple 已明确把 kext 路线边缘化。
- 结论：**FunFan 不应依赖 kext**。用户态 IOKit 才是可分发路径。

### 4.2 DriverKit：无官方授权，难以加载风扇类控制
- DriverKit 仅覆盖部分设备类，Apple 未为“风扇/SMC 控制”开放对应授权；社区实践表明即便重构也无法获得必要 I/O 权限。
- 结论：**放弃 DriverKit 路线**。

### 4.3 用户态 IOKit + 特权辅助进程（推荐路径）
- **非特权 GUI**：只读监控 + 发起控制请求（通过 XPC 与 helper 通信）。
- **特权辅助进程（Privileged Helper Daemon）**：以 root 运行，持有 AppleSMC 连接并执行写入。
  - 现代 API：**`SMAppService.daemon`（macOS 13+）**——helper 的 plist 与二进制放在 app bundle 内（`Contents/Library/LaunchDaemons`），由 app 注册，用户在“系统设置 → 登录项与扩展”中授权一次。
  - 旧 API：`SMJobBless`（macOS 13 起废弃，但可兼容老系统）。
  - 安全要点：helper 对每条 XPC 连接施加**代码签名要求**（`setCodeSigningRequirement`，信任“签了我的人 + 我的 bundle id”），杜绝任意进程调用。
- 一次性 sudo（如 Rust CLI / 研究型 TUI）：实现简单，但每次运行都要密码、体验差，**不适合 GUI 产品**。

### 4.4 代码签名与公证
- 因店外分发，必须经 **Developer ID 证书签名 + 公证（notarization）**，否则 Gatekeeper 会拦截。
- 使用 privileged helper 时，**helper 自身通常需可被系统验证的 Developer ID 签名**。部分参考项目（如 macos-smc-fan）明确指出：**需要付费 Apple Developer Program 账号**才能签发可安装的特权 helper（免费/自签名不被支持）。
- 因此 FunFan 若要正式发布，需预留**付费开发者账号 + 证书 + 公证流水线**的成本。

### 4.5 App Store：不行
- 直接访问 SMC 违反 App 沙箱要求，Apple 明确将其视为安全边界。**所有**风扇控制类 App（Macs Fan Control、TG Pro、iStat Menus 等）均店外分发。
- FunFan 同样**不可上架 App Store**。

### 4.6 系统版本风险
- Sonoma 14.7 / Sequoia 起固件对风扇管理更严格；大版本升级**可能破坏控制机制**（如解锁失效、helper 需重装）。
- 缓解：每个大版本发布后复测解锁序列；升级后提示重装 helper；对未知机器做“键探测 + 能力协商”。

### 4.7 多控制器冲突
- 同时运行两个风扇控制器（如 FunFan + Macs Fan Control + TG Pro）会争抢同一组 SMC 键，互相覆盖。
- 缓解：启动时检测“是否已有其他控制器持有手动模式”，若有则**拒绝接管并提示用户先退出其他工具**；只恢复“自己动过的”风扇。

---

## 5. 现有方案调研与对比

### 5.1 商业/闭源（作为能力参考）
| 软件 | 定位 | Apple Silicon | 控制机制 | 备注 |
|---|---|---|---|---|
| **Macs Fan Control**（CrystalIDEA） | 监控+控制，免费/Pro | ✅ M1–M5 | 私有 helper 写 SMC | 不上架；Sonoma/Sequoia 后曾失效，1.5.18(2025-06) 修复；M3/M4 Pro/Max 低温下风扇被固件关闭时无法覆盖 |
| **TG Pro**（Tunabelly） | 监控+规则+控制 | ✅ 到 M5 | `/Library/PrivilegedHelperTools/...TGFanHelper` 守护进程 | 一次性买断；Auto Boost 规则、CSV 日志、告警；T2/AS 上模式改为 Max/Auto Max |
| **iStat Menus**（Bjango） | 系统监控（含风扇面板） | ✅ | 独立 helper | 监控为主，风扇仅“自动/曲线/手动（只能提高）” |

### 5.2 开源 / 研究型（实现原理参考）
| 项目 | 语言/形态 | Apple Silicon 控制 | 权限机制 | 优缺点 |
|---|---|---|---|---|
| **smcFanControl** | Obj-C / 旧 GUI | ❌ 仅 Intel（2016 后停滞） | 旧 kext/SMC | 历史鼻祖；理念“只提高最低转速”；对 AS 不支持，不宜作为基础 |
| **SMCKit**（beltex 等 fork） | Swift 库 | 标注 Intel only | 用户态 IOKit | 协议参考好，但默认按 Intel `fpe2` 编解码，需改造适配 AS 浮点 |
| **Fanny** | Swift 菜单栏/Widget | 只读（无控制） | 用户态读取 | 极佳的“轻量只读 UI”范本 |
| **Stats** | Swift 监控 | 读数；风扇控制参考较少 | 用户态 | SMC.swift 编解码实现被多个 AS 项目引用 |
| **agoodkind/macos-smc-fan** | Swift + 特权 helper | ✅ M1–M5（研究+可用实现） | SMAppService 安装 root helper | **首篇系统记录 macOS 上手动控风的研究**；Ftst 解锁机制发源；要求付费 Developer ID |
| **raminsharifi/MacFanControl** | Rust TUI | ✅ M1–M4，无 kext/无 daemon | sudo 一次性提权 | Rust FFI 实现 80 字节协议；完整解锁序列；CLI/TUI，非 GUI |
| **adilkairolla/fan-control** | Swift 菜单栏 App | ✅ M5 Max，macOS 26.5 | launchd 守护 | 大量 SMC 实战笔记（键大小写、编解码、睡眠返还）；曲线+安全下限+迟滞+斜率 |
| **june4432/thermo-control-mcp** | Swift daemon + MCP | ✅ M1–M5（M3/M4 走 Ftst） | root daemon + Unix socket（root:admin 0660） | 把控制暴露为 MCP 工具；动态枚举 SMC 全部 `T*` 传感器（M4 Pro 上 291 个） |
| **rachitdev/mac-mini-fan-driver** | Rust LaunchDaemon + CLI | ✅ M4 Pro | root daemon | 零运行时依赖（仅链接系统 IOKit）；配置驱动曲线、看门狗重申请、安全契约完善 |
| **yolo-labz/fand** | （含 SMC-PROTOCOL 参考文档） | ✅ | 用户态 | 协议参考文档质量高，汇总了 smcFanControl/SMCKit/Stats/Asahi 的键与编解码 |

### 5.3 关键启示
1. **可行性已被多个独立项目证实**：Apple Silicon 上“用户态 IOKit + Ftst 解锁 + root helper”是可行且可维护的。
2. **协议实现不复杂但坑多**：80 字节结构体对齐、运行时读类型再解码、`F0Md`/`F0md` 与 `Ftst` 存在性探测、写后读 `F0Ac` 确认——这些都已被前人踩平，应**复用/参考**而非从零造轮子。
3. **Swift 生态成熟**：SMCKit、Stats、fan-control 提供了可直接借鉴的 Swift 编解码与菜单栏 UI 范本。
4. **安全机制是分水岭**：成功的项目都有“安全下限、迟滞、斜率、睡眠/退出恢复、单实例锁、冲突检测”。

---

## 6. 轻量 GUI 架构思路

### 6.1 形态：菜单栏常驻 + 弹出面板（最契合“简洁轻量”）
- 应用以 **`.accessory` / `LSUIElement`** 方式运行：无 Dock 图标，仅有菜单栏图标。
- 点击图标弹出 **SwiftUI 面板（NSPopover / 可键盘聚焦的 NSPanel）**，展示实时转速/温度、快捷调速、曲线与预设。
- 可选：轻量设置窗口（传感器选择、曲线编辑、开机自启、关于/免责）。
- 参照：Fanny（只读菜单栏）、iStat Menus、TG Pro、fan-control 均采用此形态。

### 6.2 技术选型
- **Swift + SwiftUI**（原生、包体小、现代、与系统外观一致）；避免 Electron（体积/内存/电量代价大，不符“轻量”）。
- 状态管理：`ObservableObject` / `@Published` Store（单例或可注入）。
- 响应式轮询：**控制线程 1 Hz**（控温循环），**显示刷新 2 Hz**（UI 读快照）；用 Combine 或 async/await 定时器。
- AppKit 桥接：`NSStatusItem` 承载 `NSHostingView`/`NSPopover`，必要时用 `NSPanel`（`canBecomeKey=true`）解决弹出层键盘焦点问题。

### 6.3 分层架构（与专家推荐的“按功能 + 三层”一致）
```
┌─────────────────────────────────────────────┐
│  UI 层（SwiftUI 菜单栏 + Popover + 设置窗口） │  ← 无业务逻辑、无 root
├─────────────────────────────────────────────┤
│  服务层 FanController / CurveEngine           │  ← 曲线、安全下限、迟滞、斜率、状态机
├─────────────────────────────────────────────┤
│  硬件抽象 SMCService（仓储层）                │  ← 键枚举、编解码、解锁序列、监控
├─────────────────────────────────────────────┤
│  Privileged Helper（root daemon，XPC）        │  ← 唯一执行 SMC 写入的进程
└─────────────────────────────────────────────┘
```
- **GUI 永远不持有 root**；所有写操作经 XPC 交给 helper。
- **SMCService 可单测**：把“硬编码机型”改为“运行时键探测 + 能力协商”，便于在模拟数据下测试曲线/安全逻辑（参考 fan-control 的 103 项测试）。

### 6.4 资源与体验
- 常驻内存应极低（菜单栏 + 后台 daemon 合计几十 MB 级）；轮询频率克制。
- 配置持久化：曲线/规则存 `~/Library/Application Support/FunFan/` 或 `~/.config/funfan/`；首选项用 `UserDefaults`。
- 单实例锁：避免重复启动抢夺 SMC 状态。
- 分发：Developer ID 签名 + 公证；可选 Sparkle 自更新；可选 Homebrew cask。

---

## 7. 方案对比与优缺点（汇总）

### 7.1 硬件访问路线
| 路线 | 可行性 | 分发友好度 | 维护成本 | 结论 |
|---|---|---|---|---|
| 第三方 kext | ❌ AS 被禁 | 差（需降安全） | 高 | **放弃** |
| DriverKit | ❌ 无授权 | 差 | 高 | **放弃** |
| 用户态 IOKit + 特权 helper（XPC） | ✅ | 好（店外+公证） | 中 | **采用** |
| sudo 一次性提权（CLI） | ✅ | 中 | 低 | 仅研究/CLI，不用于 GUI |

### 7.2 形态对比
| 形态 | 轻量度 | 用户门槛 | 适合 FunFan |
|---|---|---|---|
| Electron 大窗口 | 低 | 低 | ❌ |
| SwiftUI 菜单栏 + Popover | 高 | 低 | ✅ |
| TUI / CLI | 高 | 高 | 可作为附带 CLI，不作主形态 |

### 7.3 自研 SMC 层 vs 复用
- **复用 SMCKit / Stats 的 SMC.swift**：快速起步，但需改造以适配 AS 浮点编码、键大小写与 `Ftst` 探测。
- **自研精简 SMCService**：可控性高、依赖少（参考 fand 的协议文档、fan-control 的实战笔记），推荐吸收社区成果后**自研一层薄封装**，避免长期被上游 Intel-only 假设拖累。

---

## 8. 推荐实现路径（适配 M 系 + 最新 macOS）

> 以下路径可作为后续“开发规格（Spec）”的输入。

### 8.1 架构决策（一句话理由）
| 决策 | 选择 | 理由 |
|---|---|---|
| 硬件访问 | 用户态 IOKit（AppleSMC）+ Ftst 解锁 | AS 上唯一可分发、免 kext 的路径 |
| 特权模型 | `SMAppService` root helper + XPC | 现代、用户只需授权一次、调用方可签名校验 |
| GUI 形态 | SwiftUI 菜单栏 + Popover | 最简轻量、契合需求 |
| UI 技术 | Swift + SwiftUI + Combine | 原生、体积小、现代 |
| 控制语义 | 提高/曲线调速/**温度规则自动调速** + 安全下限 + 退出返还 | 安全优先，不锁死低转速 |
| 分发 | Developer ID 签名 + 公证 + 店外 | App Store 不可行 |

### 8.2 分阶段实施
- **阶段 1 — SMC 硬件抽象层（SMCService）**
  - 打开/关闭 `AppleSMC`、80 字节 `SMCParamStruct` 收发、selector=2。
  - 键枚举与**运行时探测**（是否存在 `F0Md`/`F0md`、`Ftst`；读 `FNum`、各风扇 `F0Mn/F0Mx`）。
  - 编解码：先 `GetKeyInfo` 取 type，再按 `flt`(小端)/`fpe2`/`sp78`/`ioft`(48.16 小端)/`ui8` 解码（**绝不假设固定编码**）。
  - 只读监控：`F0Ac`、温度 `T*`、功率等；动态枚举全部 `T*` 传感器。
- **阶段 2 — 控制与安全引擎**
  - 解锁序列：M1/M2/M5 直接写模式键；M3/M4 走 `Ftst=1` 解锁 + 重试；全部运行时探测。
  - 写入 `F0Tg`（clamp 到 `F0Mn–F0Mx`），以 `F0Ac` 收敛确认。
  - 安全下限（max(CPU,GPU) 温度驱动）、迟滞、斜率限制、单实例锁；**规则引擎（温度阈值→目标 RPM，多规则冲突取最大、迟滞防抖）**。
  - **看门狗重申请**：睡眠/唤醒/合盖后自动恢复期望状态；退出/崩溃/SIGTERM 返还系统自动。
  - 冲突检测：发现其他控制器持有时拒绝接管。
- **阶段 3 — 特权辅助进程**
  - `SMAppService.daemon` 安装 root helper；XPC 接口：`version` / `status` / `set(rpm|percent, ttl)` / `auto` / `curve`。
  - helper 对 XPC 连接施加代码签名要求；仅允许本 app 签名调用。
  - 支持 TTL（超时自动返还系统），避免“失控卡死”。
- **阶段 4 — 轻量 GUI**
  - 菜单栏图标 + Popover：实时转速/温度、固定 RPM、传感器曲线编辑、预设（静音/均衡/性能）。
  - 设置窗口：传感器选择、开机自启、关于与免责声明。
  - 监听 macOS 睡眠/唤醒、合盖通知以触发状态机。
- **阶段 5 — 打包与加固**
  - Developer ID 签名 + 公证；Sparkle 自更新；Homebrew cask（可选）。
  - 升级后提示重装 helper；大版本复测解锁序列；提供 `doctor` 自检（报告缺失键名而非空白）。
  - 明确免责声明（硬件风险、社区未文档化接口可能被系统更新破坏）。

### 8.3 风险与缓解
| 风险 | 缓解 |
|---|---|
| macOS 大版本升级破坏解锁机制 | 每个大版本复测；升级后提示重装 helper；键探测 + 能力协商 |
| M5 之后机制变化（`F0md`/`Ftst` 不存在） | 运行时探测、不写死；保留直接写路径 |
| 多控制器冲突 | 启动冲突检测、只恢复自管风扇 |
| 付费开发者账号/公证成本 | 预留账号与证书；先以本地签名做开发验证 |
| 机型键名/范围差异 | 动态枚举 + 可选机型表兜底 |

---

## 9. 后续规格（Spec）建议（开发输入）
下一步可基于本文形成正式开发规格，建议至少覆盖：
- **Objective**：简洁轻量 GUI 风扇控制，支持 Apple Silicon + 最新 macOS，安全优先。
- **Tech Stack**：Swift 5.x + SwiftUI + Combine；`SMAppService` helper；XPC；无第三方重依赖（仅系统 IOKit）。
- **Commands**：`make build` / `make test` / `make run` / 公证脚本。
- **Project Structure**：`App/`(菜单栏与桥接)、`Services/`(FanController、CurveEngine)、`SMC/`(SMCService 硬件层)、`Helper/`(root daemon + XPC)、`Tests/`、`docs/`。
- **Code Style**：显式处理 80 字节对齐结构体、键探测优先、错误映射为友好文案。
- **Testing**：SMCService/曲线/安全逻辑单测（模拟数据）；真机集成测试验证解锁与返还。
- **Boundaries**：永不写 `F0Mn/F0Mx`；永不把风扇设为 0；退出必返还；不硬编码机型；密钥/证书不入库。

---

## 10. 结论与未决问题

### 10.1 结论
1. **可行**：Apple Silicon 上的风扇控制已被多个独立开源/研究项目证实可行，核心技术是“用户态 IOKit 访问 AppleSMC + Ftst 解锁序列 + root 特权辅助进程”。
2. **kext / DriverKit 不可行**：在 Apple Silicon 上需降系统安全或无官方授权，不适合分发。
3. **App Store 不可行**：SMC 直访违反沙箱，必须店外分发 + 公证。
4. **轻量 GUI 最优解**：SwiftUI 菜单栏常驻 + Popover，配合后台 root helper（XPC）。
5. **安全是核心**：安全下限、迟滞、斜率、睡眠/退出返还、冲突检测缺一不可。

### 10.2 未决问题（待产品/负责人决策）
- 是否需要**付费 Developer ID** 用于正式发布？（开发阶段可用本地/自签名验证。）
- 是否兼容 **Intel Mac**？（协议已含 `fpe2` 路径，但测试成本上升。）
- 控制目标定位：**仅“提高/曲线/规则”**（默认，安全优先），不压低到系统默认下限以下；若未来要支持“降噪优先、允许低于默认”需单独评估风险。
- 规则引擎已纳入 v1 范围（监控温度 + 基于温度阈值的自动调速）；**CSV 日志与邮件/弹窗告警**仍留待后续版本。（见 `SPEC-FunFan.md` §4.1、§9 Q4/Q6/Q7。）

---

## 附录 A：SMC 键速查
| 键 | 类型 | 方向 | 说明 |
|---|---|---|---|
| `FNum` | ui8 | 读 | 风扇数 |
| `F0Ac/F1Ac` | flt | 读 | 实际转速（确认生效用） |
| `F0Tg/F1Tg` | flt | 写 | 目标转速（clamp 到 Min–Max） |
| `F0Mn/F0Mx` | flt | 读 | 最低/最高转速（**禁写**） |
| `F0Md/F0md` | ui8 | 写 | 模式（自动/手动；大小写探测） |
| `Ftst` | ui8 | 写 | M1–M4 解锁标志（写 1；M5 可能不存在） |
| `FS!` | flag | 写 | Intel 强制位域 |
| `T*` | flt | 读 | 温度传感器（机型差异大，动态枚举） |

## 附录 B：主要参考来源
- agoodkind/macos-smc-fan（M 系解锁研究，MIT）
- raminsharifi/MacFanControl（Rust TUI，解锁序列实现）
- adilkairolla/fan-control（Swift 菜单栏，SMC 实战笔记，macOS 26 / M5）
- june4432/thermo-control-mcp（Swift daemon + Ftst 解锁 + 动态枚举）
- rachitdev/mac-mini-fan-driver（Rust daemon，安全契约与看门狗）
- yolo-labz/fand（SMC-PROTOCOL 参考文档）
- beltex/SMCKit（Swift SMC 库，Intel 取向，协议参考）
- Fanny / Stats / iStat Menus / TG Pro / Macs Fan Control（形态与能力参照）
- Apple 开发者文档：Service Management（`SMAppService`）、App Sandbox
- Apple 支持：Apple 芯片 Mac 的 SMC 说明
