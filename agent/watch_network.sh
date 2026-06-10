#!/bin/bash
# Watchdog: network connectivity + poller health.
#
# P6c (2026-05-22): runtime is launchd-direct, no terminal multiplexer.
# This watchdog runs as its own launchd job (com.claude-watchdog) and the
# poller runs as com.claude-agent. launchd's KeepAlive respawns the poller
# when its process *crashes* (non-zero exit), but it can't notice a poller
# that is alive-but-hung. That is this watchdog's remaining job:
#   1. Notice when the poller's heartbeat has gone stale/absent and force a
#      clean restart of the launchd job via `launchctl kickstart -k`.
#   2. Log network reachability (general internet + Telegram) for diagnosis.
#
# Helper-session respawning is gone: the poller no longer spawns per-topic or
# helper subprocesses outside its in-process ClaudeDaemonRegistry (project
# picking for unmounted topics is an in-process buttons prompt now).
#
# The loop itself never exits — failures inside the loop are caught with
# `|| true` so a single ping or launchctl error can't take the watchdog down.
#
# NOTE: We intentionally do NOT enable `set -e` here because the main loop
# must survive transient errors.
set -uo pipefail

# Defensive PATH augmentation. bun / pgrep / launchctl must resolve when this
# script is spawned by launchd (which hands down a stripped default PATH).
# See cli/cta for the full explanation.
export PATH="$HOME/.bun/bin:/opt/homebrew/bin:/usr/local/bin:${PATH:-/usr/bin:/bin}:$HOME/.local/bin"

# launchd label of the poller job we supervise. Overridable for tests/dev.
AGENT_LABEL="${AGENT_LABEL:-com.claude-agent}"

# Startup grace period before we treat a missing poller or stale heartbeat
# as a real problem worth kicking. 60s covers slow boots, bun's cold-start
# window, and the watchdog's own first loop iteration.
WATCHDOG_STARTUP_GRACE_SECS=60

STATE_DIR="${CTA_STATE_DIR:-$HOME/.pager}"

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

# Force a clean restart of the poller launchd job. Used when the poller's
# heartbeat went stale/absent — the process is hung or gone in a way launchd's
# KeepAlive didn't catch (KeepAlive only fires on a process *exit*; a hung but
# live process never exits). `kickstart -k` SIGKILLs the running instance (if
# any) and immediately relaunches it under launchd, so the restarted poller is
# still fully supervised. Pure launchctl — no terminal multiplexer involved.
kick_poller_session() {
  local reason="$1"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $reason — kickstarting $AGENT_LABEL"
  if launchctl kickstart -k "gui/$(id -u)/$AGENT_LABEL" 2>/dev/null; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] poller kick complete ($AGENT_LABEL)"
    return 0
  fi
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠ poller kick failed — launchctl kickstart $AGENT_LABEL returned non-zero" >&2
  return 1
}

# Has the watchdog been up long enough that a missing/stale poller is a real
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
  # where the network is up but api.telegram.org is unreachable.
  local NET_TARGET="${PING_TARGET:-8.8.8.8}"
  local TG_TARGET="${TELEGRAM_PING_TARGET:-api.telegram.org}"
  local WAS_OFFLINE=0
  local WAS_TG_DOWN=0
  local WATCHDOG_STARTED_AT
  WATCHDOG_STARTED_AT=$(date +%s)

  # Clean shutdown: `cta stop` (launchctl unload) sends SIGTERM. Trap it and
  # exit 0 so the watchdog terminates cleanly. Paired with KeepAlive set to
  # {SuccessfulExit: false} in com.claude-watchdog.plist, a clean exit keeps the
  # job DOWN; a crash (non-zero exit) still relaunches it. Without this trap the
  # old unconditional KeepAlive respawned the watchdog after every intentional
  # stop — the immortal-watchdog bug that re-kicked the poller back to life.
  trap 'exit 0' TERM INT

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
            kick_poller_session "poller heartbeat stale (${hb_age}s)" || true
          else
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Online — poller heartbeat stale (${hb_age}s, in startup grace)"
          fi
        else
          echo "[$(date '+%Y-%m-%d %H:%M:%S')] Online"
        fi
      elif past_startup_grace "$(date +%s)" "$WATCHDOG_STARTED_AT" "$WATCHDOG_STARTUP_GRACE_SECS"; then
        # Heartbeat file absent past startup grace — poller never spawned
        # or its first touchHeartbeat() call hasn't landed. Kick it.
        kick_poller_session "poller heartbeat absent" || true
      else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Online — poller heartbeat absent (in startup grace)"
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
