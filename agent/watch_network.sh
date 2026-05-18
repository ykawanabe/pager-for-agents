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
INSTALL_DIR="${CTA_INSTALL_DIR:-$HOME/.local/share/pager}"

# Heartbeat staleness threshold in seconds. Poller touches heartbeat every
# getUpdates cycle (~25-30s under normal long-poll). 120s = ~4 missed cycles,
# unambiguous "dead poller" rather than a flaky network.
POLLER_STALE_THRESHOLD_SECS=120

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

# MULTI_TOPIC: respawn the `poller` tmux session in place. Used when the
# poller's bun process has died (heartbeat went stale) — the v0 LaunchAgent
# only watches start_agents.sh, which exits successfully after spawning, so
# launchd's KeepAlive never fires for a poller death. Without this, a dead
# poller stays dead until the next login (no inbound messages reach any
# topic). The respawn is targeted: it touches only the `poller` session, not
# the per-topic claudes — those have their own restart loop via
# topic-wrapper.sh and are likely still running mid-conversation.
# MULTI_TOPIC: respawn dead per-topic tmux sessions. The wrapper's restart
# loop only recovers crashes WITHIN a tmux session — if the session itself
# is gone (manual kill, OOM, system reboot mid-day), nothing brings it back
# until the next inbound message AND a fresh `cta start`. That makes "I sent
# a message to topic X and got nothing" the canonical user-visible failure.
# Iterate mounts.json on every loop tick; for each numeric/dm mount whose
# tmux_session has no tmux pane, respawn via topic-wrapper.sh. Wildcard ("*")
# entries are routing fallbacks, not standalone sessions — skip them.
kick_dead_topic_sessions() {
  local mounts_file="$STATE_DIR/mounts.json"
  [[ -f "$mounts_file" ]] || return 0
  local wrapper="$INSTALL_DIR/agent/topic-wrapper.sh"
  [[ -x "$wrapper" ]] || return 0
  # Filter out provisional rows: those are helper-mode placeholders whose
  # lifecycle is owned by gcOrphanedProvisionals (poller-side). Respawning
  # a dead helper-<id> as a topic-mode claude in $HOME is the D11 bug.
  local entries
  entries=$(jq -r '.mounts[] | select(.thread_id != "*") | select((.provisional // false) == false) | [(.thread_id|tostring), .path, .tmux_session] | @tsv' "$mounts_file" 2>/dev/null) || return 0
  [[ -z "$entries" ]] && return 0
  while IFS=$'\t' read -r thread_id project_path tmux_session; do
    [[ -z "$thread_id" ]] && continue
    [[ -d "$project_path" ]] || continue
    if tmux has-session -t "$tmux_session" 2>/dev/null; then
      continue
    fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] respawning dead topic session: $tmux_session (thread $thread_id)"
    local quoted_cmd
    quoted_cmd=$(printf '%q ' "$wrapper" "$thread_id" "$project_path" "$tmux_session")
    tmux new-session -d -s "$tmux_session" "$quoted_cmd" 2>/dev/null || {
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠ failed to respawn $tmux_session" >&2
      continue
    }
    sleep 0.2
    tmux pipe-pane -t "$tmux_session" -o "cat >> $STATE_DIR/agent.log" 2>/dev/null || true
  done <<< "$entries"
}

kick_poller_session() {
  local reason="$1"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $reason — restarting poller session"
  # Pull token from the plugin .env, same source start_agents.sh uses. Done
  # at kick time rather than cached at boot so a rotated token is picked up.
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
  # bun process inherits the full project env — PAGER_DISABLE_HELPER,
  # MULTI_TOPIC, custom path overrides, plus the canonical TELEGRAM_BOT_TOKEN
  # from the plugin .env (freshly read, picks up rotations). Previously only
  # two vars were forwarded via `-e`, dropping every other operator setting
  # on each watchdog kick (D12 in docs/plans/multi-topic-stability-plan.md).
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
        # MULTI_TOPIC mode owns per-topic restart loops via topic-wrapper.sh.
        # The poller itself, however, has no auto-recover: the LaunchAgent
        # watches start_agents.sh (which exits successfully after spawning),
        # so KeepAlive never fires for a dead poller. A bun crash inside the
        # `poller` tmux session is terminal — no inbound message reaches any
        # topic until the next login. Detect via stale heartbeat and respawn
        # the poller session in place. Per-topic claudes are untouched (their
        # tmux sessions stay alive, mid-conversation state preserved).
        #
        # We still must NOT recreate the v0 `claude` session — that boots the
        # official plugin's own getUpdates poller and races ours (409 Conflict
        # → silent message drops).
        if [[ -f "$STATE_DIR/heartbeat-poller" ]]; then
          local hb_age=$(( $(date +%s) - $(stat -f %m "$STATE_DIR/heartbeat-poller" 2>/dev/null || echo 0) ))
          if [[ "$hb_age" -gt "$POLLER_STALE_THRESHOLD_SECS" ]]; then
            if past_startup_grace "$(date +%s)" "$WATCHDOG_STARTED_AT" "$WATCHDOG_STARTUP_GRACE_SECS"; then
              kick_poller_session "poller heartbeat stale (${hb_age}s)"
            else
              echo "[$(date '+%Y-%m-%d %H:%M:%S')] Online — poller heartbeat stale (${hb_age}s, in startup grace)"
            fi
          else
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Online (MULTI_TOPIC)"
          fi
        elif past_startup_grace "$(date +%s)" "$WATCHDOG_STARTED_AT" "$WATCHDOG_STARTUP_GRACE_SECS"; then
          # Heartbeat file absent past startup grace — poller never spawned
          # or its first touchHeartbeat() call hasn't landed. Either way, a
          # respawn is the correct recovery.
          kick_poller_session "poller heartbeat absent"
        else
          echo "[$(date '+%Y-%m-%d %H:%M:%S')] Online — poller heartbeat absent (MULTI_TOPIC, in startup grace)"
        fi
        # Independent of poller health: respawn any per-topic tmux session
        # that has gone missing. Topic sessions can die without taking the
        # poller down (manual kill, OOM inside one claude, etc.); without
        # this loop they stay dead until the next `cta start`.
        if past_startup_grace "$(date +%s)" "$WATCHDOG_STARTED_AT" "$WATCHDOG_STARTUP_GRACE_SECS"; then
          kick_dead_topic_sessions
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
