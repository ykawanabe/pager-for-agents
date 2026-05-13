#!/bin/bash
# Entry point — starts both the claude restart loop and the network watchdog
# inside detached tmux sessions. Safe to call multiple times: existing
# sessions are killed first.
set -euo pipefail

# Tighten umask so every file created downstream (agent.log via pipe-pane,
# anything the plugin's bun subprocess writes under ~/.claude/channels/, log
# rotation archives, etc.) lands at 0600/0700 instead of the system default
# 0644/0755. agent.log mirrors the full Telegram conversation through
# tmux pipe-pane — world-readable mode would expose chat history to any
# other user on the Mac and to cloud-backup tooling that walks $HOME.
umask 077

# Defensive PATH augmentation: launchd-spawned callers (Pager via `cta start`,
# the LaunchAgent itself) inherit a stripped PATH that doesn't include tmux's
# Homebrew location. See scripts/cta for the full explanation.
export PATH="$HOME/.bun/bin:/opt/homebrew/bin:/usr/local/bin:${PATH:-/usr/bin:/bin}:$HOME/.local/bin"

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
LOG_DIR="$(dirname "$LOG_FILE")"
LOG_ROTATE_MAX_BYTES=$((10 * 1024 * 1024))  # 10 MB
LOG_ARCHIVE_RETAIN_DAYS=30

# `tmux pipe-pane` mirrors pane output to a file while still rendering it in
# the pane itself. We use it so `~/agent.log` actually contains live activity
# (claude tool calls, watchdog heartbeats, restart events) — not just the
# boot line from this script. The Pager's "Show recent activity" tails this.
#
# Pre-create the log at 0600 so the file mode is locked in regardless of
# whatever umask the redirect inside `cat >>` actually honors. tmux's
# pipe-pane runs the shell command via /bin/sh -c with no guaranteed umask
# inheritance, so belt-and-suspenders here. The log contains the full
# Telegram conversation mirrored from claude's TUI — it is sensitive.
pipe_to_log() {
  local session="$1"
  touch "$LOG_FILE"
  chmod 600 "$LOG_FILE" 2>/dev/null || true
  tmux pipe-pane -t "$session" -o "cat >> $LOG_FILE" || true
}

# Archive the active log if it has grown past the size threshold, then prune
# archives older than $LOG_ARCHIVE_RETAIN_DAYS. Runs every time the agents
# (re)start — combined with the watchdog kicks during the day, this keeps
# disk usage bounded without needing a separate cron job. In-place rotation
# during a tmux pipe-pane run isn't safe (the writer's fd holds the old
# inode), so we only rotate at startup.
rotate_logs() {
  if [[ -f "$LOG_FILE" ]]; then
    local size
    size=$(stat -f %z "$LOG_FILE" 2>/dev/null || echo 0)
    if [[ "$size" -gt "$LOG_ROTATE_MAX_BYTES" ]]; then
      local rotated="$LOG_FILE.$(date +%Y%m%d-%H%M%S)"
      /bin/mv -f "$LOG_FILE" "$rotated"
      chmod 600 "$rotated" 2>/dev/null || true
    fi
  fi
  find "$LOG_DIR" -maxdepth 1 -name 'agent.log.*' -type f \
    -mtime +"$LOG_ARCHIVE_RETAIN_DAYS" -delete 2>/dev/null || true
}

main() {
  rotate_logs

  if [[ "${MULTI_TOPIC:-0}" == "1" ]]; then
    main_multi_topic
  else
    main_single_topic
  fi
}

# v0 single-topic path — one claude bound to the official plugin via
# restart_claude.sh, plus the v0 network watchdog. Unchanged from before
# F1+F2. Stays the default until MULTI_TOPIC=1 has soaked (see roadmap).
main_single_topic() {
  tmux kill-session -t "$TMUX_SESSION_CLAUDE" 2>/dev/null || true
  tmux kill-session -t "$TMUX_SESSION_WATCHDOG" 2>/dev/null || true

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
}

# F1+F2 Phase 1 (MVP) path — one poller + one hardcoded topic wrapper.
# Phase 2 replaces the hardcoded topic with a mounts.json walk.
#
# Required .env vars (in addition to the v0 ones):
#   MAIN_CHAT_ID                 — the one chat we listen to
#   MULTI_TOPIC_THREAD_ID        — Telegram forum topic id (Phase 1 hardcoded)
#   MULTI_TOPIC_PROJECT_PATH     — project dir for that topic
#   MULTI_TOPIC_TMUX_SESSION     — optional, defaults to topic-<thread_id>
#
# Layout while running:
#   tmux poller            — bun .../services/poller/poller.ts
#   tmux topic-<id>        — services/topic-wrapper.sh (per-topic claude)
#   tmux watchdog          — v0 watchdog for now; Phase 3 swaps in the
#                            heartbeat-aware version.
main_multi_topic() {
  if [[ -z "${MAIN_CHAT_ID:-}" || -z "${MULTI_TOPIC_THREAD_ID:-}" || -z "${MULTI_TOPIC_PROJECT_PATH:-}" ]]; then
    echo "MULTI_TOPIC=1 requires MAIN_CHAT_ID, MULTI_TOPIC_THREAD_ID, and MULTI_TOPIC_PROJECT_PATH in .env" >&2
    exit 1
  fi
  local topic_session="${MULTI_TOPIC_TMUX_SESSION:-topic-${MULTI_TOPIC_THREAD_ID}}"

  local poller_path="${MULTI_TOPIC_POLLER_PATH:-$HOME/.local/share/claude-telegram-agent/services/poller/poller.ts}"
  local wrapper_path="${MULTI_TOPIC_WRAPPER_PATH:-$HOME/.local/share/claude-telegram-agent/services/topic-wrapper.sh}"
  if [[ ! -f "$poller_path" ]]; then
    echo "MULTI_TOPIC: poller not installed at $poller_path — rerun install.sh" >&2
    exit 1
  fi
  if [[ ! -x "$wrapper_path" ]]; then
    echo "MULTI_TOPIC: topic-wrapper not installed at $wrapper_path — rerun install.sh" >&2
    exit 1
  fi

  tmux kill-session -t poller 2>/dev/null || true
  tmux kill-session -t "$topic_session" 2>/dev/null || true
  tmux kill-session -t "$TMUX_SESSION_WATCHDOG" 2>/dev/null || true

  # Pull token out of plugin .env so it lands in the poller's env.
  local plugin_env="$HOME/.claude/channels/telegram/.env"
  local token=""
  if [[ -f "$plugin_env" ]]; then
    token=$(grep '^TELEGRAM_BOT_TOKEN=' "$plugin_env" | head -1 | cut -d= -f2- | sed 's/^"//; s/"$//')
  fi
  if [[ -z "$token" ]]; then
    echo "MULTI_TOPIC: TELEGRAM_BOT_TOKEN missing in $plugin_env" >&2
    exit 1
  fi

  tmux new-session -d -s poller \
    -e "TELEGRAM_BOT_TOKEN=$token" \
    -e "MAIN_CHAT_ID=$MAIN_CHAT_ID" \
    -e "HARDCODED_THREAD_ID=$MULTI_TOPIC_THREAD_ID" \
    -e "HARDCODED_TMUX=$topic_session" \
    "bun $poller_path"
  pipe_to_log poller

  sleep 1

  tmux new-session -d -s "$topic_session" \
    "$wrapper_path $MULTI_TOPIC_THREAD_ID $MULTI_TOPIC_PROJECT_PATH $topic_session"
  pipe_to_log "$topic_session"

  sleep 3

  tmux new-session -d -s "$TMUX_SESSION_WATCHDOG" "$BIN_DIR/watch_network.sh"
  pipe_to_log "$TMUX_SESSION_WATCHDOG"

  echo "Started tmux sessions (MULTI_TOPIC): poller, $topic_session, $TMUX_SESSION_WATCHDOG"
  echo "Attach with: tmux attach -t $topic_session"
  echo "Watch poller: tmux attach -t poller"
  echo "Recent activity: tail -f $LOG_FILE"
}

# Sourcing (tests/test_start_agents.sh) exposes the helpers without running
# the destructive tmux dance. Direct execution still behaves identically.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main
fi
