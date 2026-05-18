#!/bin/bash
# E2E scenario: /clear on a topic with NO mount.
#
# Validates handleClear's no-mount branch: poller replies with a friendly
# "nothing to clear" message, does NOT touch tmux, does NOT create a
# session UUID file.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/harness.sh
source "$SCRIPT_DIR/../lib/harness.sh"

echo "▶ scenario: clear_unmounted_topic"
h_setup_sandbox "clear-unmounted"
h_spawn_mock

# Pair, but NO mount for thread 9999.
h_seed_paired -1001234 99
h_spawn_poller

h_inject_text 9999 "/clear" 99 -1001234

if h_wait_for_capture sendMessage \
   '[.[] | select(.body.text|test("(?i)nothing|not mounted|no mount"))] | length >= 1' 10; then
  h_ok "got 'nothing to clear' reply for unmounted topic"
else
  h_ng "expected friendly reply for unmounted topic"
  h_dump_captures
fi

# Reply targets the right thread.
if h_wait_for_capture sendMessage \
   '[.[] | select(.body.message_thread_id == 9999)] | length >= 1' 5; then
  h_ok "reply targeted thread 9999"
else
  h_ng "reply did NOT target thread 9999"
fi

# No session UUID file should be created.
if [[ ! -e "$CTA_STATE_DIR/sessions/9999" ]]; then
  h_ok "no session UUID created for unmounted topic"
else
  h_ng "session UUID file unexpectedly created at sessions/9999"
fi

echo
echo "scenario clear_unmounted_topic: $H_PASS passed, $H_FAIL failed"
[[ "$H_FAIL" -eq 0 ]]
