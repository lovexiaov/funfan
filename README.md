# FunFan

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Release](https://img.shields.io/github/v/release/lovexiaov/funfan?include_prereleases&label=release)](https://github.com/lovexiaov/funfan/releases)
[![ci](https://github.com/lovexiaov/funfan/actions/workflows/ci.yml/badge.svg)](https://github.com/lovexiaov/funfan/actions/workflows/ci.yml)

macOS 菜单栏风扇控制工具，面向 **Apple Silicon**。零第三方依赖，纯 Swift / SwiftUI，用 SPM 构建。

不只是一个"拉滑块转风扇"的界面：它读 SMC 温度与电量，按你写的规则自动调速，并在任何异常路径上把控制权还给系统。

> **改风扇转速有风险。** 底层 SMC 接口未公开，系统升级后可能失效或行为改变。所有写入都会收敛到系统区间与安全下限、绝不发送 0 RPM，但请自行承担使用风险；出现异常先切回「自动」。安全边界见 [ARCHITECTURE.md](docs/ARCHITECTURE.md#安全边界)。

## 界面

| 菜单栏面板 | 温度曲线 |
|---|---|
| ![菜单栏面板](docs/ui-prototype/popover-actual.png) | ![温度曲线](docs/ui-prototype/curve-window-actual.png) |

更多界面（规则编辑器、设置）见 [UI 设计交付稿](docs/ui-design-handoff.md)。

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

从 [Releases](https://github.com/lovexiaov/funfan/releases) 下载最新版 `FunFan-<版本>.dmg`（目前均为 **alpha 预发布版**），三步可用：

1. 拖进「应用程序」——**别在 DMG 里直接运行**；
2. 首次打开被拦时：系统设置 → 隐私与安全性 → 「仍要打开」；
3. 菜单栏点开 → 面板底部「一键启用」→ 输一次系统密码。

> 包未经 Apple 公证，被拦一次是预期行为。校验、放行细节、卸载与旧版残留清理见 [安装与卸载](docs/INSTALL.md)。

从源码跑（macOS 13+ 与 Xcode 命令行工具）：

```bash
git clone https://github.com/lovexiaov/funfan.git && cd funfan
make build && make test && make run
```

## 文档

| 想找什么 | 看这份 |
|---|---|
| 安装、放行、卸载、清理残留 | [INSTALL.md](docs/INSTALL.md) |
| 命令行、诊断报告、无人值守验收 | [CLI.md](docs/CLI.md) |
| 打包、签名、发版、CI | [BUILD.md](docs/BUILD.md)（背景）· [RELEASE.md](docs/RELEASE.md)（操作清单与验收） |
| 代码结构、安全边界、真机踩坑 | [ARCHITECTURE.md](docs/ARCHITECTURE.md) |
| 规格与验收标准 | [SPEC-FunFan.md](docs/SPEC-FunFan.md) |
| SMC 协议、权限模型、方案对比 | [macos-fan-control-research.md](docs/macos-fan-control-research.md) |
| UI 设计、复审、可交互原型 | [ui-design-handoff.md](docs/ui-design-handoff.md) · [ui-review-2026-11-01.md](docs/ui-review-2026-11-01.md) · [HTML 原型](docs/ui-prototype/funfan-design.html) |
| Homebrew 发布调研 | [HOMEBREW.md](docs/HOMEBREW.md) |
| 项目状态、验证记录、版本改动 | [STATUS.md](docs/STATUS.md) · [CHANGELOG.md](docs/CHANGELOG.md) |
| 贡献、安全、社区准则 | [CONTRIBUTING.md](CONTRIBUTING.md) · [SECURITY.md](SECURITY.md) · [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) |

## 状态

M1–M6 已完成并在真机（Mac mini M4 / macOS 27）验证：180/180 温度键可读、风扇 1000–4900 RPM 写入生效、291 个单测全绿；策略四态（自动 / 固定 / 曲线 / 规则）全部可用。

目前对外发的是 **未签名、未公证的 alpha 预发布版**（个人项目，未加入 Apple Developer Program），首次启动需手动放行一次；未完成 T16b 端到端合盖验证（需笔记本机型）。详见 [STATUS.md](docs/STATUS.md)。

## 许可与贡献

[MIT](LICENSE)。改风扇转速属于对硬件的直接操作，风险自负，信任模型见 [SECURITY.md](SECURITY.md)。

欢迎 issue 与 PR：功能 / 安装问题请按 [issue 模板](https://github.com/lovexiaov/funfan/issues/new/choose) 附诊断报告；代码贡献先读 [CONTRIBUTING.md](CONTRIBUTING.md)，**fork 构建前务必改 bundle id**，否则会和本机已装的 helper 抢同一个 launchd label。
