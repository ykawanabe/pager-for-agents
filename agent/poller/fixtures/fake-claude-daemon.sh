#!/bin/bash
# Fake claude that mimics `claude -p --input-format stream-json
# --output-format stream-json --verbose` for ClaudeDaemon tests.
#
# Reads JSON user events from stdin, emits assistant + result events
# to stdout. Stays alive between turns (the whole point of daemon mode).
# Exits cleanly on stdin close.
#
# Behavior knobs via FAKE_CLAUDE_MODE env:
#   echo (default) - assistant text mirrors the user input
#   slow           - sleeps 1s before replying (test debounce timing)
#   multiblock     - emits 2 text blocks per turn (test streaming output)
#   crash-on-turn-2 - exits 1 after the second turn (test respawn)
set -u

emit_assistant_text() {
  local text="$1"
  # Use python3 to JSON-escape since bash quoting can't handle arbitrary text.
  python3 -c "
import json, sys
print(json.dumps({
    'type': 'assistant',
    'message': {
        'model': 'fake-claude',
        'content': [{'type': 'text', 'text': sys.argv[1]}]
    }
}))
" "$text"
}

emit_result() {
  local text="$1"
  python3 -c "
import json, sys
print(json.dumps({
    'type': 'result',
    'subtype': 'success',
    'is_error': False,
    'result': sys.argv[1],
    'total_cost_usd': 0.0042,
    'session_id': 'fake-session-uuid',
    'usage': {'input_tokens': 5, 'output_tokens': 10, 'cache_read_input_tokens': 0, 'cache_creation_input_tokens': 0}
}))
" "$text"
}

# Boot banner — real claude emits a system init event with session metadata.
echo '{"type":"system","subtype":"init","session_id":"fake-session-uuid","cwd":"'"$PWD"'"}'

TURN=0
MODE="${FAKE_CLAUDE_MODE:-echo}"

while IFS= read -r line; do
  TURN=$((TURN + 1))

  # Extract the user message text. Real format:
  #   {"type":"user","message":{"role":"user","content":"text"}}
  text=$(python3 -c "
import json, sys
try:
    d = json.loads(sys.argv[1])
    print(d.get('message', {}).get('content', ''))
except Exception as e:
    print('PARSE_ERROR: ' + str(e), file=sys.stderr)
" "$line" 2>/dev/null) || text="(unparseable input)"

  [[ "$MODE" == "slow" ]] && sleep 1

  if [[ "$MODE" == "multiblock" ]]; then
    emit_assistant_text "thinking…"
    emit_assistant_text "answer: $text"
    emit_result "answer: $text"
  else
    emit_assistant_text "You said: $text"
    emit_result "You said: $text"
  fi

  if [[ "$MODE" == "crash-on-turn-2" && "$TURN" -ge 2 ]]; then
    exit 1
  fi
done
