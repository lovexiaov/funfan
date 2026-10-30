# Plan: FunFan —— macOS 轻量风扇控制工具

> 派生自 `docs/SPEC-FunFan.md`（Phase 1 已完成并人工确认）
> 流程：Phase 0 能力地图 → Phase 2 实现计划 → Phase 3 任务清单 → Phase 4 实现
> 当前文件 = Phase 2 计划；任务拆解为 `todo.md`

---

## 0. 能力地图（Capability Map，Phase 0）

本需求捆绑多个可独立测试的模块，先定模块边界与构建顺序，再写计划。

| Module id | 职责 | 依赖 | 数据来源 / 权限 |
|---|---|---|---|
| `smc-core` | SMC 硬件抽象：连接、80 字节 struct、键探测、编解码（flt/fpe2/ui8） | — | IOKit AppleSMC；**写需 root，读免 root** |
| `monitor-sensors` | 温度监控：`SensorCatalog`（逐代表+三级回退+语义归类） + `SensorStore`（2 Hz 轮询+滑动均值） | `smc-core` | SMC `T*`；**免 root**（GUI 内读） |
| `monitor-battery` | 电量监控：`BatteryStore`（电量%/健康/循环/功率/AC） | — | IOKit `IOPS*` + `AppleSmartBattery`；**免 root、沙箱友好** |
| `control-engine` | 控制：`FanController`（解锁+写 F0Tg）、`CurveEngine`、`SafetyPolicy`、`RuleEngine`（温度阈值自动调速） | `smc-core`, `monitor-sensors` | 写经 `helper`；规则评估在 GUI 端 |
| `helper` | 特权守护进程：`SMAppService` daemon + XPC listener + 签名校验 + TTL | `control-engine` | root，仅执行写 |
| `gui` | 菜单栏常驻：Popover/设置/规则编辑/曲线编辑/睡眠合盖监听/自动返还 | `monitor-sensors`, `monitor-battery`, `control-engine`, `helper` | 主进程，永不持 root |

**构建顺序（无环）**：
```
smc-core → monitor-sensors ┐
         → monitor-battery ┴→ control-engine → helper → gui
```
- `monitor-sensors` 与 `monitor-battery` **可并行**（互不依赖）。
- `control-engine` 依赖温度数据，故在 `monitor-sensors` 之后。
- `helper` 是 `control-engine` 的 root 执行代理，二者需配对联调。
- `gui` 最后，聚合全部能力。

---

## 1. 主要组件与依赖

1. **FunFanCore（共享库）** —— 被 App 与 Helper 引用，承载 `smc-core` / `control-engine` / `monitor-sensors` 的纯逻辑部分（不含 root）。
   - `SMC/`：`SMCParamStruct`(80B)、`SMCService`、`SMCKey`、`Codecs`、`SensorCatalog`
   - `Control/`：`FanController`、`CurveEngine`、`RuleEngine`、`SafetyPolicy`
   - `Stores/`（GUI 侧也可引用类型）：数据模型 `FanRule`/`Curve`/`Preset`/`SensorReading`/`BatteryState`
2. **FunFan（GUI App）** —— `app`/`Views`/`Stores`，含 `SensorStore`、`BatteryStore`、`ControlStore`、`RulesStore`，及睡眠/合盖监听、XPC 客户端。
3. **FunFanHelper（root daemon）** —— `SMAppService.daemon` 安装，XPC 暴露 `setTargetRpm(_:)` / `restoreAuto()` / `getFanState()`；含签名校验与 TTL 看门狗。
4. **XPC 契约** —— `FunFanXPC` 协议（定义在 Core，App 与 Helper 各实现一端），所有 payload 可 `Codable` 序列化以支持单测 mock。

---

## 2. 实现顺序（里程碑）

- **M1 · smc-core 地基**：能连 SMC、读任意键、按类型解码；静态断言 struct=80B。（无任何 UI）
- **M2 · 监控层**：`monitor-sensors`（温度枚举+轮询）与 `monitor-battery`（电量）并行实现并各自单测。
- **M3 · 控制与规则引擎**：`FanController`（先实现「经 helper 下发」抽象，helper 未就绪时由单测 mock）+ `CurveEngine` + `SafetyPolicy` + `RuleEngine`，纯逻辑全单测覆盖。
- **M4 · 特权 helper**：真正的 root daemon + XPC；与 M3 的 `FanController` 接通真实写入 + `Ftst` 解锁序列。
- **M5 · GUI**：菜单栏 + Popover + 三视图（转速/温度/电量实时）+ 曲线编辑 + 规则编辑 + 设置；睡眠/合盖/退出自动返还。
- **M6 · 打包加固**：签名 + 公证脚本、冲突检测、`doctor` 自检、免责声明。

---

## 3. 风险与缓解

| 风险 | 影响 | 缓解 |
|---|---|---|
| M3/M4 的 `Ftst` 解锁序列在 M5 / 新 macOS 失效 | 风扇写不进 | `Ftst` 与 `F0Md`/`F0md` **运行时探测**（不写死）；解锁失败降级为「仅监控 + 友好提示」；`doctor` 自检可复测 |
| 温度键名逐代变化导致读空 | 温度监控失效 | `SensorCatalog` 三级回退（密钥表→HID→全 `T*` 枚举）+ 合理性过滤 (4,132)℃ |
| 规则/曲线把转速压到下限以下导致过热 | 系统风险 | `SafetyPolicy` 强制 `commanded = max(策略输出, 下限)`；下限基于核心温度动态算；下限之上才允许 |
| GUI 意外崩溃致风扇滞留手动 | 系统风险 | 写操作有 TTL 看门狗（helper 侧超时自动返还系统自动）；App 退出行 `atexit`/SIGTERM 返还 |
| 与其他风扇控制器争抢 SMC | 行为冲突 | 启动探测 `F0Md` 已被第三方持有时拒绝接管，仅恢复自身动过的风扇 |
| 店外分发被 Gatekeeper 拦 | 分发失败 | Developer ID 签名 + `notarize.sh`；helper 单独签名授权一次 |
| 单测无法覆盖硬件写路径 | 覆盖率缺口 | 单测 mock SMC/XPC；集成测试标记 `@Test` 仅在真机手动跑（M4 后） |

---

## 4. 并行 vs 串行

- **可并行**：M2 的 `monitor-sensors` 与 `monitor-battery`；M3 内 `CurveEngine`/`SafetyPolicy`/`RuleEngine` 与 `FanController` 接口设计可并行。
- **必须串行**：`smc-core`(M1) 先于一切；`helper`(M4) 后于 `control-engine` 抽象(M3)；`gui`(M5) 最后。
- **联调关键路径**：M3 抽象 → M4 真实 helper → M5 端到端。

---

## 5. 验证检查点（Phase 间 gate）

- **M1→M2**：`make test` 中 `SMCParamStructTests`(==80) + `CodecsTests` 全绿。
- **M2→M3**：`SensorCatalogTests`（归类/枚举）、`BatteryStoreTests`（计算/降级）全绿。
- **M3→M4**：`RuleEngineTests`/`CurveEngineTests`/`SafetyPolicy` 全绿（纯逻辑，含冲突取最大 RPM、迟滞、下限 clamp）。
- **M4→M5**：真机（M 系）写 `F0Tg` 生效、`F0Ac` 收敛、`Ftst` 在 M3/M4 持有；监控在 M1/M2/M5 直写成功。
- **M5→M6**：`make build` 产出 app；`notarize.sh` 通过；`doctor` 自检返回键名；退出/合盖/睡眠风扇自动返还。
- **最终**：满足 `SPEC-FunFan.md` §8 全部 12 条 Success Criteria。

---

## 6. 命令（来自 Spec §3）

```bash
make build      # xcodebuild -scheme FunFan -configuration Release build
make test       # xcodebuild test -scheme FunFan -destination 'platform=macOS'
make run        # 打开 build/Release/FunFan.app
make lint       # swiftlint / swift-format
./scripts/notarize.sh build/Release/FunFan.app
```

> 注：M1–M3 阶段可仅对 `FunFanCore` scheme 跑 `make test`；M4 起需真机 + root 做集成测试。
