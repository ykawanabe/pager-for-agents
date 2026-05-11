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

# Build the claude argv. BOT_SESSION_ID is a stable UUID generated at install
# time so the bot resumes the same conversation across restarts (Mac sleep,
# network drops, MCP kicks). Without it, every restart wipes context.
#
# When MULTI_TOPIC ships, each topic owns its own session via a per-topic
# .tg-session-id file and this global flag goes away. See roadmap.md.
args=(--channels "plugin:${TELEGRAM_PLUGIN}" --dangerously-skip-permissions)
if [[ -n "${BOT_SESSION_ID:-}" ]]; then
  args+=(--session-id "$BOT_SESSION_ID")
fi

while true; do
  claude "${args[@]}" || true
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] claude exited — restarting in 3s..."
  sleep 3
done
