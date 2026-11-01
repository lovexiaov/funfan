# Homebrew 发布调研（FunFan）

> 调研日期：2026-10-31。依据：Homebrew 官方文档（Tap-Trust / Acceptable-Casks /
> Package-Acceptance-Policy / Cask-Cookbook / How-to-Create-and-Maintain-a-Tap /
> Supply-Chain-Security）、Homebrew 5.0/6.0 发行公告，以及本机实测
> （Homebrew 7.0.11，macOS 27.0.1）。
> 结论先行：**当前形态（adhoc 签名、无 Developer ID 证书）接不进 Homebrew**，
> 无论官方仓库还是自建 tap。模板和步骤已备好（见 §6/§7），等证书一到即可启用。

---

## 1. 三条路线一览

| 路线 | 现在可行？ | 硬前提 |
|---|---|---|
| A. 官方 `homebrew-cask`（GUI App） | ❌ | Developer ID 签名 + 公证（2026-09-01 起强制）；知名度门槛 75 stars / 30 forks（自提交 225 stars / 90 forks）；公开的版本化 Release + livecheck |
| B. 自建 tap + cask | ❌（有证书后 ✅） | 同样的 Gatekeeper 墙（见 §2），与知名度无关 |
| C. formula 分发 `funfanctl`（源码构建，不过 Gatekeeper） | ⚠️ 技术可行但无意义 | `funfanctl` 依赖特权 helper（XPC → `cn.lovexiaov.fun.fan.helper`）才碰得了 SMC，单装 CLI 没有功能 |

---

## 2. 为什么 adhoc 包过不了 cask（决定性因素）

1. **政策**：Homebrew 5.0 起将「未通过 codesign + notarization 的 cask」标记为
   deprecated，**2026-09-01 起正式禁用并从官方 tap 移除**。Acceptable Casks 现行
   条文：*「On macOS, apps, installers and other executable artefacts that
   Gatekeeper can assess must pass Homebrew's Gatekeeper checks and must not
   require System Integrity Protection or Gatekeeper to be disabled or
   bypassed.」* Developer ID 签名 → 公证 → 装订是唯一过法。
2. **`--no-quarantine` 已死**：Homebrew 5.0 弃用、现行版本已移除。本机实测
   （brew 7.0.11）：`brew install --help` 与 manpage 中 quarantine 相关参数
   **0 处匹配**。也就是说用户没有任何 brew 侧的绕过手段。
3. **后果比现状更糟**：cask 下载的 .app 会被打上 `com.apple.quarantine`。
   adhoc 签名 + 隔离属性在 Apple Silicon 上典型表现是**「已损坏，无法打开」**——
   连「Open Anyway」都没有，用户只能手动 `xattr -dr com.apple.quarantine`。
   而现在 GitHub 直装 DMG 的路径至少还走「系统设置 → 仍要打开」。
   **结论：没有证书时做 cask 是负体验，不做。**

---

## 3. 官方 homebrew-cask 的完整门槛（买了证书之后还要过的）

- **签名 + 公证**：如上。
- **知名度（Notability）**：至少 **30 forks / 30 watchers / 75 stars**；
  本人自提交（仓库 owner 或 email 在 url/homepage 域名的作者）门槛抬到
  **90 forks / 90 watchers / 225 stars**。仓库需公开、≥30 天、独立维护。
- **发布形态**：公开的、按版本固定的下载 URL（GitHub Release 正好）；必须有
  可用的 `livecheck`（`strategy :github_releases` 即可）；release 不能是草稿。
- **cask 结构硬性要求**：新提交**必须带 `zap`**（无可清理内容写
  `zap :not_required`）；提交前过 `brew style --cask` 和
  `brew audit --cask --new --online`。
- 一句话：知名度是最大的非技术门槛，alpha 阶段不用想。

## 4. 自建 tap（推荐的中间站）

买了证书但知名度不够时，自建 tap 是标准做法，用户侧一行命令：

```bash
brew install --cask lovexiaov/tap/funfan
```

搭法（一次性）：

1. 建 GitHub 公开仓库 `lovexiaov/homebrew-tap`（名字必须 `homebrew-` 前缀，
   短名 `lovexiaov/tap` 才生效），顶层建 `Casks/` 目录。
2. cask 文件放 `Casks/funfan.rb`（模板见 §7）。
3. 每次发版：Release 发布（非草稿）后，更新 cask 里的 `version` + `sha256`
   提交推送即可，用户 `brew upgrade` 自动跟上。可让 `scripts/release.sh`
   顺手算出 sha256 片段贴进 cask（待办，见 §8）。
4. **Tap trust（Homebrew 6.0+ 新机制）**：第三方 tap 的 Ruby 会被执行，默认
   不信任。但用**全限定名安装**（`brew install --cask lovexiaov/tap/funfan`）
   只信任这一个 cask，无需用户额外 `brew trust`——对个人分发刚好够用，
   文档里就这么推荐。

## 5. formula 路线为什么不适配

从源码构建的 formula 走 curl 下载 + 本机编译，产物不带 quarantine，
**不需要证书也能进官方 homebrew-core 或自建 tap**——这是唯一的免证书口子。
但 FunFan 的核心（SMC 读写、风扇控制）必须经特权 helper；`funfanctl`
脱离 helper 只有 `--help` 能用。GUI App 也装不进 formula（.app 归 cask 管）。
除非未来把「只读监控」做成无 helper 也可用的独立 CLI，否则此路线搁置。

## 6. FunFan 专属 cask 技术要点

- `depends_on macos: :ventura`（Info.plist `LSMinimumSystemVersion` = 13.0）。
- **卸载 helper**：helper 走 SMAppService daemon（label `cn.lovexiaov.fun.fan.helper`，
  可执行文件在 App 包内，不在 `/Library/LaunchDaemons` 落盘 plist）。
  cask 的 `uninstall launchctl:` 用 `launchctl bootout system/cn.lovexiaov.fun.fan.helper`
  思路可行但**需真机实测**（bootout 系统域需要 root，brew 卸载默认无 sudo）。
  兜底：cask `uninstall` 加一段 `sudo: true` 的 script，或引导用户在
  App 设置页点「卸载组件」。此条是启用 tap 前必须验证的第一项。
- **无自动更新器**：App 内没有 Sparkle，cask 不写 `auto_updates`，让
  `brew upgrade` 管（这正好是 Homebrew 用户预期）。
- `zap` 路径清单（`brew generate-zap` 出稿后人工核对）：偏好、
  Application Support、Caches、Saved State、`/var/log/cn.lovexiaov.fun.fan.helper.log`。
- DMG 结构已是标准「App + Applications 软链」，`app "FunFan.app"` 即可。

## 7. Cask 模板（`Casks/funfan.rb`，启用时按当版填 version/sha256）

```ruby
cask "funfan" do
  version "1.0.0-alpha.2"
  sha256 "发布后由 SHA256SUMS.txt 取 DMG 那一行填入"

  url "https://github.com/lovexiaov/funfan/releases/download/v#{version}/FunFan-#{version}.dmg"
  name "FunFan"
  desc "Menu-bar fan controller for Macs"
  homepage "https://github.com/lovexiaov/funfan"

  livecheck do
    url :url
    strategy :github_releases
  end

  depends_on macos: :ventura

  app "FunFan.app"

  uninstall quit:      "cn.lovexiaov.fun.fan",
            launchctl: "cn.lovexiaov.fun.fan.helper", # SMAppService daemon，bootout 路径需实测
            delete:    "/var/log/cn.lovexiaov.fun.fan.helper.log"

  zap trash: [
    "~/Library/Preferences/cn.lovexiaov.fun.fan.plist",
    "~/Library/Application Support/FunFan",
    "~/Library/Caches/cn.lovexiaov.fun.fan",
    "~/Library/WebKit/cn.lovexiaov.fun.fan",
    "~/Library/Saved Application State/cn.lovexiaov.fun.fan.savedState",
  ]
end
```

验证顺序：`brew style --cask` → `brew audit --cask --new --online` →
真机 `brew install --cask ./Casks/funfan.rb` → 装完走一遍
`docs/RELEASE.md` §3 的人工验收 → 实测 §6 的 helper 卸载。

## 8. 行动清单

- [ ] **决策：买不买 Developer ID（$99/年）**。它同时解锁：Gatekeeper 正常放行、
      cask 准入、SMAppService 一次授权（当前 adhoc 下必须回退管理员直装）。
      任何 Homebrew 路线都以它为前提，不买则此文档仅存档。
- [ ] 买了证书后：建 `lovexiaov/homebrew-tap`，按 §7 启用 cask，先真机验
      §6 helper 卸载，再公布安装命令。
- [ ] `scripts/release.sh` 加一步：发布后打印 cask 需要的 `version`/`sha256`
      片段（省一次手抄）。
- [ ] 知名度达标（75 stars 且非自提交语境）后，再评估提交官方 homebrew-cask。
