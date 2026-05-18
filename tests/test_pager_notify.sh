#!/bin/bash
# Tests for agent/hooks/pager-notify.sh — the Notification/Compaction hook
# that pushes status updates to Telegram.
#
# The user-visible problem (2026-05-18): "🔔 Claude is waiting for your
# input" arrived with NO context — no topic, no reason, no tool. This test
# pins the contract that notifications include:
#   1. The topic name (if known via topics.json), in [brackets]
#   2. The message (if Claude Code provided one)
#   3. The tool_name (if it's a permission-style notification)
#
# Strategy: PATH shim a fake `curl` that captures args to a file. Source
# the hook, feed a payload via stdin, assert the captured args.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$SCRIPT_DIR/agent/hooks/pager-notify.sh"

PASS=0
FAIL=0
ok() { echo "  ok  $1";   PASS=$((PASS + 1)); }
ng() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

# Plugin .env (provides TELEGRAM_BOT_TOKEN).
mkdir -p "$SANDBOX/home/.claude/channels/telegram"
echo 'TELEGRAM_BOT_TOKEN=test-token' > "$SANDBOX/home/.claude/channels/telegram/.env"

# topics.json with a known mapping. The hook uses CTA_STATE_DIR (with
# the canonical $HOME/.pager fallback).
mkdir -p "$SANDBOX/state"
cat > "$SANDBOX/state/topics.json" <<'EOF'
{
  "topics": {
    "-1001234/42": { "name": "Iron Flow" },
    "-1001234/77": { "name": "alpha-project" }
  }
}
EOF

# PATH shim — a fake `curl` captures the data-urlencode args into CURL_LOG
# so the test can introspect the message body.
SHIM_DIR="$SANDBOX/bin"
mkdir -p "$SHIM_DIR"
CURL_LOG="$SANDBOX/curl-args.log"
cat > "$SHIM_DIR/curl" <<EOF
#!/bin/bash
echo "\$@" >> "$CURL_LOG"
exit 0
EOF
chmod +x "$SHIM_DIR/curl"

run_hook() {
  local event="$1" payload="$2"
  local thread_id="${3:-42}"
  CURL_LOG_PARENT=$(dirname "$CURL_LOG")
  mkdir -p "$CURL_LOG_PARENT"
  : > "$CURL_LOG"

  HOME="$SANDBOX/home" \
  CTA_STATE_DIR="$SANDBOX/state" \
  TELEGRAM_CHAT_ID="-1001234" \
  TELEGRAM_THREAD_ID="$thread_id" \
  PATH="$SHIM_DIR:$PATH" \
    printf '%s' "$payload" | env \
    HOME="$SANDBOX/home" \
    CTA_STATE_DIR="$SANDBOX/state" \
    TELEGRAM_CHAT_ID="-1001234" \
    TELEGRAM_THREAD_ID="$thread_id" \
    PATH="$SHIM_DIR:$PATH" \
    "$HOOK" "$event"
}

# ─── Test: notification includes topic name from topics.json ─────────────

run_hook notification '{"message": "Need permission to run rm"}' 42
if grep -q 'Iron Flow' "$CURL_LOG"; then
  ok "notification includes topic name from topics.json"
else
  ng "topic name missing from notification (curl args: $(cat "$CURL_LOG" | head -c 200))"
fi

if grep -q 'Need permission to run rm' "$CURL_LOG"; then
  ok "notification includes the payload's message field"
else
  ng "message field missing from notification"
fi

# ─── Test: empty message falls back to a sensible default ─────────────────

run_hook notification '{}' 42
if grep -qE 'waiting|input' "$CURL_LOG"; then
  ok "empty message falls back to 'waiting/input' text"
else
  ng "fallback message missing for empty payload"
fi

# ─── Test: unknown topic (not in topics.json) still ships ─────────────────

run_hook notification '{"message": "Quick question"}' 999
if grep -q 'Quick question' "$CURL_LOG"; then
  ok "unknown topic: message still delivered"
else
  ng "unknown topic: message dropped"
fi

# ─── Test: tool_name (permission events) included if present ─────────────

run_hook notification '{"message": "Permission needed", "tool_name": "Bash"}' 42
if grep -q 'Bash' "$CURL_LOG"; then
  ok "tool_name surfaced when payload has one (permission context)"
else
  ng "tool_name not surfaced in notification (Bash tool permission case)"
fi

# ─── Test: precompact / postcompact still work ─────────────────────────────

run_hook precompact '{}' 42
if grep -q 'Compacting' "$CURL_LOG"; then
  ok "precompact event still emits 'Compacting' text"
else
  ng "precompact regression"
fi

run_hook postcompact '{}' 42
if grep -qE 'Compaction done|continuing' "$CURL_LOG"; then
  ok "postcompact event still emits 'done' text"
else
  ng "postcompact regression"
fi

echo
if [[ "$FAIL" -eq 0 ]]; then
  echo "✅ test_pager_notify.sh: $PASS passed"
  exit 0
else
  echo "❌ test_pager_notify.sh: $PASS passed, $FAIL failed"
  exit 1
fi
