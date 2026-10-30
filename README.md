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
make test         # 268 个单测
make run          # 启动菜单栏 App
```

只读功能（监控）**不需要 root**。写入风扇需要安装一次特权 helper，两种方式二选一：

```bash
# 方式 A（正式）：从 App 里安装，系统只弹一次授权，之后随 App 升级
make app && open dist/FunFan.app
#   设置 → 风扇控制组件 → 安装

# 方式 B（开发）：脚本直装 /Library/LaunchDaemons，每次都要 sudo
make install-helper
```

装完验证：

```bash
./.build/release/funfanctl doctor      # 确认硬件与权限
sudo ./.build/release/funfanctl spin --rpm 2950 --seconds 6   # 写入验证，结束自动返还
```

两种安装**不能共存**（同名 label `com.funfan.helper` 会互抢 Mach service）：脚本装过的机器要先 `sudo bash scripts/install-helper.sh uninstall`，App 才会允许走方式 A；反过来，App 装过之后脚本也会拒绝安装并告诉你原因。

## 命令行

```bash
make doctor      # 硬件与权限诊断（只读）
make diagnose    # 系统信息采集，输出 Markdown 报告
make status      # 当前风扇状态（只读）
make raw KEY=TR0Z   # 打印某键的原始字节与候选解码（未知 SMC 类型取证用）
make raw TYPE=ioft  # 按类型扫全表
```

`funfanctl` 支持 `diagnose [--json] [--save]`、`doctor`、`status`、`spin`、`set`、`restore`、`raw`。有失败项时 `diagnose` 退出码为 2，便于脚本化回归。

### 无人值守验收

GUI 支持几个调试启动参数，用来在没有人在屏幕前的情况下验证策略接管（`funfanctl status` 是唯一观测面）：

```bash
./.build/debug/FunFan --strategy curve              # 启动即进入曲线策略
./.build/debug/FunFan --strategy fixed --rpm 3000   # 固定转速
./.build/debug/FunFan --simulate-lid cycle          # 注入合盖→开盖往返
./.build/debug/FunFan --curve-window                # 直接开曲线编辑窗口
```

`--strategy` 会在 bootstrap 完成 1.5 s 后生效，并把决定打进日志。验证时配合 `funfanctl status` 看「目标 / 模式」是否变化；`kill -9` 掉 GUI 后约 10 s 应自动回到 `automatic`（helper 租约看门狗）。

`--simulate-lid` 是为**没有盖子的机器**准备的：合盖判定本身验不了，但「接管 → 合盖返还 → 挂起期间拒绝重新接管 → 开盖恢复」这条链可以。取值 `closed` / `open` / `cycle`（`cycle` = 3 s 后合盖、11 s 后开盖）。

## 打包与分发

SwiftPM 只产出裸可执行文件，而裸二进制**没有 bundle 标识**：`SMAppService`（登录项、特权 helper）一律注册失败，公证工具也没有东西可提交。所以分发形态必须先有 `.app`：

```bash
make app          # → dist/FunFan.app（内到外签名，默认 adhoc）
make run-app      # 打包并启动
make sign-info    # 看会自动选用哪个签名身份
```

包结构：

```
FunFan.app/Contents/
  Info.plist                              LSUIElement=true（菜单栏常驻、无 Dock 图标）
  MacOS/FunFan                            GUI
  MacOS/FunFanHelper                      特权 helper 本体
  Library/LaunchDaemons/com.funfan.helper.plist   给 SMAppService.daemon 用（BundleProgram 相对路径）
```

版本号唯一来源是仓库根的 `VERSION` 文件；`CFBundleVersion` 取 `git rev-list --count HEAD`，单调递增且可复现。

`--helper-status` / `--helper-install` / `--helper-uninstall` 是给验收与脚本用的（必须直接跑包内可执行文件，`open --args` 拿不到 stdout）：

```bash
dist/FunFan.app/Contents/MacOS/FunFan --helper-status     # 0 已启用 / 1 待批准 / 2 环境不支持
```

每一行都会同时写到 `~/Library/Application Support/FunFan/helper-cli.log`——用户报障时直接贴这一段，比「装不上」三个字有用得多。

签名身份的来源顺序：`--identity` 参数 → `FUNFAN_SIGN_IDENTITY` 环境变量 → 自动找 `Developer ID Application` → 回退 adhoc。**adhoc 签名进不了 Gatekeeper，也无法公证**，只够本机调试与开发登录项；要出可分发的包必须用 Developer ID。

### 签名与公证

```bash
make notary-check    # 体检：证书 / 公证凭据 / 硬运行时 / 调试权限，缺什么说什么
make notarize        # 重建 .app → 打 DMG → 提交公证 → 装订 → Gatekeeper 验收
make dmg             # 只打 DMG（有证书就顺带签 DMG）
```

`make notarize` 的流程与它刻意拦在提交前的东西：

1. 用 Developer ID 重建并签名（内到外：先 helper 后 App，`--options runtime` 硬运行时）；
2. **提交前预检**——硬运行时缺失、带 `get-task-allow`、helper 签名不通过，全部在此拦下。公证一次往返通常 1–5 分钟，让它在第 0 秒失败比在第 5 分钟失败划算；
3. DMG 提交 `notarytool --wait`，非 `Accepted` 自动拉公证日志（`notarytool log`）；
4. `stapler` 装订票据，最后 `spctl` 验收——**Gatekeeper 真的放行才算过**，退出码 0 才有意义。

首次使用要准备两样东西（脚本只检查、不代办）：

```bash
# 1. Developer ID Application 证书：Xcode → Settings → Accounts → Manage Certificates → +
# 2. 公证凭据（App 专用密码，不是 Apple ID 密码）
xcrun notarytool store-credentials funfan-notary \
  --apple-id "you@example.com" --team-id "TEAMID" --password "app-specific-password"
```

凭据名可用 `FUNFAN_NOTARY_PROFILE` 覆盖。**本机当前没有 Developer ID 证书**，所以公证链路只完成了失败路径与预检逻辑的验证（`make notary-check` 会准确报出缺证书、缺凭据），实际签名/公证/装订要在装好证书的机器上跑一遍才算验完。

## 代码结构

```
FunFanCore/     硬件与逻辑（无 UI 依赖，可单测）
  SMC/          AppleSMC 访问（80 字节结构体）、编解码、键枚举
  Monitor/      传感器目录、采样与平滑、采样频率策略
  Battery/      电量与电池明细
  Control/      安全策略、曲线、规则引擎、控制器、租约、第三方接管检测
  Helper/       特权组件的签名要求与注册状态（纯数据，可单测）
  Rules/        规则持久化（原子写、损坏降级）
  XPC/          与 helper 的契约
  System/       机型/合盖判定、签名信息
  Diagnostics/  能力探测与诊断报告
  Types/        错误类型等公共定义
FunFan/         SwiftUI 菜单栏 App
FunFanCtl/      CLI（funfanctl）
FunFanHelper/   特权 helper（XPC + 看门狗）
FunFanProbe/    真机探针
Tests/          268 个单测
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
| [docs/RELEASE.md](docs/RELEASE.md) | 发布手册：证书准备、出包步骤、人工验收清单、常见失败处理 |
| [docs/ui-design-handoff.md](docs/ui-design-handoff.md) | UI 设计交付稿（含实现偏差附录） |
| [docs/ui-prototype/funfan-design.html](docs/ui-prototype/funfan-design.html) | 可交互 HTML 原型 |
| [tasks/todo.md](tasks/todo.md) | 任务清单与逐项验证记录 |

## 状态

M1（SMC 地基）→ M5（GUI）已完成并在真机（Mac mini M4 / macOS 27）验证：180/180 温度键可读、风扇 1000–4900 RPM 写入生效、268 个单测全绿。

策略四态（自动 / 固定 / 曲线 / 规则）全部可用，曲线与规则编辑器均已落地；设置窗口支持登录启动、菜单栏显示开关、一键自检与免责声明。

曲线策略已在真机跑通端到端：接管后 `manualFixed`、目标随温度单调跟随（2116→2333）、实际转速误差 0–3 RPM、`kill -9` 后 8 s 由租约看门狗返还 `automatic`。规则策略的写入链路与曲线共用同一套下发路径。

M6（打包加固）已落地：`.app` 打包、Developer ID 签名 + 公证 + 装订脚本、helper 一次授权（`SMAppService`）、第三方接管检测与 `doctor` 自检。**本机没有 Developer ID 证书**，所以公证成功路径与打包后的 helper 注册还差一次真机复验（见 `tasks/todo.md` M6 的 Verify 记录）。

未完成：T16b 端到端合盖验证（需笔记本机型）、M6 的证书侧复验。

## 许可

未定。
