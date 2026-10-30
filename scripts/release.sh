#!/bin/bash
# FunFan —— 一条命令发 GitHub Release
#
# 用法：
#   bash scripts/release.sh --dry-run          # 全流程跑到打包结束，只打印 gh 命令，不建 release
#   bash scripts/release.sh                    # 单测 → 签名/公证 → 打包 → 建「草稿」release
#   bash scripts/release.sh --publish          # 同上，但直接公开（不推荐首次就用）
#   bash scripts/release.sh --prerelease       # 标为预发布（VERSION 带 -beta 之类时自动开）
#   bash scripts/release.sh --allow-unsigned   # 允许发 adhoc 包（Gatekeeper 会拦，仅内测用）
#   bash scripts/release.sh --skip-tests       # 跳过单测（重试上传时用）
#   bash scripts/release.sh --skip-build       # 复用 dist/ 里已有的产物
#   bash scripts/release.sh --notes <file.md>  # 用自定义 release notes
#
# 版本号唯一来源是仓库根的 VERSION 文件；tag 为 `v<VERSION>`。
#
# 为什么默认建草稿而不是直接公开：
#   GitHub Release 一旦 Public，下载链接、release 页面、各类镜像与自动更新源
#   立刻可见，撤回也留痕。草稿状态可以先在网页上核对附件大小、校验和与说明，
#   点一次 Publish 才真正生效——这中间没有第二次机会给你改产物。
#
# 为什么没有 Developer ID 就拒绝：
#   adhoc 签名的包下到别人机器上会被 Gatekeeper 直接拒（「无法验证开发者」），
#   等于发了一个装不上的包。默认挡在这里，要发内测包必须显式 --allow-unsigned。
#
# 退出码：0 成功 / 2 前置条件不齐（工作区、tag、签名）/ 3 构建或公证失败

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

DRY_RUN=0
PUBLISH=0
PRERELEASE=0
ALLOW_UNSIGNED=0
SKIP_TESTS=0
SKIP_BUILD=0
NOTES_FILE=""

die() { echo "✗ $1" >&2; exit "${2:-1}"; }
step() { echo "→ $*"; }
ok() { echo "✓ $*"; }
warn() { echo "! $*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --publish) PUBLISH=1; shift ;;
    --prerelease) PRERELEASE=1; shift ;;
    --allow-unsigned) ALLOW_UNSIGNED=1; shift ;;
    --skip-tests) SKIP_TESTS=1; shift ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --notes) NOTES_FILE="${2:-}"; shift 2 ;;
    --notes=*) NOTES_FILE="${1#*=}"; shift ;;
    -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "未知参数：$1（用 --help 看用法）" ;;
  esac
done

# 演练时不该因为「tag 已存在」而中断——那正是重跑的场景
check() {
  if [ "$DRY_RUN" -eq 1 ]; then warn "$1"; else die "$1" 2; fi
}

# MARK: - 版本与 tag

[ -f VERSION ] || die "找不到 VERSION 文件"
VERSION="$(tr -d ' \n' < VERSION)"
[ -n "$VERSION" ] || die "VERSION 文件是空的"
TAG="v$VERSION"

# semver 的预发布段就是 `-` 之后，形如 1.1.0-beta.1
case "$VERSION" in
  *-*) PRERELEASE=1 ;;
esac

echo
echo "FunFan $VERSION（tag $TAG）$( [ "$PRERELEASE" -eq 1 ] && echo ' [预发布]')"
echo

# MARK: - 前置检查

step "检查工具与仓库状态 …"

command -v gh >/dev/null 2>&1 || die "找不到 gh（brew install gh）" 2
gh auth status >/dev/null 2>&1 || die "gh 未登录（gh auth login）" 2

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[ "$BRANCH" = "main" ] || check "当前分支是 $BRANCH，不是 main"

if [ -n "$(git status --porcelain)" ]; then
  check "工作区不干净，先提交或 stash（发布产物必须能从某个提交复现）"
fi

git fetch origin --quiet 2>/dev/null || check "git fetch 失败（离线？）"
BEHIND="$(git rev-list --count 'HEAD..origin/main' 2>/dev/null || echo 0)"
[ "$BEHIND" -eq 0 ] || check "本地落后 origin/main $BEHIND 个提交"
AHEAD="$(git rev-list --count 'origin/main..HEAD' 2>/dev/null || echo 0)"
[ "$AHEAD" -eq 0 ] || check "有 $AHEAD 个提交还没推送——远端 tag 会指向别人拉不到的提交"

if git rev-parse --verify --quiet "refs/tags/$TAG" >/dev/null; then
  check "本地已有 tag $TAG（要重发请先 git tag -d $TAG && git push origin :refs/tags/$TAG）"
fi
if gh release view "$TAG" >/dev/null 2>&1; then
  check "GitHub 上已有 release $TAG（补附件用 gh release upload $TAG <文件> --clobber）"
fi
ok "仓库状态可用"

# MARK: - 单测

if [ "$SKIP_TESTS" -eq 0 ]; then
  step "跑单测 …"
  LOG="$(mktemp)"
  if ! swift test --disable-sandbox >"$LOG" 2>&1; then
    tail -20 "$LOG"
    rm -f "$LOG"
    die "单测失败，不发布" 3
  fi
  grep -E "Executed .* tests" "$LOG" | tail -1 | sed 's/^/    /'
  rm -f "$LOG"
  ok "单测通过"
else
  warn "已跳过单测（--skip-tests）"
fi

# MARK: - 构建与签名

DMG="dist/FunFan-$VERSION.dmg"
ZIP="dist/FunFan-$VERSION.zip"
NOTARIZED=0

if [ "$SKIP_BUILD" -eq 0 ]; then
  if [ "$DRY_RUN" -eq 1 ] || [ "$ALLOW_UNSIGNED" -eq 1 ]; then
    step "构建（不公证）…"
    bash scripts/build-app.sh || die "打包失败" 3
    bash scripts/make-dmg.sh || die "打 DMG 失败" 3
  else
    # 证书与公证凭据齐才走完整链路；不齐就把它缺什么原样抛出来，
    # 而不是等到用户下载后被 Gatekeeper 拒。
    step "检查签名与公证前置条件 …"
    bash scripts/notarize.sh --check >/dev/null 2>&1
    CHECK_STATUS=$?
    if [ "$CHECK_STATUS" -ne 0 ]; then
      bash scripts/notarize.sh --check || true
      die "签名/公证前置条件不齐（上面是缺什么）。只想发内测包请加 --allow-unsigned" 2
    fi
    step "签名 → 公证 → 装订 → 验收 …"
    bash scripts/notarize.sh || die "公证流程失败" 3
    NOTARIZED=1
  fi
else
  warn "已跳过构建（--skip-build），复用 dist/ 里的现有产物"
fi

[ -f "$DMG" ] || die "找不到 $DMG" 3
[ -d dist/FunFan.app ] || die "找不到 dist/FunFan.app" 3

# 兜底：--skip-build 复用的是别人（可能是几小时前）打出来的包，
# 不能因为跳过了构建就跳过这道门。adhoc 包发上去，用户下载后打不开。
SIGNED_TEAM="$(codesign -dv --verbose=4 dist/FunFan.app 2>&1 \
  | sed -n 's/^TeamIdentifier=//p' | head -1)"
case "$SIGNED_TEAM" in
  "not set") SIGNED_TEAM="" ;;
esac
if [ -z "$SIGNED_TEAM" ] && [ "$ALLOW_UNSIGNED" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
  die "dist/FunFan.app 是 adhoc 签名（没有 Team ID），发出去会被 Gatekeeper 拒。想发内测包请加 --allow-unsigned" 2
fi
if [ -n "$SIGNED_TEAM" ]; then
  ok "签名 Team ID：$SIGNED_TEAM"
fi

# MARK: - 附件

# zip 是给自动化用的（Sparkle 之类的更新器只认 zip 里的 .app），
# DMG 是给人用的（带「拖进应用程序」的引导）。两个都发。
step "打 zip（给自动更新用）…"
rm -f "$ZIP"
ditto -c -k --keepParent dist/FunFan.app "$ZIP" || die "打 zip 失败" 3

step "生成校验和 …"
( cd dist && shasum -a 256 "FunFan-$VERSION.dmg" "FunFan-$VERSION.zip" > SHA256SUMS.txt ) \
  || die "生成校验和失败" 3
SUMS="dist/SHA256SUMS.txt"

# MARK: - Release notes

NOTES_TMP="$(mktemp -t funfan-notes)"
CHANGES_TMP="$(mktemp -t funfan-changes)"

if [ -n "$NOTES_FILE" ]; then
  [ -f "$NOTES_FILE" ] || die "找不到 notes 文件：$NOTES_FILE"
  cp "$NOTES_FILE" "$NOTES_TMP"
else
  # 上一个 tag 到 HEAD 的提交标题。没有历史 tag 就是全部提交。
  PREV_TAG="$(git describe --tags --abbrev=0 2>/dev/null || true)"
  if [ -n "$PREV_TAG" ]; then
    RANGE="$PREV_TAG..HEAD"
  else
    RANGE="HEAD"
  fi
  # 直接落文件，不经 heredoc/printf —— 提交标题里有反引号（键名、命令），
  # 任何一句被 shell 当成命令替换都会静默改掉 release notes。
  git log --pretty=format:'- %s' --no-merges "$RANGE" > "$CHANGES_TMP"

  {
    printf '### 安装\n\n'
    printf '1. 下载 `FunFan-%s.dmg`，双击打开\n' "$VERSION"
    printf '2. 把 FunFan 拖进「应用程序」，再卸载镜像（**别在 DMG 里直接运行**，那样会报「已损坏」）\n'
    if [ "$NOTARIZED" -eq 0 ]; then
      printf '3. 双击 FunFan：macOS 会拦一次「Apple 无法验证」\n'
      printf '4. 点「完成」（**不要**点「移到废纸篓」），然后 **系统设置 → 隐私与安全性 → 安全性 → 仍要打开**，用 Touch ID 或密码确认\n\n'
    else
      printf '3. 双击 FunFan：菜单栏出现风扇图标即完成，不需要安装包\n\n'
    fi
    printf '> 控制风扇需要安装一次后台组件：\n'
    printf '> 菜单栏图标 → 面板底部「一键启用」→ 输入一次系统密码。\n'
    printf '> 组件只在你操作时写风扇，FunFan 退出/睡眠/合盖都会立刻交还系统。\n\n'
    if [ "$NOTARIZED" -eq 0 ]; then
      printf '### ⚠️ 这个包没有经过公证\n\n'
      printf '项目没有购买 Apple Developer Program（$99/年），产物是 adhoc 签名，所以 macOS 会拦一次。'
      printf '按上面第 3–4 步放行一次即可长期使用；**每次升级都要重复**，因为下载会重新带上隔离属性。\n\n'
      printf '找不到「仍要打开」按钮（它只在尝试打开后约 1 小时内出现），或者你更习惯打命令：\n\n'
      printf '```bash\n'
      printf 'xattr -dr com.apple.quarantine /Applications/FunFan.app\n'
      printf '```\n\n'
    fi
    printf '### 变更\n\n'
  } > "$NOTES_TMP"
  cat "$CHANGES_TMP" >> "$NOTES_TMP"
  {
    # git log 的最后一行的末尾没有换行符，这里补齐标题前必须的空行
    printf '\n\n'
    printf '### 校验\n\n'
    printf '```bash\n'
    printf 'shasum -a 256 -c SHA256SUMS.txt\n'
    printf '```\n\n'
    printf '### 系统要求\n\n'
    printf 'macOS 13 Ventura 或更高，Apple Silicon（M1 及以上）。\n'
  } >> "$NOTES_TMP"
fi
rm -f "$CHANGES_TMP"

if [ "$DRY_RUN" -eq 1 ]; then
  echo
  echo "──── 生成的 release notes ────"
  cat "$NOTES_TMP"
  echo "──────────────────────────────"
fi

# MARK: - 发布

GH_ARGS=(release create "$TAG" "$DMG" "$ZIP" "$SUMS"
  --title "FunFan $VERSION"
  --notes-file "$NOTES_TMP"
  --verify-tag)
[ "$PRERELEASE" -eq 1 ] && GH_ARGS+=(--prerelease)
[ "$PUBLISH" -eq 0 ] && GH_ARGS+=(--draft)

if [ "$DRY_RUN" -eq 1 ]; then
  echo
  echo "（演练，未执行以下命令）"
  echo "  git tag -a \"$TAG\" -m \"FunFan $VERSION\""
  echo "  git push origin \"$TAG\""
  echo -n "  gh "
  printf '%q ' "${GH_ARGS[@]}"
  echo
  rm -f "$NOTES_TMP"
  echo
  ok "演练完成。附件：$DMG / $ZIP / $SUMS"
  exit 0
fi

step "打 tag $TAG …"
git tag -a "$TAG" -m "FunFan $VERSION" || die "打 tag 失败" 3
git push origin "$TAG" || die "推 tag 失败" 3

step "创建 GitHub release …"
if ! gh "${GH_ARGS[@]}"; then
  rm -f "$NOTES_TMP"
  warn "release 创建失败。tag 已经推上去了，产物仍在 dist/；"
  warn "排查后可以直接补：gh release create $TAG dist/*.dmg dist/*.zip $SUMS --title \"FunFan $VERSION\" --draft"
  die "发布失败" 3
fi
rm -f "$NOTES_TMP"

URL="$(gh release view "$TAG" --json url -q .url 2>/dev/null || true)"
echo
if [ "$PUBLISH" -eq 0 ]; then
  ok "已创建草稿 release：${URL:-（用 gh release view $TAG 查看）}"
  echo "  核对附件与说明后，点页面上的 Publish release 正式发布。"
  echo "  确认无误也可以直接：gh release edit $TAG --draft=false"
else
  ok "已发布：${URL:-（用 gh release view $TAG 查看）}"
fi
