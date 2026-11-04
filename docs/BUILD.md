# 打包与分发（开发参考）

> 从 [README](../README.md) 拆出。**发布操作清单、人工验收、失败处理一律看 [RELEASE.md](RELEASE.md)**；本文只记 README 里那部分背景知识与命令，不重复发布手册的内容。安装与放行见 [INSTALL.md](INSTALL.md)。

## 为什么分发形态必须是 `.app`

SwiftPM 只产出裸可执行文件，而裸二进制**没有 bundle 标识**：`SMAppService`（登录项、特权 helper）一律注册失败，公证工具也没有东西可提交。所以必须先组 `.app`：

```bash
make app          # → dist/FunFan.app（内到外签名，默认 adhoc）
make run-app      # 打包并启动
make sign-info    # 看会自动选用哪个签名身份
make dmg          # 只打 DMG（有证书就顺带签 DMG）
```

包结构：

```
FunFan.app/Contents/
  Info.plist                              LSUIElement=true（菜单栏常驻、无 Dock 图标）
  MacOS/FunFan                            GUI
  MacOS/FunFanHelper                      特权 helper 本体
  Library/LaunchDaemons/cn.lovexiaov.fun.fan.helper.plist   给 SMAppService.daemon 用（BundleProgram 相对路径）
```

版本号唯一来源是仓库根的 `VERSION` 文件；`CFBundleVersion` 取 `git rev-list --count HEAD`，单调递增且可复现。完整的版本号纪律见 [RELEASE.md](RELEASE.md) §5。

## helper 状态的命令行观测

`--helper-status` / `--helper-install` / `--helper-uninstall` 是给验收与脚本用的（必须直接跑包内可执行文件，`open --args` 拿不到 stdout）：

```bash
dist/FunFan.app/Contents/MacOS/FunFan --helper-status     # 0 已可用 / 1 装了没生效 / 2 这个产物装不了
dist/FunFan.app/Contents/MacOS/FunFan --helper-install    # 需要授权时会在终端弹出密码框
```

状态输出把两套记账分开说：`SMAppService` 的系统登记状态，和直装到 `/Library/PrivilegedHelperTools` 的那份是否在、launchd 是否真在跑。混成一句会出现「系统未找到」但风扇明明能控的矛盾。

每一行都会同时写到 `~/Library/Application Support/FunFan/helper-cli.log`——用户报障时直接贴这一段，比「装不上」三个字有用得多。

## 签名身份与证书现状

签名身份的来源顺序：`--identity` 参数 → `FUNFAN_SIGN_IDENTITY` 环境变量 → 自动找 `Developer ID Application` → 回退 adhoc。**adhoc 签名进不了 Gatekeeper，也无法公证**，只够本机调试与开发登录项。

本项目**不打算购买 Developer ID 证书**，所以对外分发就是 [INSTALL.md](INSTALL.md) 描述的形态：adhoc 签名 + 用户手动放行一次。签名与公证的完整链路保留在仓库里，哪天有证书了直接可用，不需要改代码。

`make notarize` 里值得单独记的一条：**提交前预检**（硬运行时缺失、带 `get-task-allow`、helper 签名不通过）被刻意放在第 0 秒——公证一次往返通常 1–5 分钟，让它在第 0 秒失败比在第 5 分钟失败划算。其余流程、凭据准备与验收标准见 [RELEASE.md](RELEASE.md) §0–§1。

## 发版与 CI

本机 `make publish-dry` / `make publish-unsigned`、推 tag 触发 `.github/workflows/release.yml`、以及「两条路别都跑」的原因，全部见 [RELEASE.md](RELEASE.md) §2。这里只补两条发布手册没写的：

- Release notes 的文案由 `scripts/gen-release-notes.sh` 生成，本机脚本和 CI 都调它，所以两边说的一定是同一套话；想手写就放 `release-notes/v<版本>.md`，CI 会优先用它。
- 两条发布路径的取舍：本机 `make publish-unsigned` 会自己建 release 再推 tag，CI 到的时候看见 release 已有完整附件，于是**只做编译验证、不上传覆盖**——用 CI 的包换掉你验过的包，等于悄悄换了用户下载的东西。

未公证包的 release notes 里会自动插入解除隔离属性的命令，内容是 [INSTALL.md](INSTALL.md)「放行一次」的简版——用户从 Release 页面点进来就能看到该怎么做，不必回头翻仓库文档。
