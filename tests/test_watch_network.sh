#!/bin/bash
# Unit tests for agent/watch_network.sh helpers.
#
# P6c (2026-05-22): tmux removed at runtime. The watchdog is now its own
# launchd job (com.claude-watchdog) supervising a launchd-direct poller
# (com.claude-agent). On a stale/absent heartbeat it force-restarts the
# poller via `launchctl kickstart -k` instead of respawning a tmux session.
# kick_dead_helper_sessions is gone — the poller no longer spawns helper-*
# tmux sessions (project-picking moved in-process to a buttons prompt).
#
# Tests cover what remains:
#   - past_startup_grace boundary arithmetic
#   - kick_poller_session issues `launchctl kickstart -k` for the agent label
#   - the script carries no tmux references
#
# Strategy: source the script (which exposes the functions but skips the
# main_loop because of the BASH_SOURCE guard), then stub launchctl with a
# shell function to inspect the side-effects.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../agent/watch_network.sh
source "$SCRIPT_DIR/agent/watch_network.sh"

PASS=0
FAIL=0

ok()   { echo "  ok  $1";   PASS=$((PASS + 1)); }
ng()   { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }

# ─── past_startup_grace ──────────────────────────────────────────────────────
# Gates kick_poller_session so a slow-booting Mac doesn't get its still-
# spawning poller "rescued" before launchd has even finished. Below the
# window → don't kick. At or past it → kick.

GRACE=60

if past_startup_grace 1000 1000 "$GRACE"; then
  ng "past_startup_grace: 0s uptime → should NOT pass grace"
else
  ok "past_startup_grace: 0s uptime → don't kick yet"
fi

if past_startup_grace 1030 1000 "$GRACE"; then
  ng "past_startup_grace: 30s uptime → should NOT pass grace"
else
  ok "past_startup_grace: 30s uptime → don't kick yet"
fi

# Boundary: 60s == 60s grace. Treat as past — bias toward faster recovery.
if past_startup_grace 1060 1000 "$GRACE"; then
  ok "past_startup_grace: exactly at boundary → kick"
else
  ng "past_startup_grace: exactly at boundary → kick"
fi

if past_startup_grace 1120 1000 "$GRACE"; then
  ok "past_startup_grace: 120s uptime → kick"
else
  ng "past_startup_grace: 120s uptime → kick"
fi

# ─── kick_poller_session → launchctl kickstart -k ───────────────────────────
# A stale poller heartbeat (process hung, not crashed — launchd's KeepAlive
# only catches crashes) is recovered by force-restarting the launchd job.
# kick_poller_session must call `launchctl kickstart -k` against the agent's
# gui/<uid>/<label> service target, and must NOT shell out to tmux.

LAUNCHCTL_CALLS=()
launchctl() { LAUNCHCTL_CALLS+=("$*"); return 0; }
# Trip the test if kick_poller_session reaches for tmux at all.
tmux() { LAUNCHCTL_CALLS+=("TMUX:$*"); return 0; }

kick_poller_session "test reason" > /dev/null 2>&1 || true

kickstart_seen=0
tmux_seen=0
for call in "${LAUNCHCTL_CALLS[@]:-}"; do
  case "$call" in
    TMUX:*) tmux_seen=1 ;;
    kickstart\ -k\ *com.claude-agent*) kickstart_seen=1 ;;
  esac
done

if [[ "$kickstart_seen" -eq 1 ]]; then
  ok "kick_poller_session: launchctl kickstart -k against com.claude-agent"
else
  ng "kick_poller_session: expected 'launchctl kickstart -k …com.claude-agent' (got '${LAUNCHCTL_CALLS[*]:-}')"
fi

if [[ "$tmux_seen" -eq 0 ]]; then
  ok "kick_poller_session: does not invoke tmux"
else
  ng "kick_poller_session: invoked tmux (got '${LAUNCHCTL_CALLS[*]:-}')"
fi

unset -f launchctl tmux

# ─── no tmux anywhere in the script ─────────────────────────────────────────
# P6c removed tmux from the runtime. Guard against it creeping back into the
# watchdog (a single tmux call would reintroduce the FDA prompt + dependency).

if grep -q '\btmux\b' "$SCRIPT_DIR/agent/watch_network.sh"; then
  ng "watch_network.sh: still references tmux ($(grep -c '\btmux\b' "$SCRIPT_DIR/agent/watch_network.sh") lines)"
else
  ok "watch_network.sh: tmux-free"
fi

# ─── summary ─────────────────────────────────────────────────────────────────

echo
echo "watch_network.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
