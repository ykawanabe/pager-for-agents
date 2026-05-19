#!/bin/bash
# Fake claude that mimics `claude -p --input-format stream-json
# --output-format stream-json --verbose` for ClaudeDaemon tests.
#
# Reads JSON user events from stdin, emits assistant + result events
# to stdout. Stays alive between turns (the whole point of daemon mode).
# Exits cleanly on stdin close.
#
# Behavior knobs via FAKE_CLAUDE_MODE env:
#   echo (default)       — assistant text mirrors the user input
#   slow                 — sleeps 1s before replying (test debounce timing)
#   multiblock           — emits 2 text blocks per turn (test streaming output)
#   crash-on-turn-2      — exits 1 after the second turn (test respawn)
#
# Pure-bash implementation: python3 cold-start (1-3s on a loaded mac) was
# the dominant cost; this fixture is hot-path during test runs, so we use
# only built-in JSON-friendly escaping for the controlled test inputs.
set -u

# Minimal JSON string escape: backslash, double-quote, newline, tab, carriage
# return. The test inputs are controlled (no unicode surprises, no embedded
# control chars), so the full RFC-8259 escape table isn't needed.
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\r'/\\r}"
  printf '%s' "$s"
}

emit_assistant_text() {
  local text esc
  text="$1"
  esc=$(json_escape "$text")
  printf '{"type":"assistant","message":{"model":"fake-claude","content":[{"type":"text","text":"%s"}]}}\n' "$esc"
}

emit_result() {
  local text esc
  text="$1"
  esc=$(json_escape "$text")
  printf '{"type":"result","subtype":"success","is_error":false,"result":"%s","total_cost_usd":0.0042,"session_id":"fake-session-uuid","usage":{"input_tokens":5,"output_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}\n' "$esc"
}

# Extract the `content` field from a `user`-event JSON line via sed. The
# real stream-json input is `{"type":"user","message":{"role":"user","content":"text"}}`.
# Tests use simple ASCII content with no embedded quotes/braces, so a regex
# extract is robust enough for the fixture. Fallback to literal line text
# if the regex doesn't match (lets us debug malformed inputs).
extract_content() {
  local line="$1"
  # Match "content":"..."  capturing the value. Greedy-stop at the next
  # double-quote that isn't preceded by a backslash.
  local content
  content=$(printf '%s' "$line" | sed -nE 's/.*"content":"((\\.|[^"\\])*)".*/\1/p')
  if [[ -z "$content" ]]; then
    printf '%s' "(unparseable: $line)"
  else
    printf '%s' "$content"
  fi
}

# Boot banner — real claude emits a system init event with session metadata.
printf '{"type":"system","subtype":"init","session_id":"fake-session-uuid","cwd":"%s"}\n' "$(json_escape "$PWD")"

TURN=0
MODE="${FAKE_CLAUDE_MODE:-echo}"

while IFS= read -r line; do
  TURN=$((TURN + 1))

  text=$(extract_content "$line")

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
