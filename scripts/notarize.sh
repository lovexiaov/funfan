#!/bin/bash
# FunFan —— Developer ID 签名 + 公证（notarytool）+ 装订（stapler）
#
# 用法：
#   bash scripts/notarize.sh --check            # 只体检：证书、凭据、包状态，什么都不改
#   bash scripts/notarize.sh                    # 全流程：重建 .app → 打 DMG → 公证 → 装订 → 验收
#   bash scripts/notarize.sh --skip-build       # 复用 dist/FunFan.app
#   bash scripts/notarize.sh --artifact <path>  # 只公证已有的 .dmg/.zip
#   bash scripts/notarize.sh --zip              # 用 zip 而不是 dmg 提交
#   bash scripts/notarize.sh --staple-only <p>  # 只做装订（公证早就过了的情形）
#
# 前置条件（都得你手动准备一次，脚本只检查不代办）：
#   1. 钥匙串里有 "Developer ID Application: <名字> (TEAMID)" 证书
#      —— Xcode → Settings → Accounts → Manage Certificates → + Developer ID Application；
#   2. 公证凭据存进钥匙串（App 专用密码，不是 Apple ID 密码）：
#      xcrun notarytool store-credentials funfan-notary \
#        --apple-id "you@example.com" --team-id "TEAMID" --password "app-specific-password"
#      凭据名可用 FUNFAN_NOTARY_PROFILE 覆盖（默认 funfan-notary）。
#
# 退出码：0 成功 / 2 缺签名证书 / 3 缺公证凭据 / 4 签名预检失败 / 5 公证失败 / 6 验收失败

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

APP_NAME="FunFan"
APP_PATH="dist/FunFan.app"
IDENTITY_ARG=""
ARTIFACT=""
PROFILE="${FUNFAN_NOTARY_PROFILE:-funfan-notary}"
CHECK_ONLY=0
SKIP_BUILD=0
USE_ZIP=0
STAPLE_ONLY=""

die() { echo "✗ $1" >&2; exit "${2:-1}"; }
step() { echo "→ $*"; }
ok() { echo "✓ $*"; }
warn() { echo "! $*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK_ONLY=1; shift ;;
    --identity) IDENTITY_ARG="${2:-}"; shift 2 ;;
    --identity=*) IDENTITY_ARG="${1#*=}"; shift ;;
    --artifact) ARTIFACT="${2:-}"; shift 2 ;;
    --artifact=*) ARTIFACT="${1#*=}"; shift ;;
    --profile) PROFILE="${2:-}"; shift 2 ;;
    --profile=*) PROFILE="${1#*=}"; shift ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --zip) USE_ZIP=1; shift ;;
    --staple-only) STAPLE_ONLY="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "未知参数：$1（用 --help 看用法）" ;;
  esac
done

# MARK: - 环境探测

find_developer_id() {
  security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' \
    | head -1
}

IDENTITY="$IDENTITY_ARG"
[ -z "$IDENTITY" ] && IDENTITY="$(find_developer_id)"

check_profile() {
  # notarytool 在没有凭据时的报错文案不稳定，直接拿它的退出码做判断。
  xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1
}

check_identity() { [ -n "$IDENTITY" ] && [ "$IDENTITY" != "-" ]; }

# MARK: - 仅装订

if [ -n "$STAPLE_ONLY" ]; then
  [ -e "$STAPLE_ONLY" ] || die "找不到 $STAPLE_ONLY"
  step "装订 $STAPLE_ONLY …"
  xcrun stapler staple "$STAPLE_ONLY" || die "装订失败（公证没过或产物被改过）" 6
  xcrun stapler validate "$STAPLE_ONLY" || die "装订校验失败" 6
  ok "装订完成"
  exit 0
fi

# MARK: - 体检

if [ "$CHECK_ONLY" -eq 1 ]; then
  echo "=== FunFan 签名/公证体检 ==="
  echo
  failed=0

  if check_identity; then
    ok "签名证书：$IDENTITY"
  else
    echo "✗ 签名证书：没有 Developer ID Application"
    echo "    当前钥匙串里的身份："
    security find-identity -v -p codesigning 2>/dev/null | sed 's/^/      /' | head -10
    echo "    怎么办：Xcode → Settings → Accounts → Manage Certificates → + Developer ID Application"
    echo "    有证书但没装私钥？从原机器导出 .p12 再双击导入。"
    failed=$((failed + 1))
  fi

  if check_profile; then
    ok "公证凭据：$PROFILE"
  else
    echo "✗ 公证凭据：钥匙串里没有 $PROFILE"
    echo "    怎么办：xcrun notarytool store-credentials $PROFILE \\"
    echo "             --apple-id \"you@example.com\" --team-id \"TEAMID\" --password \"app-specific-password\""
    echo "    （password 是 appleid.apple.com 生成的 App 专用密码，不是账号密码）"
    failed=$((failed + 1))
  fi

  if [ -d "$APP_PATH" ]; then
    flags="$(codesign -dv --verbose=4 "$APP_PATH" 2>&1 | grep -o 'flags=[^ ]*' | head -1)"
    team="$(codesign -dv --verbose=4 "$APP_PATH" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
    echo "✓ $APP_PATH 存在（$flags，TeamIdentifier=${team:-未设置}）"
    case "$flags" in
      *runtime*) ok "硬运行时：已开启（公证要求）" ;;
      *) echo "✗ 硬运行时：未开启（公证要求 --options runtime）"; failed=$((failed + 1)) ;;
    esac
    if codesign -d --entitlements :- "$APP_PATH" 2>/dev/null | grep -q "get-task-allow"; then
      echo "✗ 带 get-task-allow 调试权限（公证会拒）"
      failed=$((failed + 1))
    else
      ok "无调试权限（get-task-allow 不存在）"
    fi
  else
    warn "$APP_PATH 不存在（还没打包，先 make app）"
  fi

  echo
  if [ "$failed" -eq 0 ]; then
    ok "体检通过，可以跑 bash scripts/notarize.sh 出包"
    exit 0
  else
    echo "✗ $failed 项不满足，补齐后重跑。"
    exit 2
  fi
fi

# MARK: - 正式流程

check_identity || die "没有 Developer ID Application 证书，无法公证。先跑 bash scripts/notarize.sh --check 看缺什么。" 2
check_profile || die "钥匙串里没有公证凭据 \"$PROFILE\"。先跑 bash scripts/notarize.sh --check 看怎么建。" 3

step "签名身份：$IDENTITY"

# 1) 构建 + 签名（build-app.sh 负责内到外签名与硬运行时）
if [ -z "$ARTIFACT" ]; then
  if [ "$SKIP_BUILD" -eq 0 ]; then
    ./scripts/build-app.sh --identity "$IDENTITY" || die "构建/签名失败" 4
  else
    [ -d "$APP_PATH" ] || die "$APP_PATH 不存在，去掉 --skip-build 重跑" 4
  fi

  # 2) 签名预检：公证被拒最常见的原因就是这里不满足，提前拦住省一次 10 分钟往返。
  step "签名预检 …"
  codesign --verify --strict --verbose=2 "$APP_PATH" 2>&1 | sed 's/^/    /' \
    || die "codesign --verify 不通过" 4

  flags="$(codesign -dv --verbose=4 "$APP_PATH" 2>&1 | grep -o 'flags=[^ ]*' | head -1)"
  case "$flags" in
    *runtime*) ok "硬运行时已开启" ;;
    *) die "缺少硬运行时（$flags），公证会拒" 4 ;;
  esac
  if codesign -d --entitlements :- "$APP_PATH" 2>/dev/null | grep -q "get-task-allow"; then
    die "产物带 get-task-allow 调试权限，公证会拒" 4
  fi

  # helper 单独验一遍：它在 Contents/MacOS 下，是 App 签名里最容易被漏掉的部分。
  codesign --verify --strict --verbose=2 "$APP_PATH/Contents/MacOS/FunFanHelper" 2>&1 | sed 's/^/    /' \
    || die "helper 签名不通过" 4

  # 3) 产物：默认 DMG（用户实际下载的那个文件），--zip 可切
  if [ "$USE_ZIP" -eq 1 ]; then
    VERSION="$(tr -d ' \n' < VERSION)"
    ARTIFACT="dist/FunFan-$VERSION.zip"
    step "打 zip：$ARTIFACT …"
    rm -f "$ARTIFACT"
    ditto -c -k --keepParent "$APP_PATH" "$ARTIFACT" || die "打 zip 失败" 4
  else
    ./scripts/make-dmg.sh --identity "$IDENTITY" || die "打 DMG 失败" 4
    VERSION="$(tr -d ' \n' < VERSION)"
    ARTIFACT="dist/FunFan-$VERSION.dmg"
  fi
fi

[ -e "$ARTIFACT" ] || die "找不到待公证产物：$ARTIFACT" 4
ok "待公证产物：$ARTIFACT（$(du -h "$ARTIFACT" | cut -f1)）"

# 4) 提交公证（--wait 会同步等到出结果，通常 1–5 分钟）
step "提交公证（凭据：$PROFILE）…"
SUBMIT_JSON="$(xcrun notarytool submit "$ARTIFACT" --keychain-profile "$PROFILE" --wait --output-format json 2>&1)"
SUBMIT_STATUS=$?
echo "$SUBMIT_JSON" | sed 's/^/    /'

[ "$SUBMIT_STATUS" -eq 0 ] || die "notarytool 提交失败（看上面输出）" 5

SUBMISSION_ID="$(echo "$SUBMIT_JSON" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)"
STATUS="$(echo "$SUBMIT_JSON" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)"

if [ "$STATUS" != "Accepted" ]; then
  echo
  echo "✗ 公证未通过：${STATUS:-未知}"
  if [ -n "$SUBMISSION_ID" ]; then
    step "拉取公证日志（$SUBMISSION_ID）…"
    xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$PROFILE" 2>&1 | sed 's/^/    /'
  fi
  die "按日志修掉问题（常见：嵌二进制未签名、用私有 API、硬运行时缺失）后重跑" 5
fi
ok "公证通过（submission $SUBMISSION_ID）"

# 5) 装订：把公证票据贴进产物，用户离线也能通过 Gatekeeper
step "装订 …"
xcrun stapler staple "$ARTIFACT" || die "装订失败" 6
# zip 里装订的是 App 本身，因为 zip 不是可装订容器
if [ "$USE_ZIP" -eq 1 ]; then
  xcrun stapler staple "$APP_PATH" || die "App 装订失败" 6
fi

# 6) 验收：Gatekeeper 实际放行才算过
step "Gatekeeper 验收 …"
if [ "$USE_ZIP" -eq 1 ]; then
  spctl -a -vv -t exec "$APP_PATH" 2>&1 | sed 's/^/    /' || die "Gatekeeper 仍拒绝 App" 6
  xcrun stapler validate "$APP_PATH" | sed 's/^/    /'
else
  spctl -a -t open --context context:primary-signature -vv "$ARTIFACT" 2>&1 | sed 's/^/    /' \
    || die "Gatekeeper 仍拒绝 DMG" 6
  xcrun stapler validate "$ARTIFACT" | sed 's/^/    /'
fi

echo
ok "可分发：$ARTIFACT"
echo "  版本：$(tr -d ' \n' < VERSION)"
echo "  校验：shasum -a 256 \"$ARTIFACT\""
