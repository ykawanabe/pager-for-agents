#!/bin/bash
# Entry point — starts the poller (which owns per-topic claude daemons)
# and the network watchdog inside detached tmux sessions. Safe to call
# multiple times: existing sessions are killed first.
#
# Phase 4 (2026-05-19) rewrite: regular per-topic claude TUI sessions are
# gone — poller.ts owns one long-lived `claude -p --input-format stream-json`
# subprocess per active topic via ClaudeDaemonRegistry. The only tmux
# sessions we spawn are infrastructure:
#   tmux poller     — bun .../agent/poller/poller.ts (process supervision)
#   tmux watchdog   — agent/watch_network.sh (network + heartbeat)
# Mount-helper sessions (helper-<id>, briefly during project picking) are
# spawned on-demand by the poller, not here.
set -euo pipefail

# Tighten umask so every file created downstream (agent.log via pipe-pane,
# log rotation archives, etc.) lands at 0600/0700 instead of the system
# default 0644/0755. agent.log mirrors poller stdout — world-readable mode
# would expose chat metadata to other users on the Mac and cloud-backup
# tooling that walks $HOME.
umask 077

# Defensive PATH augmentation: launchd-spawned callers (Pager via `cta start`,
# the LaunchAgent itself) inherit a stripped PATH that doesn't include tmux's
# Homebrew location. See cli/cta for the full explanation.
export PATH="$HOME/.bun/bin:/opt/homebrew/bin:/usr/local/bin:${PATH:-/usr/bin:/bin}:$HOME/.local/bin"

STATE_DIR="${CTA_STATE_DIR:-$HOME/.pager}"
INSTALL_DIR="${CTA_INSTALL_DIR:-$HOME/.local/share/pager}"
ENV_FILE="$STATE_DIR/.env"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing $ENV_FILE — run install.sh first." >&2
  exit 1
fi

set -a
# shellcheck source=/dev/null
source "$ENV_FILE"
set +a

BIN_DIR="$HOME/.local/bin"
LOG_FILE="$STATE_DIR/agent.log"
LOG_DIR="$(dirname "$LOG_FILE")"
LOG_ROTATE_MAX_BYTES=$((10 * 1024 * 1024))  # 10 MB
LOG_ARCHIVE_RETAIN_DAYS=30

# `tmux pipe-pane` mirrors pane output to a file while still rendering it in
# the pane itself. agent.log is the Pager's "Show recent activity" tail.
#
# Pre-create the log at 0600 so the file mode is locked in regardless of
# whatever umask the redirect inside `cat >>` actually honors.
pipe_to_log() {
  local session="$1"
  touch "$LOG_FILE"
  chmod 600 "$LOG_FILE" 2>/dev/null || true
  tmux pipe-pane -t "$session" -o "cat >> $LOG_FILE" || true
}

# Archive the active log if it has grown past the size threshold, then prune
# archives older than $LOG_ARCHIVE_RETAIN_DAYS. In-place rotation during a
# tmux pipe-pane run isn't safe (the writer's fd holds the old inode), so
# we only rotate at startup.
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

  # CTA_AGENT_DIR overrides the install location (used by tests). Legacy
  # CTA_SERVICES_DIR honored for back-compat with operator scripts that
  # pinned it; new code should use CTA_AGENT_DIR.
  local agent_dir="${CTA_AGENT_DIR:-${CTA_SERVICES_DIR:-$INSTALL_DIR/agent}}"
  local poller_path="$agent_dir/poller/poller.ts"
  local mount_store_path="$agent_dir/mount-store/mount-store.ts"
  for p in "$poller_path" "$mount_store_path"; do
    if [[ ! -e "$p" ]]; then
      echo "start_agents: missing $p — rerun install.sh" >&2
      exit 1
    fi
  done

  # Tear down prior poller / watchdog so re-runs are idempotent.
  tmux kill-session -t poller 2>/dev/null || true
  tmux kill-session -t "${TMUX_SESSION_WATCHDOG:-watchdog}" 2>/dev/null || true
  # v0 leftover: a `claude` session from the long-dead main_single_topic
  # path would race our poller (409 Conflict on getUpdates → silent drops).
  # ONLY kill it if it's actually running the v0 restart_claude.sh — never
  # kill an unrelated session a user named "claude" themselves. We test
  # the pane command for the v0 signature; if it doesn't match, leave alone.
  local v0_session="${TMUX_SESSION_CLAUDE:-}"
  if [[ -n "$v0_session" ]] && tmux has-session -t "$v0_session" 2>/dev/null; then
    local pane_cmd
    pane_cmd=$(tmux list-panes -t "$v0_session" -F '#{pane_current_command} #{pane_start_command}' 2>/dev/null | head -1)
    if [[ "$pane_cmd" == *"restart_claude.sh"* ]]; then
      tmux kill-session -t "$v0_session" 2>/dev/null || true
    fi
  fi

  # Sanity: bot token must be reachable for the poller.
  local plugin_env="$HOME/.claude/channels/telegram/.env"
  local token=""
  if [[ -f "$plugin_env" ]]; then
    token=$(grep '^TELEGRAM_BOT_TOKEN=' "$plugin_env" | head -1 | cut -d= -f2- | sed 's/^"//; s/"$//')
  fi
  if [[ -z "$token" ]]; then
    echo "TELEGRAM_BOT_TOKEN missing in $plugin_env" >&2
    exit 1
  fi

  # Source project + plugin .env at spawn time. tmux's `-e` flag forwards
  # only explicitly-listed vars, dropping operator settings; sourcing here
  # keeps the poller's env in sync with kick_poller_session (watch_network.sh)
  # so the two spawn paths stay environmentally consistent.
  local env_file="$STATE_DIR/.env"
  local poller_wrapper_cmd
  poller_wrapper_cmd="set -a; [ -f '$env_file' ] && . '$env_file'; [ -f '$plugin_env' ] && . '$plugin_env'; set +a; exec bun '$poller_path'"
  tmux new-session -d -s poller "$poller_wrapper_cmd"
  # Brief settle before pipe-pane — the live install showed an intermittent
  # "can't find pane: poller" when pipe_to_log ran immediately after new-
  # session before the pane was fully attached.
  sleep 0.2
  pipe_to_log poller

  sleep 1

  tmux new-session -d -s "${TMUX_SESSION_WATCHDOG:-watchdog}" "$BIN_DIR/watch_network.sh"
  pipe_to_log "${TMUX_SESSION_WATCHDOG:-watchdog}"

  echo "Started tmux sessions: poller, ${TMUX_SESSION_WATCHDOG:-watchdog}"
  echo "Watch poller: tmux attach -t poller"
  echo "Recent activity: tail -f $LOG_FILE"
}

# Sourcing (tests/test_start_agents.sh) exposes the helpers without running
# the destructive tmux dance. Direct execution still behaves identically.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main
fi
