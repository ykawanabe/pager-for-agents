#!/bin/bash
# Watchdog: network connectivity + poller health.
#
# Phase 4 (2026-05-19): the v0 single-topic recovery paths (kick_claude_session,
# MCP plugin health monitoring) are gone — there is no `claude` tmux session
# to monitor anymore. The poller owns claude lifecycle in-process via the
# ClaudeDaemonRegistry. This watchdog only needs to:
#   1. Notice when the poller's bun process has died (heartbeat stale) and
#      respawn it via kick_poller_session.
#   2. Respawn helper-<id> tmux sessions that died mid-mount-pick (rare).
#
# The loop itself never exits — failures inside the loop are caught with
# `|| true` so a single ping or tmux error can't take the watchdog down.
#
# NOTE: We intentionally do NOT enable `set -e` here because the main loop
# must survive transient errors.
set -uo pipefail

# Defensive PATH augmentation. tmux and pgrep live outside launchd's stripped
# default PATH; ensure they resolve when this script is spawned by the
# LaunchAgent or by a launchd-spawned caller. See cli/cta for context.
export PATH="$HOME/.bun/bin:/opt/homebrew/bin:/usr/local/bin:${PATH:-/usr/bin:/bin}:$HOME/.local/bin"

# Startup grace period before we treat a missing poller session or stale
# heartbeat as a real problem worth kicking. 60s covers slow boots, bun's
# cold-start window, and the watchdog's own first loop iteration.
WATCHDOG_STARTUP_GRACE_SECS=60

STATE_DIR="${CTA_STATE_DIR:-$HOME/.pager}"
INSTALL_DIR="${CTA_INSTALL_DIR:-$HOME/.local/share/pager}"

# Heartbeat staleness threshold in seconds. Poller touches heartbeat every
# getUpdates cycle (~25-30s under normal long-poll). 120s = ~4 missed cycles,
# unambiguous "dead poller" rather than a flaky network.
POLLER_STALE_THRESHOLD_SECS=120

# Ping cadence. Long enough to be polite to public DNS / Telegram, short
# enough to react to a wifi drop in <1 minute.
PING_INTERVAL=10

load_env() {
  local env_file="$STATE_DIR/.env"
  if [[ ! -f "$env_file" ]]; then
    echo "Missing $env_file — run install.sh first." >&2
    exit 1
  fi
  set -a
  # shellcheck source=/dev/null
  source "$env_file"
  set +a
}

# Respawn helper-<id> mount-helper tmux sessions that died mid-pick. The
# poller spawns these on-demand when a user messages an unmounted topic;
# their lifecycle is short (claude TUI runs to completion or user cancels).
# A crash mid-pick leaves the topic in "provisional mount" state with no
# live helper to drive it — without this respawn, the user has to send a
# fresh message to trigger spawnHelper again, which is unintuitive.
#
# We only respawn helper-* (provisional) entries; non-provisional mounts
# are handled by the poller's daemon registry, which auto-respawns on
# crash without any tmux involvement.
kick_dead_helper_sessions() {
  local mounts_file="$STATE_DIR/mounts.json"
  [[ -f "$mounts_file" ]] || return 0
  local wrapper="$INSTALL_DIR/agent/topic-wrapper.sh"
  [[ -x "$wrapper" ]] || return 0
  local entries
  entries=$(jq -r '.mounts[] | select(.thread_id != "*") | select((.provisional // false) == true) | [(.thread_id|tostring), .path, .tmux_session] | @tsv' "$mounts_file" 2>/dev/null) || return 0
  [[ -z "$entries" ]] && return 0
  while IFS=$'\t' read -r thread_id project_path tmux_session; do
    [[ -z "$thread_id" ]] && continue
    [[ -d "$project_path" ]] || continue
    # Only kick sessions that look like helpers; defensive against stale
    # mounts.json entries from before Phase 4.
    [[ "$tmux_session" == helper-* ]] || continue
    if tmux has-session -t "$tmux_session" 2>/dev/null; then
      continue
    fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] respawning dead helper session: $tmux_session (thread $thread_id)"
    local quoted_cmd
    quoted_cmd=$(printf '%q ' "$wrapper" "$thread_id" "$project_path" "$tmux_session" "helper")
    tmux new-session -d -s "$tmux_session" "$quoted_cmd" 2>/dev/null || {
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠ failed to respawn $tmux_session" >&2
      continue
    }
    sleep 0.2
    tmux pipe-pane -t "$tmux_session" -o "cat >> $STATE_DIR/agent.log" 2>/dev/null || true
  done <<< "$entries"
}

# Respawn the `poller` tmux session in place. Used when the poller's bun
# process has died (heartbeat went stale) — the LaunchAgent only watches
# start_agents.sh, which exits successfully after spawning, so launchd's
# KeepAlive never fires for a poller death. Without this, a dead poller
# stays dead until the next login (no inbound messages reach any topic).
kick_poller_session() {
  local reason="$1"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $reason — restarting poller session"
  # Pull token from the plugin .env, same source start_agents.sh uses.
  local plugin_env="$HOME/.claude/channels/telegram/.env"
  local token=""
  if [[ -f "$plugin_env" ]]; then
    token=$(grep '^TELEGRAM_BOT_TOKEN=' "$plugin_env" | head -1 | cut -d= -f2- | sed 's/^"//; s/"$//')
  fi
  if [[ -z "$token" ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠ poller kick aborted — TELEGRAM_BOT_TOKEN missing in $plugin_env" >&2
    return 1
  fi
  if [[ -z "${MAIN_CHAT_ID:-}" ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠ poller kick aborted — MAIN_CHAT_ID missing in env" >&2
    return 1
  fi
  local poller_path="$INSTALL_DIR/agent/poller/poller.ts"
  if [[ ! -f "$poller_path" ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠ poller kick aborted — $poller_path missing" >&2
    return 1
  fi
  tmux kill-session -t poller 2>/dev/null || true
  sleep 1
  # Source both project and plugin .env files at spawn time so the poller's
  # bun process inherits the full project env — operator settings plus the
  # canonical TELEGRAM_BOT_TOKEN from the plugin .env (freshly read, picks
  # up rotations). Previously only two vars were forwarded via `-e`, dropping
  # every other operator setting on each watchdog kick (D12 in docs/plans/
  # multi-topic-stability-plan.md).
  local env_file="$STATE_DIR/.env"
  local wrapper_cmd
  wrapper_cmd="set -a; [ -f '$env_file' ] && . '$env_file'; [ -f '$plugin_env' ] && . '$plugin_env'; set +a; exec bun '$poller_path'"
  tmux new-session -d -s poller "$wrapper_cmd" || true
  # Brief settle before pipe-pane attach — start_agents.sh hit an intermittent
  # "can't find pane: poller" without this on first launch.
  sleep 0.2
  tmux pipe-pane -t poller -o "cat >> $STATE_DIR/agent.log" 2>/dev/null || true
  if tmux has-session -t poller 2>/dev/null; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] poller kick complete — session active"
    return 0
  fi
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠ poller kick failed — session not present after restart" >&2
  return 1
}

# Has the watchdog been up long enough that a missing poller session is a
# real problem worth kicking, vs a slow boot we should wait out? Pure
# arithmetic so the unit test can pin specific now/started values without
# sleeping.
#   $1 = now (epoch seconds)
#   $2 = watchdog start time (epoch seconds)
#   $3 = grace window in seconds
past_startup_grace() {
  local now=$1 started_at=$2 grace=$3
  [[ $(( now - started_at )) -ge "$grace" ]]
}

main_loop() {
  load_env
  # Two probes: general internet (PING_TARGET) and Telegram itself
  # (TELEGRAM_PING_TARGET). Pinging only 8.8.8.8 misses the failure mode
  # where the network is up but api.telegram.org is unreachable.
  local NET_TARGET="${PING_TARGET:-8.8.8.8}"
  local TG_TARGET="${TELEGRAM_PING_TARGET:-api.telegram.org}"
  local WAS_OFFLINE=0
  local WAS_TG_DOWN=0
  local WATCHDOG_STARTED_AT
  WATCHDOG_STARTED_AT=$(date +%s)

  while true; do
    local net_up=0 tg_up=0
    ping -c 1 -W 2 "$NET_TARGET" > /dev/null 2>&1 && net_up=1
    ping -c 1 -W 2 "$TG_TARGET"  > /dev/null 2>&1 && tg_up=1

    if [[ "$net_up" -eq 0 && "$tg_up" -eq 0 ]]; then
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] Offline (network + Telegram both unreachable)"
      WAS_OFFLINE=1
      WAS_TG_DOWN=1
    elif [[ "$tg_up" -eq 0 ]]; then
      # Network is up but Telegram is blocked. Don't kick — the bot can't
      # reach Telegram anyway, restarting won't help. Wait for recovery.
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] Online but Telegram unreachable"
      WAS_TG_DOWN=1
    else
      # Both reachable.
      if [[ "$WAS_OFFLINE" -eq 1 || "$WAS_TG_DOWN" -eq 1 ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Connectivity restored"
        WAS_OFFLINE=0
        WAS_TG_DOWN=0
      fi
      # Poller health: heartbeat freshness check.
      if [[ -f "$STATE_DIR/heartbeat-poller" ]]; then
        local hb_age=$(( $(date +%s) - $(stat -f %m "$STATE_DIR/heartbeat-poller" 2>/dev/null || echo 0) ))
        if [[ "$hb_age" -gt "$POLLER_STALE_THRESHOLD_SECS" ]]; then
          if past_startup_grace "$(date +%s)" "$WATCHDOG_STARTED_AT" "$WATCHDOG_STARTUP_GRACE_SECS"; then
            kick_poller_session "poller heartbeat stale (${hb_age}s)"
          else
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Online — poller heartbeat stale (${hb_age}s, in startup grace)"
          fi
        else
          echo "[$(date '+%Y-%m-%d %H:%M:%S')] Online"
        fi
      elif past_startup_grace "$(date +%s)" "$WATCHDOG_STARTED_AT" "$WATCHDOG_STARTUP_GRACE_SECS"; then
        # Heartbeat file absent past startup grace — poller never spawned
        # or its first touchHeartbeat() call hasn't landed. Respawn.
        kick_poller_session "poller heartbeat absent"
      else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Online — poller heartbeat absent (in startup grace)"
      fi
      # Independent of poller health: respawn any helper-* tmux session
      # that has gone missing mid-mount-pick. Mount-helpers are the only
      # tmux sessions still spawned outside the poller's in-process daemons.
      if past_startup_grace "$(date +%s)" "$WATCHDOG_STARTED_AT" "$WATCHDOG_STARTUP_GRACE_SECS"; then
        kick_dead_helper_sessions
      fi
    fi
    sleep "$PING_INTERVAL"
  done
}

# When sourced (e.g. by tests/test_watch_network.sh) we expose the functions
# but skip the runtime loop. Direct execution still behaves identically.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main_loop
fi
