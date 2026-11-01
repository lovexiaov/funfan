#!/bin/bash
# FunFan —— 把 SwiftPM 产物组装成可分发的 FunFan.app
#
# 用法：
#   bash scripts/build-app.sh                      # 默认：自动选签名身份（没有就用 adhoc），产出 dist/FunFan.app
#   bash scripts/build-app.sh --identity "Developer ID Application: Xxx (TEAMID)"
#   bash scripts/build-app.sh --no-sign            # 只看包结构，不签名
#   bash scripts/build-app.sh --skip-build         # 复用 .build/release 里已有的二进制
#   bash scripts/build-app.sh --output /tmp/out    # 换输出目录
#   bash scripts/build-app.sh --print-identity     # 只打印会自动选中的签名身份
#
# 为什么需要这个脚本：
#   SwiftPM 只会产出裸可执行文件。裸二进制没有 bundle 标识，于是
#   · SMAppService（登录项 / 特权 helper）一律注册失败；
#   · 系统「登录项与扩展」里显示成一串路径；
#   · 公证工具（notarytool）没有可提交的 .app。
#   所以分发形态必须先有 .app，再谈签名与公证。
#
# 签名策略：
#   1. --identity 指定 > 环境变量 FUNFAN_SIGN_IDENTITY > 自动找 Developer ID Application > adhoc；
#   2. 内到外签名（先 helper 后 App），不用 --deep（Apple 已明确不推荐）；
#   3. Developer ID 才加 --timestamp（adhoc 加会报错），两者都开 --options runtime（硬运行时），
#      因为公证要求硬运行时。

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

APP_NAME="FunFan"
BUNDLE_ID="cn.lovexiaov.fun.fan"
HELPER_ID="cn.lovexiaov.fun.fan.helper"
HELPER_BIN_NAME="FunFanHelper"
COPYRIGHT="Copyright © 2026 FunFan. 保留所有权利。"

OUTPUT_DIR="dist"
IDENTITY_ARG=""
DO_SIGN=1
SKIP_BUILD=0
HARDENED=1
PRINT_IDENTITY_ONLY=0

die() { echo "✗ $*" >&2; exit 1; }
step() { echo "→ $*"; }
ok() { echo "✓ $*"; }

# MARK: - 参数

while [ $# -gt 0 ]; do
  case "$1" in
    --identity) IDENTITY_ARG="${2:-}"; shift 2 ;;
    --identity=*) IDENTITY_ARG="${1#*=}"; shift ;;
    --output) OUTPUT_DIR="${2:-}"; shift 2 ;;
    --output=*) OUTPUT_DIR="${1#*=}"; shift ;;
    --no-sign) DO_SIGN=0; shift ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --no-hardened) HARDENED=0; shift ;;
    --print-identity) PRINT_IDENTITY_ONLY=1; shift ;;
    -h|--help)
      sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) die "未知参数：$1（用 --help 看用法）" ;;
  esac
done

# MARK: - 签名身份

# 只挑 Developer ID Application：Apple Development 签名过不了 Gatekeeper/公证，
# 选错了要到公证那一步才炸，不如这里就分清楚。
find_developer_id() {
  security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' \
    | head -1
}

resolve_identity() {
  if [ -n "$IDENTITY_ARG" ]; then
    case "$IDENTITY_ARG" in
      adhoc|-|none) echo "-" ;;
      *) echo "$IDENTITY_ARG" ;;
    esac
    return
  fi
  if [ -n "${FUNFAN_SIGN_IDENTITY:-}" ]; then
    echo "$FUNFAN_SIGN_IDENTITY"
    return
  fi
  local found
  found="$(find_developer_id)"
  if [ -n "$found" ]; then echo "$found"; else echo "-"; fi
}

IDENTITY="$(resolve_identity)"

if [ "$PRINT_IDENTITY_ONLY" -eq 1 ]; then
  if [ "$IDENTITY" = "-" ]; then
    echo "adhoc（本机没有 Developer ID Application 证书）"
  else
    echo "$IDENTITY"
  fi
  exit 0
fi

# MARK: - 版本

[ -f VERSION ] || die "缺少 VERSION 文件"
SHORT_VERSION="$(tr -d ' \n' < VERSION)"
[ -n "$SHORT_VERSION" ] || die "VERSION 为空"

# 用提交数当 build 号：单调递增、可复现，不需要额外维护一个数字。
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

# MARK: - 构建

if [ "$SKIP_BUILD" -eq 0 ]; then
  step "编译 release（arm64）…"
  # 本机 SPM 的 sandbox-exec 受限，必须 --disable-sandbox，否则连 Package.swift 都读不了。
  swift build -c release --disable-sandbox || die "编译失败"
else
  step "跳过编译，复用 .build/release"
fi

for bin in FunFan "$HELPER_BIN_NAME"; do
  [ -x ".build/release/$bin" ] || die "缺少 .build/release/${bin}，先跑一次不带 --skip-build 的构建"
done

# MARK: - 组装

APP="$OUTPUT_DIR/$APP_NAME.app"
step "组装 $APP …"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" \
         "$APP/Contents/Resources" \
         "$APP/Contents/Library/LaunchDaemons"

cp ".build/release/FunFan" "$APP/Contents/MacOS/FunFan"
cp ".build/release/$HELPER_BIN_NAME" "$APP/Contents/MacOS/$HELPER_BIN_NAME"
chmod 755 "$APP/Contents/MacOS/FunFan" "$APP/Contents/MacOS/$HELPER_BIN_NAME"

# Info.plist：从模板替换版本号/版权，再让 plutil 校验一遍语法。
sed -e "s/__VERSION__/$SHORT_VERSION/g" \
    -e "s/__BUILD__/$BUILD_NUMBER/g" \
    -e "s|__COPYRIGHT__|$COPYRIGHT|g" \
    packaging/Info.plist > "$APP/Contents/Info.plist" || die "生成 Info.plist 失败"
plutil -lint "$APP/Contents/Info.plist" >/dev/null || die "Info.plist 语法错误"

# 特权 helper 的 LaunchDaemon 描述：SMAppService.daemon 从这里读 BundleProgram。
cp packaging/cn.lovexiaov.fun.fan.helper.plist "$APP/Contents/Library/LaunchDaemons/$HELPER_ID.plist"
plutil -lint "$APP/Contents/Library/LaunchDaemons/$HELPER_ID.plist" >/dev/null \
  || die "LaunchDaemon plist 语法错误"

# 图标：有就带上，没有不报错（当前版本还没做图标）。
if [ -f "packaging/AppIcon.icns" ]; then
  cp "packaging/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" >/dev/null 2>&1 || true
fi

printf 'APPL????' > "$APP/Contents/PkgInfo"

ok "包结构已就绪：$(du -sh "$APP" | cut -f1)"

# MARK: - 签名

sign_target() {
  local path="$1" identifier="$2" entitlements="$3"
  local args=(--force --sign "$IDENTITY" --identifier "$identifier")
  [ "$HARDENED" -eq 1 ] && args+=(--options runtime)
  [ -f "$entitlements" ] && args+=(--entitlements "$entitlements")
  # adhoc 签名不能带 --timestamp（没有可信任的时间戳服务可签），带了直接报错。
  [ "$IDENTITY" != "-" ] && args+=(--timestamp)
  codesign "${args[@]}" "$path" 2>&1 | sed 's/^/    /'
  return ${PIPESTATUS[0]}
}

if [ "$DO_SIGN" -eq 1 ]; then
  if [ "$IDENTITY" = "-" ]; then
    step "签名：adhoc（仅本机调试；Gatekeeper 不认，无法公证）"
  else
    step "签名：$IDENTITY"
  fi

  # 顺手清掉构建产物可能带的扩展属性，避免签名后又被标记成「已隔离」。
  xattr -cr "$APP" 2>/dev/null

  # 内到外：helper 先签，否则 App 签完再改 helper 会把 App 的签名弄坏。
  sign_target "$APP/Contents/MacOS/$HELPER_BIN_NAME" "$HELPER_ID" "packaging/FunFanHelper.entitlements" \
    || die "helper 签名失败"
  sign_target "$APP" "$BUNDLE_ID" "packaging/FunFan.entitlements" \
    || die "App 签名失败"
  ok "签名完成"
else
  step "已跳过签名（--no-sign）"
fi

# MARK: - 校验

step "校验 …"

if [ "$DO_SIGN" -eq 1 ]; then
  codesign --verify --strict --verbose=2 "$APP" 2>&1 | sed 's/^/    /'
  verify_status=${PIPESTATUS[0]}
  [ "$verify_status" -eq 0 ] && ok "codesign --verify 通过" || echo "    （verify 未通过，见上）"

  echo "    签名详情："
  codesign -dv --verbose=4 "$APP" 2>&1 \
    | grep -E "Identifier|Format|CodeDirectory|Signature|TeamIdentifier|Runtime Version|flags" \
    | sed 's/^/      /'
fi

# 包内一致性：Info.plist 的可执行文件名必须真的存在，否则启动即崩。
PLIST_EXEC="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist" 2>/dev/null)"
[ -x "$APP/Contents/MacOS/$PLIST_EXEC" ] && ok "CFBundleExecutable=$PLIST_EXEC 存在" \
  || die "CFBundleExecutable=$PLIST_EXEC 在 Contents/MacOS 下找不到"

# Gatekeeper 评估：adhoc 必然被拒，这是预期，不是 bug。
echo "    Gatekeeper 评估："
spctl -a -vv -t exec "$APP" 2>&1 | sed 's/^/      /'
if [ "$IDENTITY" = "-" ]; then
  echo "      （adhoc 签名被拒属预期；Developer ID 签名 + 公证后应变为 accepted）"
fi

# MARK: - 汇总

echo
ok "产物：$APP"
echo "  版本：$SHORT_VERSION ($BUILD_NUMBER)"
echo "  签名：$IDENTITY"
echo "  硬运行时：$([ "$HARDENED" -eq 1 ] && echo 开 || echo 关)"
echo
echo "  试运行：open \"$APP\""
echo "  登录项/特权 helper 需要 App 有稳定标识，所以要从 .app 里跑，不要用裸二进制。"
if [ "$IDENTITY" = "-" ]; then
  echo
  echo "  提示：本机没有 Developer ID Application 证书，当前只能 adhoc。"
  echo "  要出可分发的包：装好证书后跑 bash scripts/notarize.sh（见 --help）。"
fi
