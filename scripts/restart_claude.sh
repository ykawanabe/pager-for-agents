#!/bin/bash
# Restart loop for the Claude Code Telegram agent.
# Runs claude with the Telegram channel plugin. If claude exits for any reason
# (crash, network drop, OOM, etc.) it sleeps briefly and starts again.
set -euo pipefail

ENV_FILE="$HOME/.claude-telegram-agent/.env"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing $ENV_FILE — run install.sh first." >&2
  exit 1
fi

set -a
# shellcheck source=/dev/null
source "$ENV_FILE"
set +a

cd "$CLAUDE_CWD"

while true; do
  claude \
    --channels "plugin:${TELEGRAM_PLUGIN}" \
    --dangerously-skip-permissions || true
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] claude exited — restarting in 3s..."
  sleep 3
done
