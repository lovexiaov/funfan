#!/bin/bash
# FunFan —— 生成 release notes（本地发布脚本与 CI 共用同一份文案）
#
# 用法：
#   bash scripts/gen-release-notes.sh --version 1.0.0-alpha.1            # 打印到 stdout
#   bash scripts/gen-release-notes.sh --version 1.0.0 --notarized        # 已公证的文案（不写放行步骤）
#   bash scripts/gen-release-notes.sh --version 1.0.0 --range v1..HEAD   # 指定变更区间
#   bash scripts/gen-release-notes.sh --version 1.0.0 --output /tmp/n.md
#
# 为什么单独一个脚本：
#   发布有两条路——本机 `scripts/release.sh`（能签名/公证）和 CI（`.github/workflows/release.yml`，
#   只能 adhoc）。两条路的安装说明、未公证警告、校验命令必须一字不差，否则用户看到的就是
#   两套互相矛盾的说法。文案放在这里，两边都只是调用它。
#
# 退出码：0 成功 / 2 参数或环境不齐

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

VERSION=""
VERSION_GIVEN=0
NOTARIZED=0
RANGE=""
OUTPUT=""

die() { echo "✗ $*" >&2; exit "${2:-2}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION="${2:-}"; VERSION_GIVEN=1; shift 2 ;;
    --version=*) VERSION="${1#*=}"; VERSION_GIVEN=1; shift ;;
    --notarized) NOTARIZED=1; shift ;;
    --range) RANGE="${2:-}"; shift 2 ;;
    --range=*) RANGE="${1#*=}"; shift ;;
    --output) OUTPUT="${2:-}"; shift 2 ;;
    --output=*) OUTPUT="${1#*=}"; shift ;;
    -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "未知参数：$1（用 --help 看用法）" ;;
  esac
done

if [ "$VERSION_GIVEN" -eq 1 ] && [ -z "$VERSION" ]; then
  die "版本号是空的（--version 后面要跟 1.2.3 这样的值）"
fi

if [ -z "$VERSION" ]; then
  VERSION="$(tr -d ' \n' < VERSION 2>/dev/null || true)"
fi
[ -n "$VERSION" ] || die "拿不到版本号（--version 或仓库根的 VERSION 文件）"

# 默认区间：上一个 tag 到 HEAD。没有历史 tag 就是全部提交。
if [ -z "$RANGE" ]; then
  PREV_TAG="$(git describe --tags --abbrev=0 2>/dev/null || true)"
  if [ -n "$PREV_TAG" ]; then RANGE="$PREV_TAG..HEAD"; else RANGE="HEAD"; fi
fi

CHANGES_TMP="$(mktemp -t funfan-changes)"
trap 'rm -f "$CHANGES_TMP"' EXIT

# 变更段优先用 docs/CHANGELOG.md 里「## FunFan <版本>」这一节（人工维护、面向用户），
# 没有对应条目（或该版本还没写）时回退到 git 提交记录，保证任何版本都能出 notes。
# 安装 / 校验 / 系统要求等固定文案仍是脚本单源生成，不在这里重复。
CHANGELOG="docs/CHANGELOG.md"
if [ -f "$CHANGELOG" ]; then
  awk -v v="$VERSION" '
    /^## FunFan / {
      if (found) exit            # 已经过了目标版本，遇到下一个版本标题就停
      rest = $0
      sub(/^## FunFan /, "", rest)
      sub(/\(.*\)/, "", rest)    # 去掉末尾的 (日期)
      gsub(/^[ \t]+|[ \t]+$/, "", rest)
      if (rest == v) { found = 1; next }
      next
    }
    found { print }
  ' "$CHANGELOG" > "$CHANGES_TMP"
fi

# 没提取到内容（CHANGELOG 缺失 / 该版本未写 / 提取失败）就退回 git log。
# 直接落文件，不经 heredoc/printf —— 提交标题里有反引号（键名、命令），
# 任何一句被 shell 当成命令替换都会静默改掉 release notes。
if [ ! -s "$CHANGES_TMP" ]; then
  git log --pretty=format:'- %s' --no-merges "$RANGE" > "$CHANGES_TMP"
fi

# 一次算好正文，再决定输出到文件还是 stdout
emit() {
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
    cat "$CHANGES_TMP"
    # git log 的最后一行的末尾没有换行符，这里补齐标题前必须的空行
    printf '\n\n'
    printf '### 校验\n\n'
    printf '```bash\n'
    printf 'shasum -a 256 -c SHA256SUMS.txt\n'
    printf '```\n\n'
    printf '### 系统要求\n\n'
    printf 'macOS 13 Ventura 或更高，Apple Silicon（M1 及以上）。\n'
  } > "${OUTPUT:-/dev/stdout}"
}

emit
