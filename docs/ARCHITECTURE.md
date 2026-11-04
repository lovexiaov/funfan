# 架构、安全边界与真机踩坑

> 从 [README](../README.md) 拆出。完整规格见 [SPEC-FunFan.md](SPEC-FunFan.md)，底层原理调研见 [macos-fan-control-research.md](macos-fan-control-research.md)。

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
Tests/          291 个单测
```

零第三方依赖；逻辑放 `FunFanCore`（无 UI 依赖、可单测），UI 只在 `FunFan`。

## 安全边界

- 绝不写 `F0Mn` / `F0Mx`（固件推荐区间），只写 `F0Tg`。
- 目标转速一律 clamp 到系统区间，**绝不发送 0 RPM**。
- 任何退出路径（正常退出、崩溃、合盖、helper 侧租约过期）都会返还系统自动控制。
- 规则只能"提速"。你自己的规则不可能把风扇降到安全下限以下。

信任模型与私密漏洞上报渠道见 [SECURITY.md](../SECURITY.md)。

## 几个真机上踩到的坑

这些都是实测才知道的，不是文档里查得到的：

- `SMCParamStruct` 必须严格 **80 字节**。Swift 里 `struct` 的内存对齐会让它变成 76 或 84，调用静默失败。项目里用逐字段 offset 断言钉死。
- Apple Silicon 上温度并非全是 `flt`。本机 180 个温度键里有 6 个是 **`ioft`**（8 字节小端 48.16 定点），且必须**按有符号解**——未接探针会返回高位全 1 的哨兵值，按无符号解会得到 2.8e14℃，反而"看起来合法"地骗过合理性过滤。
- `swift build` 直接产出的二进制只有 **linker-signed** 签名，`launchd` 装载时会报 `Bootstrap failed: 5`。安装脚本里会重新 `codesign --force --sign -`。
- 本机 SPM 的 `sandbox-exec` 受限，所有 `swift` 命令都得带 `--disable-sandbox`（Makefile 已统一处理）。
- 合盖状态的 `AppleClamshellState` 在现代 macOS 上已不存在，改用「内建屏是否在线 + 是否有外接屏在线」双条件判定。

> 工程约定：**先读 `GetKeyInfo` 的 type 再解码**，未知类型必须显式失败而不是猜；新增类型先用 `funfanctl raw` 取真实字节取证。命令见 [CLI.md](CLI.md)。
