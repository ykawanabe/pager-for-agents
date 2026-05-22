#!/bin/bash
# E2E scenario: mid-turn /stop aborts the running turn, then the next message
# resumes the SAME session (registry.stopTurn preserves the handle + UUID).
#
# Flow:
#   1. Spawn the poller with PAGER_CLAUDE_BIN=fake-claude-daemon.sh and
#      FAKE_CLAUDE_MODE=hang-no-result (turn posts text then hangs → inFlight).
#   2. Inject a plain message → daemon starts a turn, posts "You said: ...",
#      hangs (no result event) → registry stuck inFlight.
#   3. Inject /stop → handleStop → stopTurn kills the daemon → "⏹ Stopped." ack.
#   4. Inject another plain message → registry lazy-respawns + processes it,
#      proving the topic survived the stop (session resume path).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/harness.sh
source "$SCRIPT_DIR/../lib/harness.sh"

echo "▶ scenario: stop_resumes_session"
h_setup_sandbox "stop-resumes-session"
h_spawn_mock

h_seed_paired -1001234 99
h_seed_mount 42 "$SCENARIO_DIR" "iron-flow"
h_seed_session_uuid 42 "stop-uuid-aaaa"

# Fake daemon in hang-no-result mode + fast debounce, wired before the poller
# boots (h_spawn_poller sources $CTA_STATE_DIR/.env into the poller process).
cat >> "$CTA_STATE_DIR/.env" <<EOF
PAGER_CLAUDE_BIN=$REPO_DIR/agent/poller/fixtures/fake-claude-daemon.sh
FAKE_CLAUDE_MODE=hang-no-result
PAGER_DAEMON_DEBOUNCE_MS=100
EOF

h_spawn_poller

# 1) Start a turn that hangs in-flight.
h_inject_text 42 "do something long" 99 -1001234
if h_wait_for_capture sendMessage \
   '[.[] | select(.body.text|test("You said: do something long"))] | length >= 1' 10; then
  h_ok "first turn started (assistant text streamed)"
else
  h_ng "first turn did not stream text within 10s"
  h_dump_captures
fi

# 2) /stop aborts it.
h_inject_text 42 "/stop" 99 -1001234
if h_wait_for_capture sendMessage \
   '[.[] | select(.body.text|test("Stopped"))] | length >= 1' 10; then
  h_ok "/stop acked with 'Stopped.'"
else
  h_ng "did NOT receive Stopped ack within 10s"
  h_dump_captures
fi

# 3) Next message resumes the topic (new turn runs → respawn worked).
h_inject_text 42 "are you back" 99 -1001234
if h_wait_for_capture sendMessage \
   '[.[] | select(.body.text|test("You said: are you back"))] | length >= 1' 10; then
  h_ok "topic resumed after /stop (next message processed)"
else
  h_ng "topic did NOT resume after /stop"
  h_dump_captures
fi

# Session UUID must be UNCHANGED (stop preserves the session; only /clear rotates).
UUID="$(tr -d '\n' < "$CTA_STATE_DIR/sessions/42" 2>/dev/null || true)"
if [[ "$UUID" == "stop-uuid-aaaa" ]]; then
  h_ok "session UUID preserved across /stop (still stop-uuid-aaaa)"
else
  h_ng "session UUID changed across /stop (got: '$UUID')"
fi

echo
echo "scenario stop_resumes_session: $H_PASS passed, $H_FAIL failed"
[[ "$H_FAIL" -eq 0 ]]
