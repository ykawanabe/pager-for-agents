#!/bin/bash
# Watches network connectivity and kicks the claude tmux session when the
# connection returns after an outage. The loop itself never exits — failures
# inside the loop are caught with `|| true` so a single ping or tmux error
# can't take the watchdog down.
#
# NOTE: We intentionally do NOT enable `set -e` here because the main loop
# must survive transient errors.
set -uo pipefail

ENV_FILE="$HOME/.claude-telegram-agent/.env"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing $ENV_FILE — run install.sh first." >&2
  exit 1
fi

# shellcheck source=/dev/null
set -a
source "$ENV_FILE"
set +a

WAS_OFFLINE=0

while true; do
  if ping -c 1 -W 2 "$PING_TARGET" > /dev/null 2>&1; then
    if [[ "$WAS_OFFLINE" -eq 1 ]]; then
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] Network restored — restarting claude session"
      tmux kill-session -t "$TMUX_SESSION_CLAUDE" 2>/dev/null || true
      sleep 2
      tmux new-session -d -s "$TMUX_SESSION_CLAUDE" "$HOME/.local/bin/restart_claude.sh" || true
      WAS_OFFLINE=0
    else
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] Online"
    fi
  else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Offline"
    WAS_OFFLINE=1
  fi
  sleep "$PING_INTERVAL"
done
