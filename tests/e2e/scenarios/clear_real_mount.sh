#!/bin/bash
# E2E scenario: /clear on a mounted topic.
#
# Validates D14 fix end-to-end through the real poller process:
#   1. Inject /clear via mock getUpdates.
#   2. Poller routes through tryHandleCommand → handleClear.
#   3. UUID file rotated.
#   4. tmux kill-session attempted (silently no-op since no real topic-42
#      tmux exists in this sandbox).
#   5. sendMessage captured with "Cleared" in body.text.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/harness.sh
source "$SCRIPT_DIR/../lib/harness.sh"

echo "▶ scenario: clear_real_mount"
h_setup_sandbox "clear-real-mount"
h_spawn_mock

# Seed paired + mount + session UUID before spawning the poller so the
# initial mountsCache load picks them up.
h_seed_paired -1001234 99
h_seed_mount 42 "$SCENARIO_DIR" "iron-flow"
h_seed_session_uuid 42 "old-uuid-aaaa"

h_spawn_poller

# Inject /clear from the paired user in thread 42.
h_inject_text 42 "/clear" 99 -1001234

# Expect a sendMessage to thread 42 containing "Cleared".
if h_wait_for_capture sendMessage \
   '[.[] | select(.body.text|test("Cleared"))] | length >= 1' 10; then
  h_ok "sendMessage 'Cleared…' captured for /clear handler"
else
  h_ng "did NOT receive Cleared ack within 10s"
  h_dump_captures
fi

# Assert UUID file was rotated (content != "old-uuid-aaaa").
NEW_UUID=""
if [[ -f "$CTA_STATE_DIR/sessions/42" ]]; then
  NEW_UUID=$(tr -d '\n' < "$CTA_STATE_DIR/sessions/42")
fi
if [[ -n "$NEW_UUID" && "$NEW_UUID" != "old-uuid-aaaa" ]]; then
  h_ok "sessions/42 UUID rotated (now: $NEW_UUID)"
else
  h_ng "sessions/42 UUID NOT rotated (got: '$NEW_UUID', expected != old-uuid-aaaa)"
fi

# Assert the captured sendMessage points at the right thread.
if h_wait_for_capture sendMessage \
   '[.[] | select(.body.message_thread_id == 42)] | length >= 1' 5; then
  h_ok "ack targeted thread 42 (message_thread_id correct)"
else
  h_ng "ack did NOT target thread 42"
fi

echo
echo "scenario clear_real_mount: $H_PASS passed, $H_FAIL failed"
[[ "$H_FAIL" -eq 0 ]]
