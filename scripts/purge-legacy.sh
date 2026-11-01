#!/bin/bash
# FunFan 旧包数据清理
#
# 背景：标识从 com.funfan.* 迁到 cn.lovexiaov.fun.fan 之后，机器上的旧痕迹不会自己
# 消失。其中旧 daemon 最危险 —— 它还注册着 com.funfan.helper 这个 Mach service，
# 会和新 helper 同时写 SMC，表现为风扇忽快忽慢、App 退出后不返还。
#
# 用法：
#   bash scripts/purge-legacy.sh                    体检：只列出会清什么，不动任何东西
#   sudo bash scripts/purge-legacy.sh --apply       真清（系统侧 + 用户侧）
#   bash scripts/purge-legacy.sh --apply            不带 sudo 跑：只清用户侧，系统侧提示补 sudo
#
# 可选：
#   --incl-current      连新标识的 helper 一起卸（要从零重装验证时用）
#   --with-user-data    连 规则/曲线/诊断 一起清（默认保留；清了进废纸篓，可捞回）
#   --yes               不做交互确认（脚本化场景）
#
# 安全约定：
#   - 默认 dry-run，任何删除都必须显式 --apply。
#   - 只碰白名单内、名字里带 funfan / fun.fan 的精确路径；路径校验不过直接中止。
#   - 不动 /Applications/FunFan.app，也不动 ~/Library/Application Support/FunFan
#     以外的任何用户目录。
#   - 用户数据不删除，而是移进废纸篓（可恢复）。
#   - 删除前先把 plist / 偏好 / 日志备份到 .build/legacy-purge-backup/<时间戳>/。

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TS="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$REPO_ROOT/.build/legacy-purge-backup/$TS"

# ---- 旧标识（与 FunFanCore/XPC/HelperProtocol.swift 的 HelperConstants.Legacy 对齐）
LEGACY_LABEL="com.funfan.helper"
LEGACY_BIN="/Library/PrivilegedHelperTools/${LEGACY_LABEL}"
LEGACY_PLIST="/Library/LaunchDaemons/${LEGACY_LABEL}.plist"
LEGACY_LOG="/var/log/${LEGACY_LABEL}.log"
# 旧偏好域：一个是带 bundle id 的，一个是更早期按进程名落盘的，两代都要清
LEGACY_DOMAINS=("com.funfan.app" "FunFan")

# ---- 新标识（只在 --incl-current 时动）
CURRENT_LABEL="cn.lovexiaov.fun.fan.helper"
CURRENT_BIN="/Library/PrivilegedHelperTools/${CURRENT_LABEL}"
CURRENT_PLIST="/Library/LaunchDaemons/${CURRENT_LABEL}.plist"
CURRENT_LOG="/var/log/${CURRENT_LABEL}.log"

APPLY=false
WITH_USER_DATA=false
INCL_CURRENT=false
ASSUME_YES=false

for arg in "$@"; do
  case "$arg" in
    --apply)          APPLY=true ;;
    --with-user-data) WITH_USER_DATA=true ;;
    --incl-current)   INCL_CURRENT=true ;;
    --yes|-y)         ASSUME_YES=true ;;
    -h|--help)        sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "✗ 未知参数：$arg（--help 看用法）"; exit 2 ;;
  esac
done

# ---- 输出
if [ -t 1 ]; then
  B=$'\033[1m'; DIM=$'\033[2m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; N=$'\033[0m'
else
  B=""; DIM=""; G=""; Y=""; R=""; N=""
fi
step() { printf '\n%s▸ %s%s\n' "$B" "$*" "$N"; }
ok()   { printf '  %s✓%s %s\n' "$G" "$N" "$*"; }
skip() { printf '  %s·%s %s\n' "$DIM" "$N" "$*"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$*"; }
die()  { printf '\n%s✗ %s%s\n' "$R" "$*" "$N"; exit 1; }

# ---- 身份：sudo 下 $HOME 是 /var/root，用户侧必须切回真实账号
if [ "$(id -u)" -eq 0 ]; then
  TARGET_USER="${SUDO_USER:-}"
  if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = "root" ]; then
    die "检测不到发起 sudo 的账号。请以普通用户执行：sudo bash scripts/purge-legacy.sh --apply"
  fi
  TARGET_HOME="$(eval echo "~${TARGET_USER}")"
  IS_ROOT=true
else
  TARGET_USER="$(id -un)"
  TARGET_HOME="$HOME"
  IS_ROOT=false
fi
[ -d "$TARGET_HOME" ] || die "解析不到用户主目录：$TARGET_HOME"

# 以目标用户身份跑命令（偏好设置必须落在他的 cfprefsd 上，不能落 root 的）
as_user() {
  if $IS_ROOT; then sudo -u "$TARGET_USER" "$@"; else "$@"; fi
}

PREF_DIR="$TARGET_HOME/Library/Preferences"
APP_SUPPORT="$TARGET_HOME/Library/Application Support/FunFan"
CACHE_DIR="$TARGET_HOME/Library/Caches/com.funfan.app"
SAVED_STATE="$TARGET_HOME/Library/Saved Application State/com.funfan.app.savedState"

# ---- 路径白名单：宁可误报也不误删
assert_safe_path() {
  local p="$1"
  [ -n "$p" ] || die "内部错误：空路径"
  case "$p" in
    /|"$TARGET_HOME"|"$TARGET_HOME"/Library|"$TARGET_HOME"/Library/Preferences|/Library|/var|/var/log|/Library/LaunchDaemons)
      die "拒绝删除根级目录：$p" ;;
  esac
  case "$p" in
    /Library/PrivilegedHelperTools/*funfan*|/Library/PrivilegedHelperTools/*fun.fan*|\
    /Library/LaunchDaemons/*funfan*|/Library/LaunchDaemons/*fun.fan*|\
    /var/log/*funfan*|/var/log/*fun.fan*|\
    "$TARGET_HOME"/Library/Preferences/*funfan*|\
    "$TARGET_HOME"/Library/Preferences/*FunFan*|\
    "$TARGET_HOME"/Library/Preferences/*fun.fan*|\
    "$TARGET_HOME"/Library/Caches/*funfan*|"$TARGET_HOME"/Library/Caches/*fun.fan*|\
    "$TARGET_HOME"/Library/Saved\ Application\ State/*funfan*|\
    "$TARGET_HOME"/Library/Saved\ Application\ State/*fun.fan*|\
    "$TARGET_HOME"/Library/Application\ Support/FunFan)
      return 0 ;;
    *) die "拒绝删除白名单外的路径：$p" ;;
  esac
}

# 备份单个文件（失败只告警，不阻断清理）
backup_file() {
  local p="$1"
  [ -e "$p" ] || return 0
  mkdir -p "$BACKUP_DIR" 2>/dev/null || return 0
  cp -p "$p" "$BACKUP_DIR/$(basename "$p")" 2>/dev/null || warn "备份失败：$p"
}

# 删一个文件：先备份，再删。不存在就跳过。
purge_file() {
  local p="$1" note="${2:-}"
  if [ ! -e "$p" ] && [ ! -L "$p" ]; then
    skip "不存在：$p"
    return 0
  fi
  assert_safe_path "$p"
  local size
  size="$(du -h "$p" 2>/dev/null | awk '{print $1}')"
  if ! $APPLY; then
    printf '  %s将删除%s %s  (%s) %s\n' "$DIM" "$N" "$p" "${size:-?}" "$note"
    return 0
  fi
  # 备份（只备份可能有参考价值的小文件，二进制不备份）
  case "$p" in
    *.plist|*.log|*.json) backup_file "$p" ;;
  esac
  if rm -f "$p"; then ok "已删除：$p"; else warn "删除失败（可能需要 sudo）：$p"; return 1; fi
}

# 停一个 launchd daemon，并清掉可能存在的 disabled 覆盖
bootout_label() {
  local label="$1" plist="${2:-}"
  local loaded=false
  launchctl print "system/${label}" >/dev/null 2>&1 && loaded=true
  # 非 root 下 print 可能读不到 system 域，用 plist 存在性兜底，避免 dry-run 漏报
  if ! $loaded && [ -n "$plist" ] && [ -e "$plist" ]; then loaded=true; fi

  if $loaded; then
    if ! $APPLY; then
      printf '  %s将停止%s system/%s\n' "$DIM" "$N" "$label"
    else
      # helper 的 SIGTERM 处理会返还所有动过的风扇；另有 10s TTL 租约兜底，
      # 所以这里 bootout 不会把风扇锁在某个转速上。
      launchctl bootout "system/${label}" 2>/dev/null
      if launchctl print "system/${label}" >/dev/null 2>&1; then
        warn "bootout 未生效：system/${label}"
      else
        ok "已停止：system/${label}"
      fi
    fi
  else
    skip "未加载：system/${label}"
  fi
  # disabled 表里的显式覆盖（默认是 enabled，不必处理）
  if launchctl print-disabled system 2>/dev/null | grep -q "\"${label}\" => disabled"; then
    if ! $APPLY; then
      printf '  %s将解除禁用覆盖%s %s\n' "$DIM" "$N" "$label"
    else
      launchctl enable "system/${label}" 2>/dev/null && ok "已解除禁用覆盖：$label"
    fi
  fi
}

echo "${B}FunFan 旧包数据清理${N}  ${DIM}$( $APPLY && echo '模式=apply（真的会删）' || echo '模式=dry-run（只体检，不动手）')${N}"
echo "${DIM}账号=$TARGET_USER  主目录=$TARGET_HOME  root=$IS_ROOT${N}"

if ! $APPLY; then
  echo "${DIM}下面列出「如果加 --apply 会做什么」。确认无误后再执行：sudo bash scripts/purge-legacy.sh --apply${N}"
fi

# ---- 0. 前置检查
step "前置检查"
if pgrep -x FunFan >/dev/null 2>&1; then
  warn "FunFan App 正在运行（pid $(pgrep -x FunFan | paste -sd, -)）。"
  warn "  它每 2s 续租一次；旧 helper 被停掉后 GUI 只会报连接失败，不会崩，但建议先退出："
  warn "  osascript -e 'quit app \"FunFan\"'   # 或菜单栏图标右键 → 退出"
fi
if $IS_ROOT; then ok "以 root 运行，系统侧与用户侧都能清"; else warn "非 root：系统侧（daemon/二进制/日志）清不掉，会提示补跑"; fi

# ---- 1. 备份目录
step "备份"
if $APPLY; then
  mkdir -p "$BACKUP_DIR" && ok "备份目录：$BACKUP_DIR"
  $IS_ROOT && chown -R "$TARGET_USER":staff "$REPO_ROOT/.build/legacy-purge-backup" 2>/dev/null
else
  skip "dry-run 不创建（apply 时会建在 $BACKUP_DIR）"
fi

# ---- 2. 旧 daemon
step "旧 daemon（${LEGACY_LABEL}）"
if $APPLY && ! $IS_ROOT; then
  if launchctl print "system/${LEGACY_LABEL}" >/dev/null 2>&1 || [ -e "$LEGACY_PLIST" ]; then
    warn "需要 root：sudo launchctl bootout system/${LEGACY_LABEL}"
  else
    skip "未加载：system/${LEGACY_LABEL}"
  fi
else
  bootout_label "$LEGACY_LABEL" "$LEGACY_PLIST"
fi

# ---- 3. 旧系统文件
step "旧系统文件"
for f in "$LEGACY_PLIST" "$LEGACY_BIN" "$LEGACY_LOG"; do
  if $APPLY && ! $IS_ROOT && [ -e "$f" ]; then
    warn "需要 root：sudo rm -f $f"
    continue
  fi
  purge_file "$f"
done

# ---- 4. 旧偏好域
step "旧偏好域"
for domain in "${LEGACY_DOMAINS[@]}"; do
  if as_user defaults read "$domain" >/dev/null 2>&1; then
    if ! $APPLY; then
      printf '  %s将删除域%s %s  (内容：%s)\n' "$DIM" "$N" "$domain" "$(as_user defaults read "$domain" 2>/dev/null | tr -d '\n' | tr -s ' ' | cut -c1-80)"
    else
      # 先备份：defaults delete 会连 plist 一起清掉，之后再想备份就没源了
      backup_file "$PREF_DIR/${domain}.plist"
      as_user defaults delete "$domain" 2>/dev/null && ok "已删除域：$domain" || warn "删除域失败：$domain"
      # 兜底：cfprefsd 偶尔会留下空壳文件
      [ -e "$PREF_DIR/${domain}.plist" ] && purge_file "$PREF_DIR/${domain}.plist" "（残留文件）"
    fi
  else
    skip "域不存在：$domain"
  fi
done
# 新域不动，只报告状态
if as_user defaults read "cn.lovexiaov.fun.fan" >/dev/null 2>&1; then
  skip "新域 cn.lovexiaov.fun.fan 已存在（不碰）"
else
  skip "新域 cn.lovexiaov.fun.fan 尚未建立（首次启动 App 会生成）"
fi

# ---- 5. 缓存与窗口状态
step "缓存 / 窗口状态"
purge_file "$CACHE_DIR" "缓存目录"
purge_file "$SAVED_STATE" "窗口恢复状态"

# ---- 6. 用户数据（默认保留）
step "用户数据（规则 / 曲线 / 诊断）"
if [ -d "$APP_SUPPORT" ]; then
  detail="$(ls -1 "$APP_SUPPORT" 2>/dev/null | paste -sd' ' -)"
  if ! $WITH_USER_DATA; then
    skip "保留：$APP_SUPPORT"
    skip "内含：${detail:-空}（要一并清掉加 --with-user-data）"
  else
    if ! $APPLY; then
      printf '  %s将移入废纸篓%s %s  (内含：%s)\n' "$DIM" "$N" "$APP_SUPPORT" "$detail"
    else
      if ! $ASSUME_YES; then
        printf '  %s即将把 %s 移入废纸篓（含规则/曲线，清后需重建）。继续？[y/N] %s' "$Y" "$APP_SUPPORT" "$N"
        read -r ans </dev/tty || ans=""
        case "$ans" in y|Y|yes|YES) ;; *) skip "已跳过用户数据"; WITH_USER_DATA=false ;; esac
      fi
      if $WITH_USER_DATA; then
        # 不 rm -rf：移进废纸篓，用户随时能捞回来
        TRASH_DIR="$TARGET_HOME/.Trash"
        dest="$TRASH_DIR/FunFan-legacy-$TS"
        if mkdir -p "$TRASH_DIR" && mv "$APP_SUPPORT" "$dest"; then
          ok "已移入废纸篓：$dest"
        else
          warn "移入废纸篓失败：$APP_SUPPORT"
        fi
      fi
    fi
  fi
else
  skip "不存在：$APP_SUPPORT"
fi

# ---- 7. 新 helper（仅在 --incl-current 时）
if $INCL_CURRENT; then
  step "新 helper（${CURRENT_LABEL}，--incl-current）"
  if $APPLY && ! $IS_ROOT; then
    warn "需要 root：sudo launchctl bootout system/${CURRENT_LABEL}"
  else
    bootout_label "$CURRENT_LABEL" "$CURRENT_PLIST"
  fi
  for f in "$CURRENT_PLIST" "$CURRENT_BIN" "$CURRENT_LOG"; do
    if [ -e "$f" ] && ! $IS_ROOT && $APPLY; then warn "需要 root：sudo rm -f $f"; continue; fi
    purge_file "$f"
  done
else
  step "新 helper（${CURRENT_LABEL}）"
  if launchctl print "system/${CURRENT_LABEL}" >/dev/null 2>&1; then
    skip "在跑，保持不动（要从零重装加 --incl-current）"
  else
    skip "未安装"
  fi
fi

# ---- 8. App 本体
step "App 本体"
if [ -d /Applications/FunFan.app ]; then
  skip "保留 /Applications/FunFan.app（要卸载请自己拖进废纸篓）"
else
  skip "/Applications 下没有 FunFan.app"
fi

# ---- 9. 自检
step "自检"
if $APPLY; then
  left=0
  for p in "$LEGACY_BIN" "$LEGACY_PLIST" "$LEGACY_LOG"; do
    if [ -e "$p" ]; then
      warn "残留：$p"
      left=$((left + 1))
    fi
  done
  if launchctl print "system/${LEGACY_LABEL}" >/dev/null 2>&1; then
    warn "残留：system/${LEGACY_LABEL} 仍在加载"
    left=$((left + 1))
  fi
  for domain in "${LEGACY_DOMAINS[@]}"; do
    if as_user defaults read "$domain" >/dev/null 2>&1; then
      warn "残留：偏好域 $domain"
      left=$((left + 1))
    fi
  done
  if [ "$left" -eq 0 ]; then
    ok "旧标识已清空（二进制 / plist / 日志 / 偏好域 / daemon）"
  else
    warn "还有 $left 项没清掉，通常是缺 root —— 用 sudo 重跑本脚本"
  fi
else
  skip "dry-run 不自检"
fi

# ---- 收尾
step "下一步"
if ! $APPLY; then
  echo "  确认无误后执行："
  echo "    ${B}sudo bash scripts/purge-legacy.sh --apply${N}"
  echo "  ${DIM}（不带 sudo 也可以，但系统侧会跳过并提示）${N}"
else
  if $INCL_CURRENT || ! launchctl print "system/${CURRENT_LABEL}" >/dev/null 2>&1; then
    echo "  重新安装 helper："
    echo "    ${B}sudo bash scripts/install-helper.sh${N}"
    echo "  ${DIM}装完用 App 设置里的「后台组件状态」确认：Mach service 应为 ${CURRENT_LABEL}${N}"
  else
    echo "  新 helper 还在跑，无需重装。"
  fi
  [ -d "$BACKUP_DIR" ] && echo "  备份留在：$BACKUP_DIR  ${DIM}（确认无碍后可删）${N}"
  echo "  ${DIM}提示：偏好域换了，菜单栏那几项设置会回到默认值。${N}"
fi
echo
