#!/bin/bash
# FunFan 真机写入验证（需要 root）
#
# 用法：
#   sudo bash scripts/spin-test.sh [目标RPM] [持续秒数]
#
# 它会做三件事：
#   1. doctor  —— 打印权限/风扇/键类型
#   2. spin    —— 设目标转速，观测实际转速(F0Ac)，结束后自动返还
#   3. restore —— 保险式再返还一次（幂等）
#
# 安全：只写目标转速与模式键；绝不碰 F0Mn/F0Mx；不设 0 RPM；任何路径都会返还。

set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
BIN=".build/release/funfanctl"

if [ "$(id -u)" -ne 0 ]; then
  echo "✗ 需要 root。请运行： sudo bash scripts/spin-test.sh"
  exit 1
fi

if [ ! -x "$BIN" ]; then
  echo "→ 未找到 $BIN，先构建 release…"
  swift build -c release --disable-sandbox || exit 1
fi

TARGET_RPM="${1:-}"
SECONDS_TO_RUN="${2:-6}"

echo "════════ 1/3 doctor ════════"
"$BIN" doctor
echo
echo "════════ 2/3 spin（写入验证）════════"

# 中断时也要返还：把 Ctrl-C 交给子进程处理（它自己会 defer 返还），这里只兜底
trap 'echo; echo "→ 中断，执行兜底返还…"; "$BIN" restore; exit 130' INT TERM

if [ -n "$TARGET_RPM" ]; then
  "$BIN" spin --rpm "$TARGET_RPM" --seconds "$SECONDS_TO_RUN"
else
  "$BIN" spin --seconds "$SECONDS_TO_RUN"
fi

echo
echo "════════ 3/3 restore（保险）════════"
"$BIN" restore
echo
echo "完成。若第 2 步显示「写入链路验证通过」，说明 M4 硬件写入已打通。"
