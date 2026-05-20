#!/bin/bash
# E2E scenario: Watch-live input via the Phase 4 inject channel.
#
# Validates the daemon-inject fix end-to-end through the REAL poller process:
#   1. `cta send 42 "<text>"` drops $STATE_DIR/inject/42__<nonce>.txt (no tmux).
#   2. Poller's fs.watch / loop-poll picks it up (processInjectFlags).
#   3. Registry enqueues into the (fake) claude daemon.
#   4. Fake daemon (echo mode) mirrors the text back as assistant output.
#   5. Poller forwards it → mock captures a sendMessage carrying the text.
#   6. The inject file is consumed (delete-before-enqueue).

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/harness.sh
source "$SCRIPT_DIR/../lib/harness.sh"

echo "▶ scenario: watch_live_inject"
h_setup_sandbox "watch-live-inject"
h_spawn_mock

h_seed_paired -1001234 99
h_seed_mount 42 "$SCENARIO_DIR" "iron-flow"

# Wire the fake claude daemon + a fast debounce BEFORE the poller boots
# (h_spawn_poller sources this .env). Without PAGER_CLAUDE_BIN the registry
# would try to spawn real `claude`.
cat >> "$CTA_STATE_DIR/.env" <<EOF
PAGER_CLAUDE_BIN=$REPO_DIR/agent/poller/fixtures/fake-claude-daemon.sh
PAGER_DAEMON_DEBOUNCE_MS=300
EOF

h_spawn_poller

# Deliver via the real `cta send` — the exact path Pager's Watch-live input
# field shells out to.
MARKER="INJECT_E2E_$RANDOM"
set +e
"$REPO_DIR/cli/cta" send 42 "$MARKER"
RC=$?
set -e
if [[ "$RC" -eq 0 ]]; then
  h_ok "cta send exit 0 (queued, no tmux error)"
else
  h_ng "cta send exit $RC (expected 0)"
fi

# Fake daemon echoes the injected text; poller forwards → sendMessage.
if h_wait_for_capture sendMessage \
   "[.[] | select(.body.text|test(\"$MARKER\"))] | length >= 1" 12; then
  h_ok "injected text round-tripped: inject file → poller → daemon → Telegram"
else
  h_ng "injected text did NOT round-trip within 12s"
  h_dump_captures
fi

# Delete-before-enqueue: the inject file must be gone.
if ! ls "$CTA_STATE_DIR"/inject/42__*.txt >/dev/null 2>&1; then
  h_ok "inject file consumed by poller"
else
  h_ng "inject file left behind: $(ls "$CTA_STATE_DIR"/inject/ 2>/dev/null)"
fi

echo
echo "scenario watch_live_inject: $H_PASS passed, $H_FAIL failed"
[[ "$H_FAIL" -eq 0 ]]
