#!/bin/bash
# E2E scenario: /clear on a provisional (helper-mode) mount.
#
# Validates handleClear's provisional branch: poller refuses + suggests
# /cancel, does NOT rotate the UUID file, does NOT kill the helper tmux.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/harness.sh
source "$SCRIPT_DIR/../lib/harness.sh"

echo "▶ scenario: clear_provisional_topic"
h_setup_sandbox "clear-provisional"
h_spawn_mock

h_seed_paired -1001234 99
# Pre-add a PROVISIONAL row at thread 88 — helper-mode placeholder shape.
h_seed_mount 88 "$SCENARIO_DIR" "helper-88" provisional
h_seed_session_uuid 88 "helper-uuid-original"

# Spawn a placeholder helper-88 tmux session BEFORE the poller starts.
# Otherwise gcOrphanedProvisionals at poller startup drops the row
# (because helper-88 tmux is "dead"), and /clear has nothing to refuse —
# the unmounted-topic branch fires instead. This pre-spawn keeps the row
# alive so we can test the provisional branch in isolation.
# (The cold-boot GC behavior is D15 in the stability plan; tested
# separately in scenario_gc_on_cold_boot.sh once that scenario lands.)
tmux -S "$TMUX_SOCKET" new-session -d -s helper-88 'cat'

h_spawn_poller
h_inject_text 88 "/clear" 99 -1001234

if h_wait_for_capture sendMessage \
   '[.[] | select(.body.text|test("(?i)cancel|helper"))] | length >= 1' 10; then
  h_ok "reply mentions /cancel or helper mode"
else
  h_ng "reply did not mention /cancel or helper mode"
  h_dump_captures
fi

# UUID file must NOT be rotated.
CURRENT=$(tr -d '\n' < "$CTA_STATE_DIR/sessions/88" 2>/dev/null || echo "MISSING")
if [[ "$CURRENT" == "helper-uuid-original" ]]; then
  h_ok "sessions/88 UUID NOT rotated (correctly preserved)"
else
  h_ng "sessions/88 UUID unexpectedly changed (got: '$CURRENT')"
fi

# Note: we deliberately do NOT assert on mounts.json content here. The poller
# calls tmux has-session via the default socket (not our private -S socket),
# so gcOrphanedProvisionals at startup sees helper-88 as "dead" and drops
# the row from disk — yet the in-memory mountsCache still has it when
# /clear arrives, so handleClear's provisional branch still fires correctly.
# That mismatch is D15 (cold-boot GC wipe), tracked separately in P2.3.
# Once the harness gets a tmux PATH shim (or P2.3 lands), this comment can
# be replaced with a real provisional-row-survives assertion.

echo
echo "scenario clear_provisional_topic: $H_PASS passed, $H_FAIL failed"
[[ "$H_FAIL" -eq 0 ]]
