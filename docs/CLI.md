# 命令行与验收

> 从 [README](../README.md) 拆出。`funfanctl` 是随 `make build` 一起产出的命令行工具；安装与后台组件见 [INSTALL.md](INSTALL.md)。

## 常用命令

```bash
make doctor      # 硬件与权限诊断（只读）
make diagnose    # 系统信息采集，输出 Markdown 报告
make status      # 当前风扇状态（只读）
make raw KEY=TR0Z   # 打印某键的原始字节与候选解码（未知 SMC 类型取证用）
make raw TYPE=ioft  # 按类型扫全表
```

`funfanctl` 支持 `diagnose [--json] [--save]`、`doctor`、`status`、`spin`、`set`、`restore`、`raw`。有失败项时 `diagnose` 退出码为 2，便于脚本化回归。

`diagnose` 产出的是可直接贴进 issue 的 Markdown 报告：机型、芯片、系统、SMC 键数、温度键可读率与不可读清单（含类型）、风扇区间与模式键、helper 状态与日志尾。

## 无人值守验收

GUI 支持几个调试启动参数，用来在没有人在屏幕前的情况下验证策略接管（`funfanctl status` 是唯一观测面）：

```bash
./.build/debug/FunFan --strategy curve              # 启动即进入曲线策略
./.build/debug/FunFan --strategy fixed --rpm 3000   # 固定转速
./.build/debug/FunFan --simulate-lid cycle          # 注入合盖→开盖往返
./.build/debug/FunFan --curve-window                # 直接开曲线编辑窗口
```

`--strategy` 会在 bootstrap 完成 1.5 s 后生效，并把决定打进日志。验证时配合 `funfanctl status` 看「目标 / 模式」是否变化；`kill -9` 掉 GUI 后约 10 s 应自动回到 `automatic`（helper 租约看门狗）。

`--simulate-lid` 是为**没有盖子的开发机**（Mac mini）准备的：那台机器上合盖判定路径不生效，但「接管 → 合盖返还 → 挂起期间拒绝重新接管 → 开盖恢复」这条链可以靠注入信号回归。合盖判定本身已在 MacBook Pro M2 真机验证，见 [STATUS.md](STATUS.md)。取值 `closed` / `open` / `cycle`（`cycle` = 3 s 后合盖、11 s 后开盖）。

打包后的 helper 状态查询（必须直接跑包内可执行文件，`open --args` 拿不到 stdout）见 [BUILD.md](BUILD.md)。
