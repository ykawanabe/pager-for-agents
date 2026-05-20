#!/bin/bash
# E2E scenario: /model sets per-topic model (mirrors /effort).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/harness.sh
source "$SCRIPT_DIR/../lib/harness.sh"

echo "▶ scenario: model_command"
h_setup_sandbox "model-command"
h_spawn_mock
h_seed_paired -1001234 99
h_seed_mount 42 "$SCENARIO_DIR" "iron-flow"
cat >> "$CTA_STATE_DIR/.env" <<EOT
PAGER_CLAUDE_BIN=$REPO_DIR/agent/poller/fixtures/fake-claude-daemon.sh
PAGER_DAEMON_DEBOUNCE_MS=300
EOT
h_spawn_poller

h_inject_text 42 "/model opus" 99 -1001234
if h_wait_for_capture sendMessage '[.[] | select(.body.text|test("model set to opus"))] | length >= 1' 10; then
  h_ok "/model opus acknowledged"
else
  h_ng "/model opus not acknowledged"; h_dump_captures
fi
if [[ "$(cat "$CTA_STATE_DIR/model/42" 2>/dev/null)" == "opus" ]]; then
  h_ok "model/42 persisted = opus"
else
  h_ng "model/42 not persisted (got '$(cat "$CTA_STATE_DIR/model/42" 2>/dev/null)')"
fi

h_inject_text 42 "/model @@@" 99 -1001234
if h_wait_for_capture sendMessage '[.[] | select(.body.text|test("look like a model name"))] | length >= 1' 10; then
  h_ok "invalid /model rejected"
else
  h_ng "invalid /model not rejected"
fi
if [[ "$(cat "$CTA_STATE_DIR/model/42" 2>/dev/null)" == "opus" ]]; then
  h_ok "model/42 unchanged after invalid name"
else
  h_ng "model/42 clobbered"
fi

echo
echo "scenario model_command: $H_PASS passed, $H_FAIL failed"
[[ "$H_FAIL" -eq 0 ]]
