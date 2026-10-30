# 发布手册（FunFan）

> 目标读者：要打一个能发给别人的包的自己。
> 现状：**已决定不购买 Developer ID 证书**，对外发未公证内测包（`make publish-unsigned`）。
> 签名 + 公证的链路完整保留，只是长期不启用；有证书时按 `## 0` 准备、用 `make publish`。
> 第一次真正出包时，请把本文当成清单逐条打勾，并把实际输出补回 `tasks/todo.md`。

---

## 0. 一次性准备

> **当前不走这条路。** 下面的证书与凭据都需要付费会员（$99/年），项目已决定不买，
> 日常发布用 `make publish-unsigned` 直接跳到 `## 2`。这一节保留给「哪天买了证书」。

| 需要什么 | 怎么拿到 | 验证命令 |
|---|---|---|
| Developer ID Application 证书 | Xcode → Settings → Accounts → Manage Certificates → `+` → Developer ID Application | `security find-identity -v -p codesigning` |
| 公证凭据（App 专用密码） | [appleid.apple.com](https://appleid.apple.com) 生成 App 专用密码，然后存进钥匙串 | `make notary-check` |

```bash
xcrun notarytool store-credentials funfan-notary \
  --apple-id "you@example.com" \
  --team-id  "TEAMID" \
  --password "xxxx-xxxx-xxxx-xxxx"
```

`funfan-notary` 可用 `FUNFAN_NOTARY_PROFILE` 覆盖。

---

## 1. 出包

```bash
make test          # 281 个单测必须全绿
make notary-check  # 体检：缺什么会直接说，不猜
make notarize      # 签名 → DMG → 公证 → 装订 → Gatekeeper 验收
```

`make notarize` 内部顺序（每一步失败都会停在原地并给退出码）：

1. `scripts/build-app.sh --identity "<Developer ID ...>"`：重建 `.app`，**先签 helper 再签 App**，开硬运行时；
2. 提交前预检：`codesign --verify`、`flags` 含 `runtime`、无 `get-task-allow`、helper 单独验签；
3. `scripts/make-dmg.sh`：打 DMG（有证书顺带签 DMG）；
4. `notarytool submit --wait`：非 `Accepted` 自动拉 `notarytool log`；
5. `stapler staple` + `spctl` 验收。

只想要本机可用的包（不发人）时用 `make app`，产物是 adhoc 签名，Gatekeeper 会拒，这是预期。

---

## 2. 发 GitHub Release

```bash
make publish-dry         # 演练：单测 → 打包 → 打印将执行的 gh 命令，不创建 release
make publish-unsigned    # 真发（当前默认路径）：未公证内测包
make publish             # 真发（需证书）：单测 → 签名/公证 → DMG + ZIP → 建草稿
```

脚本是 `scripts/release.sh`，版本号取自 `VERSION`，tag 为 `v<版本>`。

跑之前它会先挡掉下面这些情况（每条都直接说原因，不猜）：

| 检查 | 为什么挡 |
|---|---|
| 不在 `main`、工作区不干净 | 发布的产物必须能对应到某个提交，否则出问题无法复现 |
| 本地落后或领先 `origin/main` | 远端的 tag 会指向一个别人拉不到的提交 |
| 本地或远端已有 `v<版本>` | 重发要走 `gh release upload --clobber`，不该静默覆盖已发布的产物 |
| 没有 Developer ID 证书 / 公证凭据 | adhoc 包在别人机器上会被 Gatekeeper 直接拒，发出去等于废包 |

`--allow-unsigned` 可以绕过最后一条，生成的是**内测包**：release notes 里会自动插入 `xattr -dr com.apple.quarantine` 的解除办法。`make publish-unsigned` 就是这条命令——当前项目一直用这个。

**默认建草稿**（`--draft`），要在网页上核对附件和说明之后点 Publish。理由：Release 一旦公开，下载链接、release 页面和各类镜像立刻可见，撤回也会留痕，而这中间没有第二次机会给你换产物。想一步到位用 `--publish`。

每次发三个附件：

| 文件 | 给谁 |
|---|---|
| `FunFan-<版本>.dmg` | 人工下载，带「拖进应用程序」的引导 |
| `FunFan-<版本>.zip` | 自动更新器（Sparkle 之类只认 zip 里的 `.app`，`ditto` 打包以保住签名） |
| `SHA256SUMS.txt` | `shasum -a 256 -c SHA256SUMS.txt` |

Release notes 由「上一个 tag 到 HEAD」的提交标题生成，外加固定的安装说明；`VERSION` 带 `-beta` 这类后缀时会自动标为预发布。想手写就 `--notes <文件>`：

```bash
./scripts/release.sh --notes release-notes/v1.1.0.md
```

---

## 3. 发出去之前的人工验收

在**另一台**（或至少把 `dist/` 清过、Gatekeeper 有真实上下文的）机器上：

未公证包（当前形态）要特别确认这条链路真的走得通——这是唯一挡在用户面前的东西：

- [ ] 双击 DMG 挂载，拖进「应用程序」；
- [ ] 双击 FunFan **被拦**（预期），提示是「Apple 无法验证」而不是「已损坏」；点「完成」不点「移到废纸篓」；
- [ ] 系统设置 → 隐私与安全性 → 安全性：出现「"FunFan" 已被阻止」+「仍要打开」，点了之后 Touch ID/密码确认，App 正常启动；
- [ ] 上一步完成后，**关掉再双击**能直接开，不再拦；
- [ ] 装完 DMG 就卸载，别从挂载的镜像里运行（否则 App Translocation 会让后台组件装不上）；

已公证包额外确认：

- [ ] 首次打开**不出现**「无法验证开发者」。

两者都要过：

- [ ] 菜单栏出现风扇图标，无 Dock 图标、无 ⌘Tab 项；
- [ ] 温度与风扇转速有真实读数（不是 `—`）；
- [ ] 设置 → 风扇控制组件 → 安装 → 系统弹**一次**授权 → 状态变「已安装」；
- [ ] 切「固定 3000 RPM」，`funfanctl status` 看到模式 `manualFixed`、目标 3000；
- [ ] 退出 App，10 s 内 `funfanctl status` 回到 `automatic`；
- [ ] 系统设置 → 通用 → 登录项与扩展：后台项显示在 FunFan 名下，可开关；
- [ ] 从 GitHub Release 页面下载的包与本地 `dist/` 里的 SHA-256 一致。

---

## 4. 常见失败与处理

| 现象 | 原因 | 处理 |
|---|---|---|
| 用户反馈「已损坏，无法打开」（不是「无法验证」） | 从挂载的 DMG 里直接运行，走了 App Translocation 的随机只读路径 | 先拖进 `/Applications`，卸载镜像，再启动；仍不行则 `xattr -dr com.apple.quarantine /Applications/FunFan.app` |
| 系统设置里找不到「仍要打开」按钮 | 该按钮只在尝试打开后约 1 小时内出现 | 重新双击一次 App 让它再被拦，再回设置页 |
| `spctl` 仍 rejected | 没装订或公证没过 | `xcrun stapler validate <产物>`；重跑 `make notarize` |
| 公证 `Invalid`，日志提到 `not signed` | 包内有未签名的可执行文件 | 检查 `.app/Contents/MacOS/` 下每个文件都已签名（脚本已按 helper→App 顺序签） |
| 公证 `Invalid`，日志提到 `hardened runtime` | 少了 `--options runtime` | `make notary-check` 会直接指出 |
| 公证 `Invalid`，日志提到 `get-task-allow` | 用了开发签名/调试 entitlements | 确认 `packaging/*.entitlements` 没被改 |
| 设置里安装报 `SMAppServiceErrorDomain 1` | adhoc 签名或 App 在桌面/下载 | 安装器会自动回退到「管理员授权直装」；想走系统登记就先签名 + 拖进 /Applications |
| 「一键安装」弹密码后失败 | 脚本某一步报错（权限/路径/launchd） | 看弹窗里的 stderr 摘要；`sudo /bin/bash -c` 手动跑同一份命令可复现，日志在 `/var/log/com.funfan.helper.log` |
| 直装组件与系统登记同时存在 | 先脚本装过，又走了 App 安装 | 「一键安装」会先 `bootout` 再覆盖，路径与 label 相同，不会共存两份 |
| 状态一直是「待批准」 | 用户没在系统设置里批准 | 点「去批准」跳转；App 重新激活时会自动刷新 |
| 风扇忽快忽慢 | 两个控制软件在抢 | FunFan 会检测到手动模式并拒绝接管；退出对方软件后点「重新检测」 |

---

## 5. 版本号

- `VERSION` 文件是唯一来源（`CFBundleShortVersionString`）；
- `CFBundleVersion` 取 `git rev-list --count HEAD`，单调递增、可复现，不用手填；
- 发版前把 `VERSION` 改好并**单独提交一次**，让「版本号变更」在历史上可查；
- `make publish` 会按 `VERSION` 打 tag，所以**改版本号 → 提交 → 发布**是固定顺序，
  不要在发布之后再补改 `VERSION`（那样 tag 与包内版本会不一致）。
