#!/bin/bash
# test_send_telegram_e2e.sh — does claude actually call the send_telegram MCP
# tool when given a Telegram-bot system prompt and a user message?
#
# This is the killer test that no unit test covers: claude has a `send_telegram`
# tool registered via --mcp-config, and a system prompt that says "you MUST
# call this tool to reach the user." Whether claude actually does it is a
# behavioral assertion of the model under our prompt + tool — we can't unit-
# test it.
#
# Mechanism:
#   1. Spin up tests/mock-bot-api.ts on a random port. It records every call
#      to a JSONL file (sendMessage, getMe, etc).
#   2. Build the same --mcp-config JSON that topic-wrapper.sh builds, but
#      pointed at the mock via TELEGRAM_API_BASE.
#   3. Run claude headlessly: `claude -p "<user message>" --mcp-config '...'
#      --append-system-prompt '<our prompt>' --strict-mcp-config`.
#   4. After claude exits, grep the mock's record file for a sendMessage call.
#   5. PASS if found and the message text is non-empty.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"

PASS=0
FAIL=0
ok() { echo "  ok   $1"; PASS=$((PASS + 1)); }
ng() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }

# ─── prerequisites ───────────────────────────────────────────────────────────

command -v claude >/dev/null || { echo "claude not on PATH — skipping" >&2; exit 0; }
command -v bun >/dev/null    || { echo "bun not on PATH — skipping"    >&2; exit 0; }

MCP_SERVER="$SCRIPT_DIR/agent/mcp-telegram/server.ts"
[[ -f "$MCP_SERVER" ]] || { echo "mcp-telegram server.ts not found at $MCP_SERVER" >&2; exit 1; }

# Match topic-wrapper.sh's default system prompt. Update this when the live
# prompt changes — drift means the test reflects a stale contract.
PROMPT='You are responding through a Telegram bot. The user is on Telegram; your terminal output is NOT visible to them. To deliver ANY reply, you MUST call the `send_telegram` MCP tool with your response text. A reply that only appears in the terminal never reaches the user.

Workflow for every user message:
  1. Read the message.
  2. Compose your reply.
  3. Call `send_telegram(text=...)` to deliver it.

Telegram renders replies as plain text. No markdown.'

# ─── mock server ─────────────────────────────────────────────────────────────

# Random port in the ephemeral range. macOS/Linux both honor :0 for auto-
# assignment but we want a predictable URL; pick a port and hope.
PORT=$(( ( RANDOM % 20000 ) + 30000 ))
RECORD=$(mktemp -t mock-bot-api.XXXXXX.jsonl)
trap 'cleanup' EXIT INT TERM

MOCK_LOG=$(mktemp -t mock-bot-api.log.XXXXXX)
MOCK_PID=""
cleanup() {
  if [[ -n "$MOCK_PID" ]] && kill -0 "$MOCK_PID" 2>/dev/null; then
    kill "$MOCK_PID" 2>/dev/null || true
    wait "$MOCK_PID" 2>/dev/null || true
  fi
  rm -f "$RECORD" "$MOCK_LOG"
}

bun run "$SCRIPT_DIR/tests/mock-bot-api.ts" "$PORT" "$RECORD" > "$MOCK_LOG" 2>&1 &
MOCK_PID=$!
# Poll until the mock is listening (up to ~3s). Bun.serve binds fast but we
# don't want the next curl to hit before bind completes.
for _ in $(seq 1 30); do
  if curl -fsS "http://localhost:${PORT}/botFAKE/getMe" >/dev/null 2>&1; then break; fi
  sleep 0.1
done
if ! curl -fsS "http://localhost:${PORT}/botFAKE/getMe" >/dev/null 2>&1; then
  echo "mock-bot-api failed to start on :${PORT} — log:" >&2
  cat "$MOCK_LOG" >&2
  exit 1
fi

# ─── mcp-config pointing at mock ─────────────────────────────────────────────

MCP_CFG=$(python3 - "$MCP_SERVER" "$PORT" <<'PY'
import json, sys
server_path, port = sys.argv[1:3]
cfg = {
    "mcpServers": {
        "telegram": {
            "command": "bun",
            "args": [server_path],
            "env": {
                "TELEGRAM_BOT_TOKEN": "FAKE",
                "TELEGRAM_CHAT_ID": "12345",
                "TELEGRAM_THREAD_ID": "dm",
                "TELEGRAM_API_BASE": f"http://localhost:{port}/botFAKE",
            },
        }
    }
}
print(json.dumps(cfg))
PY
)

# ─── run claude headless with one message ────────────────────────────────────

USER_MSG="${1:-hello, this is an E2E test — please reply with the word 'pong'}"
echo "→ Running claude -p with mocked Telegram API on :${PORT}"
echo "→ User message: $USER_MSG"

# `-p` = print mode (non-interactive). claude reads stdin OR takes message as
# positional. We pass via stdin to dodge shell-quoting weirdness.
# `--output-format json` so we can inspect claude's structured tool calls.
CLAUDE_LOG=$(mktemp -t claude-e2e.log.XXXXXX)
echo "$USER_MSG" | timeout 90 claude -p \
  --mcp-config "$MCP_CFG" \
  --strict-mcp-config \
  --dangerously-skip-permissions \
  --append-system-prompt "$PROMPT" \
  --output-format json \
  > "$CLAUDE_LOG" 2>&1
CLAUDE_EXIT=$?

echo "→ claude exited with code $CLAUDE_EXIT"
if [[ $CLAUDE_EXIT -ne 0 ]]; then
  echo "claude output (truncated):"
  head -40 "$CLAUDE_LOG"
fi

# ─── assertions ──────────────────────────────────────────────────────────────

# Mock should have logged at least one sendMessage call.
SEND_CALLS=$(grep '"method":"sendMessage"' "$RECORD" 2>/dev/null || true)
if [[ -n "$SEND_CALLS" ]]; then
  ok "claude called sendMessage at least once"
  echo "    captured calls:"
  echo "$SEND_CALLS" | head -3 | sed 's/^/      /'
else
  ng "claude called sendMessage (none recorded — claude responded in stdout instead of via tool)"
  echo "    mock record file contents:"
  cat "$RECORD" | sed 's/^/      /'
  echo "    claude stdout (last 30 lines):"
  tail -30 "$CLAUDE_LOG" | sed 's/^/      /'
fi

# Non-empty text payload (catches the case where claude calls the tool but
# passes an empty string).
if echo "$SEND_CALLS" | grep -Eq '"text":"[^"]+'; then
  ok "sendMessage payload has non-empty text"
else
  if [[ -n "$SEND_CALLS" ]]; then
    ng "sendMessage payload was empty"
  fi
fi

rm -f "$CLAUDE_LOG"

echo
echo "RESULT: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] || exit 1
