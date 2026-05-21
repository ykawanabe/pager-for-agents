#!/bin/bash
# E2E scenario: the 2-stage reaction ack (👀 delivered → 👌 read) end-to-end
# through the REAL poller + (fake) daemon. This pipeline was previously
# UNCOVERED by e2e — it gates the P3 ack cutover (transport.setDeliveredAck /
# setReadAcks) at the behavior level, so the same assertions hold before and
# after the cutover.
#
# Flow:
#   1. access.json sets ackReaction="👀" (operator glyph; without it ack is off).
#   2. Inject a normal text message to a mounted thread from the paired user.
#   3. Poller dispatch fires the delivered ack → setMessageReaction 👀.
#   4. Registry debounce closes → flush hook drains pendingReadAcks → 👌.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/harness.sh
source "$SCRIPT_DIR/../lib/harness.sh"

echo "▶ scenario: ack_reaction"
h_setup_sandbox "ack-reaction"
h_spawn_mock

h_seed_paired -1001234 99
h_seed_mount 42 "$SCENARIO_DIR" "iron-flow"

# Operator glyph: the poller reads ACCESS_JSON (mtime-watched). Set it BEFORE
# boot so ackReactionCache is populated on the first refresh.
ACCESS_JSON_FILE="$SCENARIO_DIR/access.json"
echo '{"ackReaction":"👀"}' > "$ACCESS_JSON_FILE"

# Fake daemon + fast debounce, wired before the poller boots (h_spawn_poller
# sources this .env). ACCESS_JSON points the poller at our glyph file.
cat >> "$CTA_STATE_DIR/.env" <<EOF
PAGER_CLAUDE_BIN=$REPO_DIR/agent/poller/fixtures/fake-claude-daemon.sh
PAGER_DAEMON_DEBOUNCE_MS=300
ACCESS_JSON=$ACCESS_JSON_FILE
EOF

h_spawn_poller

# A normal text message (not a command) to the mounted thread → routes to the
# daemon → ack pipeline fires.
h_inject_text 42 "hello from ack test" 99 -1001234

# Stage 1: delivered ack 👀 on the user's message.
if h_wait_for_capture setMessageReaction \
   '[.[] | select(.body.reaction[0].emoji=="👀")] | length >= 1' 8; then
  h_ok "delivered ack 👀 fired on dispatch"
else
  h_ng "delivered ack 👀 did NOT fire within 8s"
  h_dump_captures
fi

# Stage 2: read ack 👌 after the debounce flush (N:1 fan-in drains the queue).
if h_wait_for_capture setMessageReaction \
   '[.[] | select(.body.reaction[0].emoji=="👌")] | length >= 1' 8; then
  h_ok "read ack 👌 fired on daemon flush"
else
  h_ng "read ack 👌 did NOT fire within 8s"
  h_dump_captures
fi

# The 👌 must REPLACE 👀 (Telegram = 1 reaction/bot/message → swap, not stack):
# both are the same chat+message_id, applied as single-element arrays.
if h_wait_for_capture setMessageReaction \
   '[.[] | select(.body.message_id==1 and (.body.reaction|length==1))] | length >= 2' 5; then
  h_ok "both acks are single-reaction swaps on the same message"
else
  h_ng "ack reactions were not single-element swaps on message_id 1"
  h_dump_captures
fi

echo "── ack_reaction: $H_PASS passed, $H_FAIL failed ──"
[[ "$H_FAIL" -eq 0 ]]
