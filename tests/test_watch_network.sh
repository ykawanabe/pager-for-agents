#!/bin/bash
# Unit tests for scripts/watch_network.sh helpers.
#
# Strategy: source the script (which exposes the functions but skips the
# main_loop because of the BASH_SOURCE guard), then override `pgrep` and
# `tmux` with shell functions to simulate the three states we care about.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../scripts/watch_network.sh
source "$SCRIPT_DIR/scripts/watch_network.sh"

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

unset -f tmux sleep

# ─── summary ─────────────────────────────────────────────────────────────────

echo
echo "watch_network.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
