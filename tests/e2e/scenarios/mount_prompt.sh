#!/bin/bash
# E2E scenario: P6a — unmounted topic gets a buttons prompt (no tmux helper),
# tapping a candidate links the topic.
#
#   1. Message to an unmounted topic (no wildcard) → poller sends an inline
#      keyboard with `mnt:<thread>:<idx>` buttons (candidate = CLAUDE_CWD).
#   2. Inject the callback (button tap) → poller addMounts the dir + replies
#      "Linked…", and mounts.json gains the entry.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/harness.sh
source "$SCRIPT_DIR/../lib/harness.sh"

echo "▶ scenario: mount_prompt"
h_setup_sandbox "mount-prompt"
# CLAUDE_CWD is the one mount candidate (no existing mounts in this sandbox).
echo "CLAUDE_CWD=$SCENARIO_DIR" >> "$CTA_STATE_DIR/.env"
h_spawn_mock
h_seed_paired -1001234 99
# Deliberately NO mount and NO wildcard.
h_spawn_poller

# 1. Unmounted topic message → buttons prompt with mnt:42:0.
h_inject_text 42 "hello there" 99 -1001234
if h_wait_for_capture sendMessage \
   '[.[] | select(.body.reply_markup.inline_keyboard[0][0].callback_data == "mnt:42:0")] | length >= 1' 10; then
  h_ok "unmounted topic → mount-choice buttons (no tmux helper)"
else
  h_ng "no mnt: buttons prompt"; h_dump_captures
fi

# 2. Tap the button → callback_query update.
PAYLOAD=$(jq -nc '{
  callback_query: {
    id: "cb-1",
    from: {id: 99, is_bot: false, first_name: "Tester"},
    message: {message_id: 1, chat: {id: -1001234, type: "supergroup"}, message_thread_id: 42, text: "This topic isn'"'"'t linked to a project yet. Pick one, or send /mount <path>:"},
    data: "mnt:42:0"
  }
}')
curl -fsS -X POST -H 'content-type: application/json' -d "$PAYLOAD" \
  "http://localhost:${MOCK_PORT}/__test__/inject" >/dev/null

if h_wait_for_capture sendMessage \
   '[.[] | select(.body.text|test("Linked this topic to"))] | length >= 1' 10; then
  h_ok "button tap → topic linked + confirmation"
else
  h_ng "no 'Linked' confirmation after tap"; h_dump_captures
fi

# 3. mounts.json now has thread 42 → CLAUDE_CWD.
got=$(bun run "$CTA_INSTALL_DIR/agent/mount-store/mount-store.ts" get 42 2>/dev/null | jq -r '.path // empty')
if [[ "$got" == "$SCENARIO_DIR" ]]; then
  h_ok "mounts.json: thread 42 → $SCENARIO_DIR"
else
  h_ng "mount not written (got '$got')"
fi

echo
echo "scenario mount_prompt: $H_PASS passed, $H_FAIL failed"
[[ "$H_FAIL" -eq 0 ]]
