#!/bin/bash
# E2E scenario: mid-turn auto-steer — a message sent while claude is in-flight
# interrupts the running turn (debounced) and the new message is processed in
# the next turn instead of silently queuing until the hung turn ends.
#
# Flow:
#   1. Spawn the poller with PAGER_CLAUDE_BIN=fake-claude-daemon.sh and
#      FAKE_CLAUDE_MODE=hang-no-result (turn posts text then hangs → inFlight).
#      Set PAGER_INTERRUPT_DEBOUNCE_MS=200 so the interrupt fires fast in tests.
#   2. Inject message 1 ("do something long") → daemon starts a turn, posts
#      "You said: do something long", then hangs (no result) → inFlight.
#   3. Inject message 2 ("actually, do this instead") while mid-turn →
#      registry arms the interrupt debounce (200ms). After the window elapses,
#      the registry sends an in-band interrupt control_request to the fake
#      daemon → fixture emits a result → turn-end → idle.
#   4. The idle turn-end re-arms the debounce for the queued message 2 → the
#      next turn runs and produces "You said: actually, do this instead".
#
# interrupt_on_message is ON by default — no settings.json needed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/harness.sh
source "$SCRIPT_DIR/../lib/harness.sh"

echo "▶ scenario: steer_midturn"
h_setup_sandbox "steer-midturn"
h_spawn_mock

h_seed_paired -1001234 99
h_seed_mount 42 "$SCENARIO_DIR" "iron-flow"
h_seed_session_uuid 42 "steer-uuid-bbbb"

# Fake daemon in hang-no-result mode: posts text then hangs without a result
# event, leaving the registry stuck inFlight. The fast interrupt debounce
# (200ms, well below the default 1500ms) makes the scenario complete quickly
# without brittleness. Fast message debounce too so the first turn launches
# promptly.
cat >> "$CTA_STATE_DIR/.env" <<EOF
PAGER_CLAUDE_BIN=$REPO_DIR/agent/poller/fixtures/fake-claude-daemon.sh
FAKE_CLAUDE_MODE=hang-no-result
PAGER_DAEMON_DEBOUNCE_MS=100
PAGER_INTERRUPT_DEBOUNCE_MS=200
EOF

h_spawn_poller

# 1) Send message 1 — daemon starts a turn and posts text, then hangs in-flight.
h_inject_text 42 "do something long" 99 -1001234
if h_wait_for_capture sendMessage \
   '[.[] | select(.body.text|test("You said: do something long"))] | length >= 1' 10; then
  h_ok "message 1: first turn started and streamed text (inFlight)"
else
  h_ng "message 1: first turn did NOT stream text within 10s"
  h_dump_captures
fi

# 2) Send message 2 while the daemon is still inFlight — auto-steer arms.
#    After PAGER_INTERRUPT_DEBOUNCE_MS (200ms) the registry interrupts the
#    running turn: fake daemon emits a result → turn-end → idle → message 2
#    flushes as the next turn.
h_inject_text 42 "actually, do this instead" 99 -1001234

# Give the interrupt debounce (200ms) + debounce window (100ms) + turn
# processing time to complete. 15s is generous; typical runtime ~1s.
if h_wait_for_capture sendMessage \
   '[.[] | select(.body.text|test("You said: actually, do this instead"))] | length >= 1' 15; then
  h_ok "message 2: auto-steer delivered reply for the steered message"
else
  h_ng "message 2: steered message did NOT produce a reply within 15s"
  h_dump_captures
fi

# Typing indicator must be RE-ASSERTED for the steered turn. The interrupted
# turn's turn-end cleared the marker; without an onTurnStart re-arm the steered
# turn runs with no "typing…" bubble and the bot looks idle while still working.
# Marker path: $CTA_STATE_DIR/typing/<chat>__<thread>.token.
if [[ -f "$CTA_STATE_DIR/typing/-1001234__42.token" ]]; then
  h_ok "typing indicator re-armed for the steered turn (marker present)"
else
  h_ng "typing indicator NOT re-armed for steered turn (marker absent)"
  h_dump_captures
fi

# Verify the daemon subprocess survived the interrupt (no kill/respawn).
# The session UUID must be unchanged — interrupt does NOT rotate the session.
UUID="$(tr -d '\n' < "$CTA_STATE_DIR/sessions/42" 2>/dev/null || true)"
if [[ "$UUID" == "steer-uuid-bbbb" ]]; then
  h_ok "session UUID preserved across auto-steer interrupt (graceful, not kill)"
else
  h_ng "session UUID changed across auto-steer (got: '$UUID') — suggests kill/respawn"
fi

echo
echo "scenario steer_midturn: $H_PASS passed, $H_FAIL failed"
[[ "$H_FAIL" -eq 0 ]]
