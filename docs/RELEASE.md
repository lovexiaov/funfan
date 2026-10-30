# 发布手册（FunFan）

> 目标读者：要打一个能发给别人的包的自己。
> 现状：脚本齐全，但**公证成功路径尚未在本机验证**（开发机没有 Developer ID 证书）。
> 第一次真正出包时，请把本文当成清单逐条打勾，并把实际输出补回 `tasks/todo.md`。

---

## 0. 一次性准备

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
make test          # 268 个单测必须全绿
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

## 2. 发出去之前的人工验收

在**另一台**（或至少把 `dist/` 清过、Gatekeeper 有真实上下文的）机器上：

- [ ] 双击 DMG 挂载，拖进「应用程序」，首次打开**不出现**「无法验证开发者」；
- [ ] 菜单栏出现风扇图标，无 Dock 图标、无 ⌘Tab 项；
- [ ] 温度与风扇转速有真实读数（不是 `—`）；
- [ ] 设置 → 风扇控制组件 → 安装 → 系统弹**一次**授权 → 状态变「已安装」；
- [ ] 切「固定 3000 RPM」，`funfanctl status` 看到模式 `manualFixed`、目标 3000；
- [ ] 退出 App，10 s 内 `funfanctl status` 回到 `automatic`；
- [ ] 系统设置 → 通用 → 登录项与扩展：后台项显示在 FunFan 名下，可开关。

---

## 3. 常见失败与处理

| 现象 | 原因 | 处理 |
|---|---|---|
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

## 4. 版本号

- `VERSION` 文件是唯一来源（`CFBundleShortVersionString`）；
- `CFBundleVersion` 取 `git rev-list --count HEAD`，单调递增、可复现，不用手填；
- 发版前把 `VERSION` 改好并**单独提交一次**，让「版本号变更」在历史上可查。
