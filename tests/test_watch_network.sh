#!/bin/bash
# Unit tests for agent/watch_network.sh helpers.
#
# Phase 4 (2026-05-19): mcp_healthy + kick_claude_session deleted along with
# the v0 single-topic recovery path. Tests now cover what remains:
#   - past_startup_grace boundary arithmetic
#   - kick_dead_helper_sessions only fires on provisional / helper-* entries
#
# Strategy: source the script (which exposes the functions but skips the
# main_loop because of the BASH_SOURCE guard), then stub tmux/jq/sleep
# with shell functions to inspect the side-effects.
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
# spawning poller "rescued" before start_agents.sh has even finished. Below
# the window → don't kick. At or past it → kick.

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

# ─── kick_dead_helper_sessions ──────────────────────────────────────────────
# Only respawns provisional helper-* tmux sessions. Non-provisional mounts
# (regular Phase 4 topics) live entirely inside the poller's daemon registry
# and have no tmux session to respawn; touching them would be wrong.

TMP_STATE=$(mktemp -d)
TMP_INSTALL=$(mktemp -d)
mkdir -p "$TMP_INSTALL/agent"
# Stub topic-wrapper so the executable-existence guard passes; we only
# need to assert tmux is called.
echo '#!/bin/bash' > "$TMP_INSTALL/agent/topic-wrapper.sh"
chmod +x "$TMP_INSTALL/agent/topic-wrapper.sh"
STATE_DIR="$TMP_STATE"
INSTALL_DIR="$TMP_INSTALL"

# Two mounts: one provisional (helper-99, should be kicked) and one
# non-provisional (topic-42, must NOT be kicked).
mkdir -p "$TMP_STATE"
cat > "$TMP_STATE/mounts.json" <<EOF
{"mounts":[
  {"thread_id":"99","path":"$HOME","label":"helper","tmux_session":"helper-99","provisional":true},
  {"thread_id":"42","path":"$HOME","label":"proj","tmux_session":"topic-42","provisional":false}
]}
EOF

TMUX_CALLS=()
tmux() {
  TMUX_CALLS+=("$*")
  case "$1" in
    has-session) return 1 ;;  # both reported dead
    *)           return 0 ;;
  esac
}
sleep() { :; }

kick_dead_helper_sessions > /dev/null 2>&1 || true

# Assert tmux was invoked for helper-99 but never for topic-42.
helper_kicked=0
topic_touched=0
for call in "${TMUX_CALLS[@]:-}"; do
  case "$call" in
    *helper-99*) helper_kicked=1 ;;
    *topic-42*)  topic_touched=1 ;;
  esac
done
if [[ "$helper_kicked" -eq 1 ]]; then
  ok "kick_dead_helper_sessions: respawns dead provisional helper-* session"
else
  ng "kick_dead_helper_sessions: respawns dead provisional helper-* session"
fi
if [[ "$topic_touched" -eq 0 ]]; then
  ok "kick_dead_helper_sessions: ignores non-provisional topic-* (daemon-owned)"
else
  ng "kick_dead_helper_sessions: ignores non-provisional topic-* (daemon-owned, got '${TMUX_CALLS[*]}')"
fi

unset -f tmux sleep
rm -rf "$TMP_STATE" "$TMP_INSTALL"

# ─── summary ─────────────────────────────────────────────────────────────────

echo
echo "watch_network.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
