#!/bin/bash
# FunFan 特权 helper 安装/卸载脚本
#
# 用法：
#   sudo bash scripts/install-helper.sh           安装并加载
#   sudo bash scripts/install-helper.sh uninstall 卸载
#   sudo bash scripts/install-helper.sh status    查看运行状态
#
# 说明：这是 v0 的 launchd 直装方案（便于开发期验证）。
# 正式发布应改为 App 内 SMAppService.daemon 注册（需 Xcode 工程 + Developer ID 签名）。

set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

LABEL="com.funfan.helper"
BIN_SRC=".build/release/FunFanHelper"
BIN_DST="/Library/PrivilegedHelperTools/${LABEL}"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
LOG="/var/log/${LABEL}.log"

if [ "$(id -u)" -ne 0 ]; then
  echo "✗ 需要 root。请用 sudo 运行本脚本。"
  exit 1
fi

action="${1:-install}"

# 与「系统授权安装」（App 内 SMAppService）互斥：两者都注册同名 label
# com.funfan.helper，同时存在会互相抢 Mach service，表现为风扇忽然失控又忽然返还。
# 判据用运行中 daemon 的 program 路径：SMAppService 那份一定在 .app 包内。
if [ "$action" = "install" ] && launchctl print "system/${LABEL}" >/dev/null 2>&1; then
  current_program="$(launchctl print "system/${LABEL}" 2>/dev/null | awk -F'= ' '/program =/{print $2; exit}')"
  case "$current_program" in
    *.app/Contents/MacOS/*)
      echo "✗ 已经通过 App 内「安装特权组件」（SMAppService）注册过："
      echo "    ${current_program}"
      echo "  两条安装路径不能共存（同名 label 会互相抢服务）。"
      echo "  要改用脚本直装，请先在 App 设置里卸载后台组件，再跑本脚本。"
      exit 1
      ;;
  esac
fi

case "$action" in
  uninstall)
    echo "→ 停止并卸载 ${LABEL}…"
    launchctl bootout "system/${LABEL}" 2>/dev/null
    rm -f "$PLIST" "$BIN_DST"
    echo "✓ 已卸载"
    exit 0
    ;;

  status)
    if launchctl print "system/${LABEL}" >/dev/null 2>&1; then
      echo "✓ ${LABEL} 已加载"
      launchctl print "system/${LABEL}" | grep -E "state|pid|program|path" | head -10
    else
      echo "✗ ${LABEL} 未加载"
    fi
    [ -f "$LOG" ] && { echo; echo "--- 最近日志 ---"; tail -20 "$LOG"; }
    exit 0
    ;;

  run)
    # 开发期兜底：launchd 装不上时，用 root 前台跑一个 helper。
    # root 进程照样能在 system bootstrap 域注册 Mach service，GUI 连得上。
    if [ ! -x "$BIN_DST" ]; then
      echo "✗ ${BIN_DST} 不存在，先跑一次 install。"
      exit 1
    fi
    echo "→ 以 root 前台运行 helper（Ctrl-C 退出，退出前自动返还风扇）"
    exec "$BIN_DST"
    ;;
esac

if [ ! -x "$BIN_SRC" ]; then
  echo "→ 构建 release…"
  swift build -c release --disable-sandbox || exit 1
fi

echo "→ 安装 helper 到 ${BIN_DST}…"
mkdir -p /Library/PrivilegedHelperTools
cp "$BIN_SRC" "$BIN_DST"
chown root:wheel "$BIN_DST"
chmod 755 "$BIN_DST"

# SPM 产物只有 linker-signed（ld 顺手打的 adhoc），launchd 在 bootstrap 阶段
# 会用自己的校验器验签，这种签名容易直接吃 "Bootstrap failed: 5"。
# 这里用 codesign 重新生成一份标准 adhoc 签名（开发期足够，正式发布换 Developer ID）。
echo "→ 重新签名（adhoc）…"
codesign --force --sign - --identifier "$LABEL" "$BIN_DST" || {
  echo "✗ codesign 失败"; exit 1
}
codesign --verify --verbose=2 "$BIN_DST" 2>&1 | sed 's/^/    /'
chmod 544 "$BIN_DST"

echo "→ 写入 LaunchDaemon plist…"
cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${BIN_DST}</string>
    </array>
    <key>MachServices</key>
    <dict>
        <key>${LABEL}</key>
        <true/>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>EnvironmentVariables</key>
    <dict>
        <key>FUNFAN_REQUIRE_SIGNATURE</key>
        <string>0</string>
    </dict>
    <key>StandardErrorPath</key>
    <string>${LOG}</string>
</dict>
</plist>
PLIST_EOF
chown root:wheel "$PLIST"
chmod 644 "$PLIST"

echo "→ 加载服务…"
launchctl bootout "system/${LABEL}" 2>/dev/null
launchctl enable "system/${LABEL}" 2>/dev/null

if ! out=$(launchctl bootstrap system "$PLIST" 2>&1); then
  echo "✗ bootstrap 失败：${out}"

  echo
  echo "── 诊断 ──────────────────────────────"
  echo "系统：$(sw_vers -productName) $(sw_vers -productVersion) ($(uname -m))"
  echo "权限：$(ls -l "$BIN_DST")"
  codesign -dv --verbose=4 "$BIN_DST" 2>&1 | grep -E "Identifier|Signature|flags|CDHash" | sed 's/^/  /'
  xattr "$BIN_DST" | sed 's/^/  xattr: /'
  launchctl print-disabled system 2>/dev/null | grep -i "$LABEL" | sed 's/^/  disabled: /'
  echo "  ── launchd 日志（最近 3 分钟）──"
  /usr/bin/log show --last 3m --predicate "process == \"launchd\"" 2>/dev/null \
    | grep -i -E "$LABEL|funfan" | tail -12 | sed 's/^/  /'
  echo "──────────────────────────────────────"
  echo

  echo "→ 回退尝试：launchctl load -wF"
  if launchctl load -wF "$PLIST" 2>/dev/null; then
    echo "✓ 回退加载成功"
  else
    echo "✗ 回退也失败。请把上面「诊断」整段贴回来。"
    exit 1
  fi
fi

sleep 1
if launchctl print "system/${LABEL}" >/dev/null 2>&1; then
  echo "✓ ${LABEL} 已加载并监听 Mach service"
  launchctl print "system/${LABEL}" 2>/dev/null | grep -E "state =|pid =|program =" | sed 's/^/  /'
  [ -f "$LOG" ] || : > "$LOG" 2>/dev/null
  echo "  日志：${LOG}"
  echo "  卸载：sudo bash scripts/install-helper.sh uninstall"
else
  echo "✗ 服务已注册但没跑起来（多半是 helper 启动即退出）"
  echo "── 最近日志 ──"
  /usr/bin/log show --last 2m --predicate "process == \"${LABEL}\" OR eventMessage CONTAINS \"${LABEL}\"" 2>/dev/null | tail -20 | sed 's/^/  /'
  [ -f "$LOG" ] && { echo "── $LOG ──"; tail -20 "$LOG" | sed 's/^/  /'; }
  exit 1
fi
