#!/bin/bash
# E2E scenario: /effort command sets per-topic reasoning effort.
#
# Through the REAL poller: inject "/effort xhigh" from the paired user,
# expect an ack + the per-topic effort file persisted; then an invalid level
# is rejected.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/harness.sh
source "$SCRIPT_DIR/../lib/harness.sh"

echo "▶ scenario: effort_command"
h_setup_sandbox "effort-command"
h_spawn_mock
h_seed_paired -1001234 99
h_seed_mount 42 "$SCENARIO_DIR" "iron-flow"
cat >> "$CTA_STATE_DIR/.env" <<EOF
PAGER_CLAUDE_BIN=$REPO_DIR/agent/poller/fixtures/fake-claude-daemon.sh
PAGER_DAEMON_DEBOUNCE_MS=300
EOF
h_spawn_poller

# Valid level → ack + persisted.
h_inject_text 42 "/effort xhigh" 99 -1001234
if h_wait_for_capture sendMessage \
   '[.[] | select(.body.text|test("effort set to xhigh"))] | length >= 1' 10; then
  h_ok "/effort xhigh acknowledged"
else
  h_ng "/effort xhigh not acknowledged"; h_dump_captures
fi
if [[ "$(cat "$CTA_STATE_DIR/effort/42" 2>/dev/null)" == "xhigh" ]]; then
  h_ok "effort/42 persisted = xhigh"
else
  h_ng "effort/42 not persisted (got '$(cat "$CTA_STATE_DIR/effort/42" 2>/dev/null)')"
fi

# Invalid level → rejected, file unchanged.
h_inject_text 42 "/effort turbo" 99 -1001234
if h_wait_for_capture sendMessage \
   '[.[] | select(.body.text|test("not valid"))] | length >= 1' 10; then
  h_ok "invalid /effort rejected"
else
  h_ng "invalid /effort not rejected"
fi
if [[ "$(cat "$CTA_STATE_DIR/effort/42" 2>/dev/null)" == "xhigh" ]]; then
  h_ok "effort/42 unchanged after invalid level"
else
  h_ng "effort/42 clobbered by invalid level"
fi

# "auto" sentinel → accepted + persisted (maps to omitting --effort at spawn,
# so claude falls back to its own settings.json effortLevel default).
h_inject_text 42 "/effort auto" 99 -1001234
if h_wait_for_capture sendMessage \
   '[.[] | select(.body.text|test("effort set to auto"))] | length >= 1' 10; then
  h_ok "/effort auto acknowledged"
else
  h_ng "/effort auto not acknowledged"; h_dump_captures
fi
if [[ "$(cat "$CTA_STATE_DIR/effort/42" 2>/dev/null)" == "auto" ]]; then
  h_ok "effort/42 persisted = auto"
else
  h_ng "effort/42 not persisted as auto (got '$(cat "$CTA_STATE_DIR/effort/42" 2>/dev/null)')"
fi

echo
echo "scenario effort_command: $H_PASS passed, $H_FAIL failed"
[[ "$H_FAIL" -eq 0 ]]
