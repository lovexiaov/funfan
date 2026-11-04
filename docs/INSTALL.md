# 安装与卸载

> 使用者文档，从 [README](../README.md) 拆出。发行包是 **adhoc 签名、未经公证** 的 alpha 预发布版，首次启动需要手动放行一次；发布侧的操作清单见 [RELEASE.md](RELEASE.md)，命令行见 [CLI.md](CLI.md)。

## 从 Releases 安装

从 [Releases](https://github.com/lovexiaov/funfan/releases) 下载最新版的 `FunFan-<版本>.dmg`，按下面四步安装。目前发布的都是 **alpha 预发布版**，每个版本附三个附件：给人下载的 DMG、给自动更新器的 ZIP、校验用的 `SHA256SUMS.txt`。

> **装过早期 alpha 包请先清残留。** `v1.0.0-alpha.1` / `v1.0.0-alpha.2` 由改名前的 bundle id（`com.funfan`）构建，会在机器上留下一个旧后台组件，与新版本共存时会和新 helper 抢同一个风扇；这两个包已撤回。装过它们的机器，先按下面「清理改名前的残留」一节清一遍，再装新版。

> **分发包没有 Apple 签名证书，也没有经过公证。** FunFan 是个人项目，没有加入 Apple Developer Program（$99/年），产物是 adhoc 签名，macOS 会拦它一次，需要你手动放行。功能完全不受影响，代价只是首次启动多两步。信不过就看下面「从源码构建」，自己编出来的包不会有这道拦截。

**1. 校验（可选，但建议）**

三个附件都下载到同一个目录（通常是「下载」），在终端执行：

```bash
cd ~/Downloads && shasum -a 256 -c SHA256SUMS.txt
```

**2. 拖进「应用程序」**

双击 DMG，把 FunFan 拖到「应用程序」。**不要在 DMG 里直接运行**——从挂载的镜像里启动会走 App Translocation（随机只读路径），表现为弹「已损坏，无法打开」，而且后台组件会装不上。

**3. 放行一次**

双击 FunFan，会弹「Apple 无法验证「FunFan」是否包含恶意软件」。点**完成**（不要点「移到废纸篓」），然后：

```
系统设置 → 隐私与安全性 → 向下滚到「安全性」
→ 看到「FunFan 已被阻止以保护你的 Mac」→ 点「仍要打开」→ Touch ID 或密码确认
```

两个细节容易让人卡住：

- 「仍要打开」按钮只在**尝试打开后约 1 小时内**出现。窗口关了或者过了一小时，重新双击一次 App 让它再被拦一遍，按钮才会回来。
- macOS 15 起**右键 → 打开**这条老捷径已被 Apple 移除，网上大量教程还在教它，现在按了没有用。

不想走设置界面也可以直接清掉隔离属性（等价）：

```bash
xattr -dr com.apple.quarantine /Applications/FunFan.app
```

放行一次即长期有效。**升级到新版本后要再做一次**——每次下载都会重新带上隔离属性。

**4. 启用风扇控制**

菜单栏出现风扇图标 → 点开 → 面板底部「一键启用」→ 输入一次系统密码。之后升级 App 不用再授权，因为装的是一份独立的后台组件，不随 App 重装。

> 只看温度不装这个组件也能用。那份权限**只**用来写风扇转速。

## 从源码构建

需要 macOS 13+ 与 Xcode 命令行工具。自己编出来的包没有隔离属性，双击即开。

```bash
git clone https://github.com/lovexiaov/funfan.git
cd funfan

make build        # 调试构建（含 CLI / helper / probe / GUI）
make test         # 291 个单测
make run          # 启动菜单栏 App
```

只读功能（监控）**不需要 root**。写入风扇要先装一次特权后台组件——**在 App 里点一下就行**，不需要开终端：

```
打开 FunFan → 菜单栏面板底部「一键启用」     （或 设置 → 风扇控制组件 → 一键安装）
```

安装器会自己挑路线，两种都只打扰你一次：

| 情况 | 走哪条路 | 你会看到 |
|---|---|---|
| Developer ID 签名的正式包 | `SMAppService` 系统登记 | 系统设置里「允许」一次，之后随 App 升级不再问 |
| adhoc / 开发构建 / 已被脚本装过 | 管理员授权直装 `/Library/PrivilegedHelperTools` | 一次系统密码框 |

命令行等价物（开发期或排障用）：

```bash
make app && open dist/FunFan.app   # 装好后从 App 里点按钮
make install-helper                # 或脚本直装，每次都要 sudo
```

装完验证：

```bash
./.build/release/funfanctl doctor      # 确认硬件与权限
sudo ./.build/release/funfanctl spin --rpm 2950 --seconds 6   # 写入验证，结束自动返还
```

两种安装落在**同一个路径、同一个 label**（`cn.lovexiaov.fun.fan.helper`），所以彼此互斥；「一键安装」会自动 `bootout` 旧进程再覆盖，不需要先手动卸载。反过来，App 装过之后脚本会拒绝安装并说明原因（防止两个写手抢同一个 Mach service）。

## 卸载

推荐的卸载顺序：先在 App 设置里点「卸载组件」，再删 App。脚本直装的用 `sudo bash scripts/install-helper.sh uninstall`。

直接把 App 拖进废纸篓也不会留下失控的 root 进程：daemon 会检测宿主消失（每 60 s 查一次、连续约 3 分钟确认，防外置卷瞬时卸载误判），先返还风扇控制，再删掉自己的注册与文件。两个已知边界：① 脚本直装版要daemon「认识」宿主才会监视——安装时传 `--app <路径>`（不传则自动探测 `dist/FunFan.app`）；② 「删 App → 重启」的顺序下，包内安装的 daemon 随 App 一起消失，自清无从发生，系统设置里会残留一条指向空路径的后台项（无害，不会执行任何代码）。

## 清理改名前的残留

bundle id 从 `com.funfan.*` 迁到 `cn.lovexiaov.fun.fan` 之后，机器上的旧痕迹不会自己消失：旧 daemon 还注册着 `com.funfan.helper` 这个 Mach service，会和新 helper 同时写 SMC（风扇忽快忽慢、App 退出后不返还）。

```bash
bash scripts/purge-legacy.sh                  # 体检：只列出会清什么，不动手
sudo bash scripts/purge-legacy.sh --apply     # 真清（系统侧 + 用户侧）
```

默认保留 `~/Library/Application Support/FunFan`（规则 / 曲线 / 诊断报告）；要一并清掉加 `--with-user-data`，它是**移进废纸篓**而不是删除，随时能捞回。要从零重装验证加 `--incl-current`，连新 helper 一起卸。

## 风险提示

> **改风扇转速有风险。** 底层 SMC 接口未公开，系统升级后可能失效或行为改变。所有写入都会收敛到系统区间与安全下限、绝不发送 0 RPM，但请自行承担使用风险；出现异常先切回「自动」。

安全边界（只写 `F0Tg`、绝不写 0 RPM、退出即返还）见 [ARCHITECTURE.md](ARCHITECTURE.md)，信任模型与漏洞上报见 [SECURITY.md](../SECURITY.md)。
