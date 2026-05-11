#!/bin/bash
# Entry point — starts both the claude restart loop and the network watchdog
# inside detached tmux sessions. Safe to call multiple times: existing
# sessions are killed first.
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

BIN_DIR="$HOME/.local/bin"
LOG_FILE="$HOME/.claude-telegram-agent/agent.log"

# `tmux pipe-pane` mirrors pane output to a file while still rendering it in
# the pane itself. We use it so `~/agent.log` actually contains live activity
# (claude tool calls, watchdog heartbeats, restart events) — not just the
# boot line from this script. The Pager's "Show recent activity" tails this.
pipe_to_log() {
  local session="$1"
  tmux pipe-pane -t "$session" -o "cat >> $LOG_FILE" || true
}

# Kill any existing sessions before relaunching.
tmux kill-session -t "$TMUX_SESSION_CLAUDE" 2>/dev/null || true
tmux kill-session -t "$TMUX_SESSION_WATCHDOG" 2>/dev/null || true

# Start the claude loop.
tmux new-session -d -s "$TMUX_SESSION_CLAUDE" "$BIN_DIR/restart_claude.sh"
pipe_to_log "$TMUX_SESSION_CLAUDE"

# Give claude a moment to bind to the Telegram plugin before the watchdog
# starts polling — avoids a benign "no session" race on first launch.
sleep 3

# Watchdog runs in its own session (not a window of $TMUX_SESSION_CLAUDE) so
# the watchdog survives when the claude session is killed and recreated.
tmux new-session -d -s "$TMUX_SESSION_WATCHDOG" "$BIN_DIR/watch_network.sh"
pipe_to_log "$TMUX_SESSION_WATCHDOG"

echo "Started tmux sessions: $TMUX_SESSION_CLAUDE, $TMUX_SESSION_WATCHDOG"
echo "Attach with: tmux attach -t $TMUX_SESSION_CLAUDE"
echo "Recent activity: tail -f $LOG_FILE"
