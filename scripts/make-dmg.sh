#!/bin/bash
# FunFan —— 打 DMG（拖进「应用程序」那种）
#
# 用法：
#   bash scripts/make-dmg.sh                 # 用 dist/FunFan.app 打 dist/FunFan-<版本>.dmg
#   bash scripts/make-dmg.sh --app <path>    # 指定别的 .app
#   bash scripts/make-dmg.sh --identity -    # 不签 DMG（默认有 Developer ID 就签）
#
# 为什么单独一个脚本：
#   公证（notarytool）吃 .zip 或 .dmg 都行，但 .dmg 能把「拖进 Applications」
#   的引导一起带上，而且公证 + 装订的对象就是用户实际下载到的那个文件。
#   zip 公证完还得再装订一次 .app 本身，两步容易漏。

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

APP_PATH="dist/FunFan.app"
IDENTITY_ARG=""
OUT_DIR="dist"

die() { echo "✗ $*" >&2; exit 1; }
step() { echo "→ $*"; }
ok() { echo "✓ $*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --app) APP_PATH="${2:-}"; shift 2 ;;
    --app=*) APP_PATH="${1#*=}"; shift ;;
    --identity) IDENTITY_ARG="${2:-}"; shift 2 ;;
    --identity=*) IDENTITY_ARG="${1#*=}"; shift ;;
    --output) OUT_DIR="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "未知参数：$1" ;;
  esac
done

[ -d "$APP_PATH" ] || die "找不到 ${APP_PATH}，先跑 bash scripts/build-app.sh"
mkdir -p "$OUT_DIR"

VERSION="$(tr -d ' \n' < VERSION 2>/dev/null || echo 0.0.0)"
DMG="$OUT_DIR/FunFan-$VERSION.dmg"

# 暂存目录：放 App + 一个指向 /Applications 的软链，用户打开 DMG 就能直接拖。
STAGE="$(mktemp -d)/FunFan"
mkdir -p "$STAGE"
step "暂存 $APP_PATH …"
ditto "$APP_PATH" "$STAGE/FunFan.app" || die "复制 App 失败"
ln -s /Applications "$STAGE/Applications"

step "生成 $DMG …"
rm -f "$DMG"
# macOS 26 起 hdiutil 打镜像会抛 deprecation 警告，官方替代是 diskutil image create。
# 但 macOS 13–15 上没有这个子命令，所以优先用新的、失败再回退旧的。
if ! diskutil image create from "$STAGE" "$DMG" --volumeName "FunFan" --format UDZO >/dev/null 2>&1; then
  rm -f "$DMG"
  hdiutil create \
    -volname "FunFan" \
    -srcfolder "$STAGE" \
    -ov -format UDZO \
    -fs HFS+ \
    "$DMG" >/dev/null 2>&1 || die "创建 DMG 失败"
fi
[ -f "$DMG" ] || die "创建 DMG 失败"
rm -rf "$(dirname "$STAGE")"

SIZE="$(du -h "$DMG" | cut -f1)"
ok "已生成 ${DMG}（${SIZE}）"

# DMG 本身也能签：让用户双击挂载时 Gatekeeper 的判定有签名依据。
IDENTITY="$IDENTITY_ARG"
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)"
fi

if [ -n "$IDENTITY" ] && [ "$IDENTITY" != "-" ]; then
  step "签名 DMG（${IDENTITY}）…"
  codesign --force --sign "$IDENTITY" --timestamp "$DMG" || die "DMG 签名失败"
  codesign --verify --verbose=2 "$DMG" 2>&1 | sed 's/^/    /'
  ok "DMG 已签名"
else
  echo "  （没有 Developer ID 证书，DMG 未签名；可以本机挂载试用，不能分发）"
fi

echo
echo "  下一步（有证书时）：bash scripts/notarize.sh --artifact \"$DMG\""
