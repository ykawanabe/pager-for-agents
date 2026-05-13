#!/bin/bash
# Unit tests for agent/watch_network.sh helpers.
#
# Strategy: source the script (which exposes the functions but skips the
# main_loop because of the BASH_SOURCE guard), then override `pgrep` and
# `tmux` with shell functions to simulate the three states we care about.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../agent/watch_network.sh
source "$SCRIPT_DIR/agent/watch_network.sh"

PASS=0
FAIL=0

ok()   { echo "  ok  $1";   PASS=$((PASS + 1)); }
ng()   { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }

# ─── mcp_healthy ─────────────────────────────────────────────────────────────

# Case 1: claude itself isn't running yet (e.g. startup) → considered healthy.
# We don't want to kick a session that hasn't booted.
pgrep() { return 1; }
if mcp_healthy; then ok "mcp_healthy: claude not running → healthy"
else                 ng "mcp_healthy: claude not running → healthy"; fi

# Case 2: claude AND bun both running → healthy.
pgrep() { return 0; }
if mcp_healthy; then ok "mcp_healthy: claude + bun running → healthy"
else                 ng "mcp_healthy: claude + bun running → healthy"; fi

# Case 3: claude alive, bun missing → unhealthy. This is the silent-plugin-death
# state the watchdog is meant to recover from.
pgrep() {
  case "$*" in
    *"claude --channels"*) return 0 ;;
    *"bun"*)               return 1 ;;
    *)                     return 1 ;;
  esac
}
if mcp_healthy; then ng "mcp_healthy: claude alive, bun dead → unhealthy"
else                 ok "mcp_healthy: claude alive, bun dead → unhealthy"; fi

unset -f pgrep

# ─── kick_claude_session ─────────────────────────────────────────────────────

# Verify it invokes tmux with kill-session + new-session in that order, and
# passes the right session name.
TMUX_SESSION_CLAUDE="claude-test"
TMUX_CALLS=()
tmux() {
  TMUX_CALLS+=("$*")
  return 0
}
# sleep is called inside kick_claude_session — stub it to keep the test fast.
sleep() { :; }

kick_claude_session "unit test" > /dev/null

if [[ "${TMUX_CALLS[0]}" == "kill-session -t claude-test" ]]; then
  ok "kick_claude_session: kills existing session first"
else
  ng "kick_claude_session: kills existing session first (got '${TMUX_CALLS[0]}')"
fi

if [[ "${TMUX_CALLS[1]}" == "new-session -d -s claude-test "*"restart_claude.sh"* ]]; then
  ok "kick_claude_session: spawns new restart_claude.sh session"
else
  ng "kick_claude_session: spawns new restart_claude.sh session (got '${TMUX_CALLS[1]}')"
fi

# Recreated session must get pipe-pane re-attached, otherwise the activity
# log goes dark after the first kick — exactly the bug the user hit.
if [[ "${TMUX_CALLS[2]}" == "pipe-pane -t claude-test -o cat >> "*"agent.log" ]]; then
  ok "kick_claude_session: re-attaches pipe-pane to agent.log"
else
  ng "kick_claude_session: re-attaches pipe-pane to agent.log (got '${TMUX_CALLS[2]}')"
fi

unset -f tmux sleep

# Failure path: when the session isn't present after restart, kick must
# return non-zero so callers can detect it (instead of logging fake success
# and moving on, which is what happened before the verify step was added).
TMUX_CALLS=()
tmux() {
  TMUX_CALLS+=("$*")
  case "$1" in
    has-session) return 1 ;;  # simulate session didn't actually start
    *)           return 0 ;;
  esac
}
sleep() { :; }

if kick_claude_session "verify failure" > /dev/null 2>&1; then
  ng "kick_claude_session: returns non-zero on verify failure"
else
  ok "kick_claude_session: returns non-zero on verify failure"
fi

unset -f tmux sleep

# ─── past_startup_grace ──────────────────────────────────────────────────────
# The orphan-session kick is gated on this helper so a slow-booting Mac doesn't
# get its still-spawning claude session "rescued" before start_agents.sh has
# even finished. Below the window → don't kick. At or past it → kick.

GRACE=60

# Just-started: 0s of uptime.
if past_startup_grace 1000 1000 "$GRACE"; then
  ng "past_startup_grace: 0s uptime → should NOT pass grace"
else
  ok "past_startup_grace: 0s uptime → don't kick yet"
fi

# Mid-grace: 30s of 60s.
if past_startup_grace 1030 1000 "$GRACE"; then
  ng "past_startup_grace: 30s uptime → should NOT pass grace"
else
  ok "past_startup_grace: 30s uptime → don't kick yet"
fi

# Exactly at boundary: 60s == 60s grace. Treat as past — bias toward recovering
# faster, the boundary tick is functionally equivalent to "we waited."
if past_startup_grace 1060 1000 "$GRACE"; then
  ok "past_startup_grace: exactly at boundary → kick"
else
  ng "past_startup_grace: exactly at boundary → kick"
fi

# Past grace: 120s, well clear.
if past_startup_grace 1120 1000 "$GRACE"; then
  ok "past_startup_grace: 120s uptime → kick"
else
  ng "past_startup_grace: 120s uptime → kick"
fi

# ─── summary ─────────────────────────────────────────────────────────────────

echo
echo "watch_network.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
