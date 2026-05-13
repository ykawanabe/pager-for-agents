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
# Homebrew location. See cli/cta for the full explanation.
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
      local rotated
      rotated="$LOG_FILE.$(date +%Y%m%d-%H%M%S)"
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

# F1+F2 Phase 2 path — one poller + one tmux session per mount entry.
#
# Required .env: MAIN_CHAT_ID. Everything else (topics, project paths, tmux
# session names) is driven by ~/.claude-telegram-agent/mounts.json, which is
# owned by `cta mount/umount`. Mounts can be added at runtime — the poller
# hot-reloads on mounts.json mtime; this script spawns the per-topic tmux
# sessions on (re)start.
#
# Layout while running:
#   tmux poller            — bun .../agent/poller/poller.ts
#   tmux topic-<id>        — one per mounts.json entry (forum topic or "dm")
#   tmux watchdog          — v0 watchdog for now; Phase 3 swaps in the
#                            heartbeat-aware version.
main_multi_topic() {
  if [[ -z "${MAIN_CHAT_ID:-}" ]]; then
    echo "MULTI_TOPIC=1 requires MAIN_CHAT_ID in .env" >&2
    exit 1
  fi

  # CTA_AGENT_DIR overrides the install location (used by tests). The legacy
  # CTA_SERVICES_DIR env name is honored for back-compat with any operator
  # scripts that pinned it; new code should use CTA_AGENT_DIR.
  local agent_dir="${CTA_AGENT_DIR:-${CTA_SERVICES_DIR:-$HOME/.local/share/claude-telegram-agent/agent}}"
  local poller_path="$agent_dir/poller/poller.ts"
  local wrapper_path="$agent_dir/topic-wrapper.sh"
  local mount_store_path="$agent_dir/mount-store/mount-store.ts"
  for p in "$poller_path" "$wrapper_path" "$mount_store_path"; do
    if [[ ! -e "$p" ]]; then
      echo "MULTI_TOPIC: missing $p — rerun install.sh" >&2
      exit 1
    fi
  done

  # Tear down any prior poller / watchdog. Per-topic sessions are torn down
  # individually in the mounts loop below so we don't blow away ones that
  # don't appear in mounts.json yet (idempotent re-entry).
  tmux kill-session -t poller 2>/dev/null || true
  tmux kill-session -t "$TMUX_SESSION_WATCHDOG" 2>/dev/null || true
  # v0 leftover: if a `claude` session from main_single_topic is alive when
  # we switch to MULTI_TOPIC, two pollers race on getUpdates. Kill it.
  tmux kill-session -t "$TMUX_SESSION_CLAUDE" 2>/dev/null || true

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
    "bun $poller_path"
  # Brief settle before pipe-pane — the live install showed an intermittent
  # "can't find pane: poller" when pipe_to_log ran immediately after new-
  # session before the pane was fully attached.
  sleep 0.2
  pipe_to_log poller

  sleep 1

  # Walk mounts.json and spawn one tmux session per entry. `bun run … list`
  # prints the full file as JSON; jq pulls out the fields we need on
  # tab-separated lines for safe whitespace handling in paths.
  local n=0
  while IFS=$'\t' read -r thread_id project_path tmux_session; do
    [[ -z "$thread_id" ]] && continue
    if [[ ! -d "$project_path" ]]; then
      echo "MULTI_TOPIC: skipping thread $thread_id — project_path '$project_path' is not a directory" >&2
      continue
    fi
    tmux kill-session -t "$tmux_session" 2>/dev/null || true
    # tmux new-session's command arg goes through /bin/sh -c; printf %q
    # shell-escapes each arg so paths with spaces / metacharacters survive.
    local quoted_cmd
    quoted_cmd=$(printf '%q ' "$wrapper_path" "$thread_id" "$project_path" "$tmux_session")
    tmux new-session -d -s "$tmux_session" "$quoted_cmd"
    pipe_to_log "$tmux_session"
    n=$((n + 1))
  done < <(bun run "$mount_store_path" list \
            | jq -r '.mounts[] | select(.thread_id != "*") | [.thread_id, .path, .tmux_session] | @tsv')

  sleep 3

  tmux new-session -d -s "$TMUX_SESSION_WATCHDOG" "$BIN_DIR/watch_network.sh"
  pipe_to_log "$TMUX_SESSION_WATCHDOG"

  echo "Started tmux sessions (MULTI_TOPIC): poller, $n topic(s), $TMUX_SESSION_WATCHDOG"
  if [[ "$n" -eq 0 ]]; then
    echo "Note: mounts.json is empty. Use 'cta mount <thread_id> <path>' to mount a project."
  fi
  echo "Watch poller: tmux attach -t poller"
  echo "Recent activity: tail -f $LOG_FILE"
}

# Sourcing (tests/test_start_agents.sh) exposes the helpers without running
# the destructive tmux dance. Direct execution still behaves identically.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main
fi
