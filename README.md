# FunFan

macOS 菜单栏风扇控制工具，面向 **Apple Silicon**。零第三方依赖，纯 Swift / SwiftUI，用 SPM 构建。

不只是一个"拉滑块转风扇"的界面：它读 SMC 温度与电量，按你写的规则自动调速，并在任何异常路径上把控制权还给系统。

## 现在能做什么

| 能力 | 说明 |
|---|---|
| 温度监控 | 全键枚举 `T*` 传感器（本机 180 个），按 CPU / GPU / 内存 / SSD / 电池 / 环境归类；CPU、GPU 同时给**均温**与**逐核 / 按簇**明细 |
| 电量监控 | 走 `IOPMPowerSource`（免 root、沙箱友好），台式机正确判定为"无电池" |
| 规则自动调速 | `CPU 均温 ≥ 60℃ → 3500 RPM` 这类规则，40 RPM 死区防抖、10 s 重断言、解除时只发一次命令 |
| 曲线调速 | 多控制点曲线 + 斜率限制，避免转速突跳 |
| 安全策略 | **只提速不压低**：60℃→最小值、95℃→最大值线性给出下限，任何策略结果都不能低于它；**绝不写 0 RPM**；多规则冲突取最大 |
| 租约看门狗 | GUI 经 XPC 让 root helper 持权，10 s 租约 + 1 s 看门狗；GUI 崩溃 / 退出 / 合盖，风扇自动回到系统控制 |
| 一键诊断 | 一条命令拿到可贴进 issue 的 Markdown 报告：机型、芯片、系统、SMC 键数、温度键可读率与不可读清单（含类型）、风扇区间与模式键、helper 状态与日志尾 |

## 快速开始

需要 macOS 13+ 与 Xcode 命令行工具。

```bash
git clone git@github.com:lovexiaov/funfan.git
cd funfan

make build        # 调试构建（含 CLI / helper / probe / GUI）
make test         # 216 个单测
make run          # 启动菜单栏 App
```

只读功能（监控）**不需要 root**。写入风扇需要安装一次特权 helper：

```bash
make install-helper                    # sudo 安装到 /Library/LaunchDaemons
./.build/release/funfanctl doctor      # 确认硬件与权限
sudo ./.build/release/funfanctl spin --rpm 2950 --seconds 6   # 写入验证，结束自动返还
```

## 命令行

```bash
make doctor      # 硬件与权限诊断（只读）
make diagnose    # 系统信息采集，输出 Markdown 报告
make status      # 当前风扇状态（只读）
make raw KEY=TR0Z   # 打印某键的原始字节与候选解码（未知 SMC 类型取证用）
make raw TYPE=ioft  # 按类型扫全表
```

`funfanctl` 支持 `diagnose [--json] [--save]`、`doctor`、`status`、`spin`、`set`、`restore`、`raw`。有失败项时 `diagnose` 退出码为 2，便于脚本化回归。

## 代码结构

```
FunFanCore/     硬件与逻辑（无 UI 依赖，可单测）
  SMC/          AppleSMC 访问（80 字节结构体）、编解码、键枚举
  Monitor/      传感器目录、采样与平滑、采样频率策略
  Battery/      电量与电池明细
  Control/      安全策略、曲线、规则引擎、控制器、租约
  Rules/        规则持久化（原子写、损坏降级）
  XPC/          与 helper 的契约
  System/       机型/合盖判定
  Diagnostics/  能力探测与诊断报告
  Types/        错误类型等公共定义
FunFan/         SwiftUI 菜单栏 App
FunFanCtl/      CLI（funfanctl）
FunFanHelper/   特权 helper（XPC + 看门狗）
FunFanProbe/    真机探针
Tests/          216 个单测
```

## 几个真机上踩到的坑

这些都是实测才知道的，不是文档里查得到的：

- `SMCParamStruct` 必须严格 **80 字节**。Swift 里 `struct` 的内存对齐会让它变成 76 或 84，调用静默失败。项目里用逐字段 offset 断言钉死。
- Apple Silicon 上温度并非全是 `flt`。本机 180 个温度键里有 6 个是 **`ioft`**（8 字节小端 48.16 定点），且必须**按有符号解**——未接探针会返回高位全 1 的哨兵值，按无符号解会得到 2.8e14℃，反而"看起来合法"地骗过合理性过滤。
- `swift build` 直接产出的二进制只有 **linker-signed** 签名，`launchd` 装载时会报 `Bootstrap failed: 5`。安装脚本里会重新 `codesign --force --sign -`。
- 本机 SPM 的 `sandbox-exec` 受限，所有 `swift` 命令都得带 `--disable-sandbox`（Makefile 已统一处理）。
- 合盖状态的 `AppleClamshellState` 在现代 macOS 上已不存在，改用「内建屏是否在线 + 是否有外接屏在线」双条件判定。

## 安全边界

- 绝不写 `F0Mn` / `F0Mx`（固件推荐区间），只写 `F0Tg`。
- 目标转速一律 clamp 到系统区间，**绝不发送 0 RPM**。
- 任何退出路径（正常退出、崩溃、合盖、helper 侧租约过期）都会返还系统自动控制。
- 规则只能"提速"。你自己的规则不可能把风扇降到安全下限以下。

## 文档

| 文件 | 内容 |
|---|---|
| [docs/macos-fan-control-research.md](docs/macos-fan-control-research.md) | 调研：SMC 协议、权限模型、开源方案对比、推荐路径 |
| [docs/SPEC-FunFan.md](docs/SPEC-FunFan.md) | 规格：范围、架构、模块职责、验收标准 |
| [docs/ui-design-handoff.md](docs/ui-design-handoff.md) | UI 设计交付稿（含实现偏差附录） |
| [docs/ui-prototype/funfan-design.html](docs/ui-prototype/funfan-design.html) | 可交互 HTML 原型 |
| [tasks/todo.md](tasks/todo.md) | 任务清单与逐项验证记录 |

## 状态

M1（SMC 地基）→ M5（GUI）已完成并在真机（Mac mini M4 / macOS 27）验证：180/180 温度键可读、风扇 1000–4900 RPM 写入生效、216 个单测全绿。

未完成：T14b（曲线编辑器 + 设置窗口）、T16b 端到端合盖验证（需笔记本机型）、M6（签名 / 公证 / 打包）。

## 许可

未定。
