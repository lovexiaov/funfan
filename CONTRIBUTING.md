# 贡献指南

欢迎 issue 和 PR。这个项目很小，规则也少，但有几条是硬性的——尤其是涉及 root helper 和 SMC 写入的部分。

## 先读什么

| 想做的事 | 先看 |
|---|---|
| 了解整体设计 | [`docs/SPEC-FunFan.md`](docs/SPEC-FunFan.md) |
| 改 SMC 协议层 | [`docs/macos-fan-control-research.md`](docs/macos-fan-control-research.md) |
| 改界面 | [`docs/ui-design-handoff.md`](docs/ui-design-handoff.md) |
| 发版 / 打包 | [`docs/RELEASE.md`](docs/RELEASE.md) |
| 报告安全问题 | [`SECURITY.md`](SECURITY.md)（不要开公开 issue） |

## 开发环境

- macOS 13+，Apple Silicon
- Xcode 命令行工具（`xcode-select --install`）
- 零第三方依赖，不需要 Homebrew、CocoaPods、SPM 远端包

```bash
git clone https://github.com/lovexiaov/funfan.git
cd funfan

make build      # 调试构建（CLI / helper / probe / GUI）
make test       # 全部单测
make run        # 启动菜单栏 App（裸二进制，开发态）
make app        # 打包成 dist/FunFan.app
```

只读功能（温度、电量）不需要 root。写风扇需要装一次特权 helper，在 App 里点「一键启用」即可；开发期也可以用 `make install-helper`。**不要在 PR 里提交任何要求用户 `curl | sudo bash` 的东西。**

> 本机若遇到 SPM 的 `sandbox-exec` 报错，Makefile 已经统一加了 `--disable-sandbox`，直接用 `make` 就行。

## 提交前

1. `make test` 全绿。涉及真机的结论**不能只靠 mock**，请在 PR 里写清机型与 macOS 版本。
2. 新增或修改 SMC 键表时，附上真机证据（`make raw KEY=...` 或 `funfanctl diagnose` 的片段）。
3. 不引入第三方运行时依赖。打包脚本、公证链路都假设「只有系统框架」。
4. 改 UI 请附截图（明暗两种外观各一张更好）。
5. 一个 PR 做一件事。重构和行为变更不要混在一起。

## 代码约定

- 注释写**为什么**，不写「这行在做什么」。项目里大量注释是在记录真机踩坑与取舍，照着这个风格写。
- 安全相关的常量（SMC 键名、转速区间、租约时长）只允许有一个真源，不要在别处重复字面量。
- 新增的单测请放在 `Tests/FunFanCoreTests/`，命名沿用 `XXXTests.swift`。
- 提交信息用中文即可，写清「做了什么 + 为什么 + 验证结果」。

## 安全红线（PR 会被直接拒绝）

- 写 `F0Mn` / `F0Mx`（固件推荐区间），或发送 `0 RPM`
- 让规则/曲线能突破「只提速不压低」的安全下限
- 在 GUI 进程里直接以 root 写 SMC，或放宽 helper 的客户端签名校验
- 移除租约看门狗，或让异常退出路径不返还系统控制
- 引入网络请求、遥测、自动更新框架（除非先开 issue 讨论）

## Fork 构建必读：先改 bundle id

这是最容易踩的坑。`cn.lovexiaov.fun.fan` 是本项目维护者的标识，helper 也挂在同一个根下。**如果你 fork 后在本地直接构建并安装 helper，它会和你机器上已经装的正版 helper 抢同一个 launchd label**（`cn.lovexiaov.fun.fan.helper`），表现为两个 helper 同时写 SMC：风扇忽快忽慢，退出后还不返还。

所以 fork 构建前，把标识改成你自己的：

| 文件 | 要改什么 |
|---|---|
| `FunFanCore/XPC/HelperProtocol.swift` | `HelperConstants.identifierRoot` |
| `packaging/Info.plist` | `CFBundleIdentifier` |
| `packaging/cn.lovexiaov.fun.fan.helper.plist` | 文件名、`Label`、`MachServices` 的键、`AssociatedBundleIdentifiers`、`StandardErrorPath` |
| `scripts/build-app.sh` | `BUNDLE_ID`、`HELPER_ID`、plist 源文件路径 |
| `scripts/install-helper.sh` | `LABEL` |
| `Tests/FunFanCoreTests/HelperInstallScriptTests.swift` | 测试里的 label / 二进制路径 |
| `.github/workflows/release.yml` | 产物校验里的期望 bundle id |

改完跑 `make test`，再 `make install-helper`。之前的旧 helper 记得先 `make uninstall-helper`。

## 关于许可证

贡献的代码按仓库的 [MIT License](LICENSE) 授权。提交 PR 即表示你同意这一点，并确认你有权提交这些代码（没有从别处抄来不兼容许可证的实现）。
