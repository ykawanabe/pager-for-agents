#!/bin/bash
# Watchdog: network connectivity + MCP plugin health.
#
# Recovers from two distinct failure modes:
#   1. Network outage — kick claude session when connection returns.
#   2. Silent plugin death — claude process alive, but bun MCP server has
#      exited (we've seen this happen without taking claude itself down,
#      leaving the bot unreachable). Kick after 3 consecutive failed checks
#      (~30s) so we don't false-trigger during normal plugin startup.
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

# Number of consecutive failed MCP checks before we kick the session. At a
# 10s loop interval that's ~30s of grace, which covers the plugin's cold-start
# window after `claude --channels` boots.
MCP_FAILURE_THRESHOLD=3

# Startup grace period before we treat a missing claude tmux session as a
# failure worth kicking. start_agents.sh launches both sessions with a 3s gap;
# 60s gives plenty of slack for slow boots, MCP cold-start, and the watchdog's
# own first loop iteration before we start enforcing "session must exist."
WATCHDOG_STARTUP_GRACE_SECS=60

STATE_DIR="${CTA_STATE_DIR:-$HOME/.pager}"

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

kick_claude_session() {
  local reason="$1"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $reason — restarting claude session"
  tmux kill-session -t "$TMUX_SESSION_CLAUDE" 2>/dev/null || true
  sleep 2
  tmux new-session -d -s "$TMUX_SESSION_CLAUDE" "$HOME/.local/bin/restart_claude.sh" || true
  # Re-attach pipe-pane so the recreated session's output keeps landing in
  # the activity log; otherwise the log goes silent after the first kick.
  tmux pipe-pane -t "$TMUX_SESSION_CLAUDE" -o "cat >> $STATE_DIR/agent.log" || true
  # Verify: silent failures here used to leave the user with a dead bot and
  # a log line that lied about success. Return non-zero so callers can see
  # the failure (and so the test can assert against it).
  if tmux has-session -t "$TMUX_SESSION_CLAUDE" 2>/dev/null; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] kick complete — session active"
    return 0
  fi
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠ kick failed — session not present after restart" >&2
  return 1
}

# Returns 0 (healthy) if claude isn't running yet, OR if both claude and the
# bun MCP server are running. Returns 1 (unhealthy) only when claude is alive
# but bun is missing — the silent-plugin-death state.
mcp_healthy() {
  pgrep -f "claude --channels plugin:telegram" >/dev/null || return 0
  pgrep -f "bun .*server\.ts" >/dev/null
}

# Has the watchdog been up long enough that a missing claude session is a real
# problem worth kicking, vs a slow boot we should wait out? Pure arithmetic so
# the unit test can pin specific now/started values without sleeping.
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
  # where the network is up but api.telegram.org is unreachable (carrier
  # block, Telegram outage, DNS issue) — the bot's poll loop sits idle
  # without any external signal. We kick on transition out of either down
  # state.
  local NET_TARGET="${PING_TARGET:-8.8.8.8}"
  local TG_TARGET="${TELEGRAM_PING_TARGET:-api.telegram.org}"
  local WAS_OFFLINE=0
  local WAS_TG_DOWN=0
  local MCP_FAILS=0
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
      MCP_FAILS=0
    elif [[ "$tg_up" -eq 0 ]]; then
      # Network is up but Telegram is blocked. Don't kick — the bot can't
      # reach Telegram anyway, restarting won't help. Wait for recovery.
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] Online but Telegram unreachable"
      WAS_TG_DOWN=1
      MCP_FAILS=0
    else
      # Both reachable.
      if [[ "$WAS_OFFLINE" -eq 1 || "$WAS_TG_DOWN" -eq 1 ]]; then
        # In MULTI_TOPIC mode the v0 `claude` tmux session must not exist —
        # spawning it via restart_claude.sh boots the official Telegram plugin
        # which races our poller (409 Conflict, silent message drops). The
        # poller and per-topic sessions are owned by LaunchAgent KeepAlive
        # and topic-wrapper.sh's own restart loop; both recover from a
        # connectivity blip without watchdog intervention.
        if [[ "${MULTI_TOPIC:-0}" != "1" ]]; then
          kick_claude_session "Connectivity restored"
        else
          echo "[$(date '+%Y-%m-%d %H:%M:%S')] Connectivity restored (MULTI_TOPIC — no kick)"
        fi
        WAS_OFFLINE=0
        WAS_TG_DOWN=0
        MCP_FAILS=0
      elif [[ "${MULTI_TOPIC:-0}" == "1" ]]; then
        # MULTI_TOPIC mode owns its own per-topic restart loops via
        # topic-wrapper.sh. The v0 `claude` tmux session does not exist and
        # should not be recreated — recreating it spawns the official plugin's
        # own getUpdates poller, which fights ours and silently drops messages
        # (409 Conflict). Just ping the poller's heartbeat; if it's dead,
        # launchd respawns start_agents.sh via the LaunchAgent's KeepAlive.
        if [[ -f "$STATE_DIR/heartbeat-poller" ]]; then
          local hb_age=$(( $(date +%s) - $(stat -f %m "$STATE_DIR/heartbeat-poller" 2>/dev/null || echo 0) ))
          if [[ "$hb_age" -gt 120 ]]; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Online — poller heartbeat stale (${hb_age}s)"
          else
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Online (MULTI_TOPIC)"
          fi
        else
          echo "[$(date '+%Y-%m-%d %H:%M:%S')] Online — poller heartbeat absent (MULTI_TOPIC)"
        fi
      elif ! tmux has-session -t "$TMUX_SESSION_CLAUDE" 2>/dev/null; then
        # v0 orphan-session recovery (single-topic mode only).
        if past_startup_grace "$(date +%s)" "$WATCHDOG_STARTED_AT" "$WATCHDOG_STARTUP_GRACE_SECS"; then
          kick_claude_session "claude tmux session missing"
          MCP_FAILS=0
        else
          local uptime=$(( $(date +%s) - WATCHDOG_STARTED_AT ))
          echo "[$(date '+%Y-%m-%d %H:%M:%S')] Online — claude session missing (startup grace: ${uptime}/${WATCHDOG_STARTUP_GRACE_SECS}s)"
        fi
      else
        if mcp_healthy; then
          MCP_FAILS=0
          echo "[$(date '+%Y-%m-%d %H:%M:%S')] Online"
        else
          MCP_FAILS=$((MCP_FAILS + 1))
          echo "[$(date '+%Y-%m-%d %H:%M:%S')] Online — MCP plugin missing ($MCP_FAILS/$MCP_FAILURE_THRESHOLD)"
          if [[ "$MCP_FAILS" -ge "$MCP_FAILURE_THRESHOLD" ]]; then
            kick_claude_session "MCP plugin dead (bun server.ts gone while claude alive)"
            MCP_FAILS=0
          fi
        fi
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
