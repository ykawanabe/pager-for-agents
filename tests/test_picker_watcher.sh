#!/bin/bash
# Tests for agent/picker-watcher.ts — the alt-screen detector that surfaces
# claude's interactive pickers to Telegram (because the bot can't deliver
# arrow-key pickers natively).
#
# Strategy: PATH-shim a fake `tmux` and a fake `curl` (via TELEGRAM_API_BASE
# pointing at a captured-request endpoint). The fake tmux returns whatever
# we put in a state file, so the test can flip alt-screen on/off without
# spawning real claude. The fake API base writes the request body to a
# captures dir. Run picker-watcher for a fixed number of ticks and assert
# the captures.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WATCHER="$SCRIPT_DIR/agent/picker-watcher.ts"

PASS=0
FAIL=0
ok() { echo "  ok  $1";   PASS=$((PASS + 1)); }
ng() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }

command -v bun >/dev/null || { echo "bun not installed; skipping"; exit 0; }

[[ -f "$WATCHER" ]] || { ng "watcher missing: $WATCHER"; exit 1; }

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

# ─── 1. detectTransition pure function ──────────────────────────────────────
#
# Import the module from bun and call detectTransition directly. Cheap unit
# test of the state-machine logic without any subprocess plumbing.

cat > "$SANDBOX/transition.test.ts" <<EOF
import { detectTransition } from "$WATCHER";

function expect(actual: string, expected: string, label: string) {
  if (actual === expected) console.log(\`OK \${label}\`);
  else { console.error(\`FAIL \${label}: got '\${actual}' want '\${expected}'\`); process.exit(1); }
}

expect(detectTransition(false, true), "enter", "false→true is enter");
expect(detectTransition(true, false), "exit",  "true→false is exit");
expect(detectTransition(false, false), "none", "false→false is none");
expect(detectTransition(true, true), "none",   "true→true is none");
EOF

if bun "$SANDBOX/transition.test.ts" >/dev/null 2>&1; then
  ok "detectTransition transitions correct (4 cases)"
else
  ng "detectTransition unit cases — see bun output"
  bun "$SANDBOX/transition.test.ts" || true
fi

# ─── 2. End-to-end with mocked tmux + mocked Telegram API ───────────────────

# Fake tmux: reads alt-screen state from a file the test controls. Two
# subcommands the watcher uses:
#   display-message -p -t SESSION '#{alternate_on}'    → echoes state file content
#   capture-pane -p -t SESSION                          → echoes a fake snapshot
mkdir -p "$SANDBOX/bin"
cat > "$SANDBOX/bin/tmux" <<'EOF'
#!/bin/bash
# Subcommand router for the fake tmux.
case "$1" in
  display-message)
    cat "$STATE_FILE" 2>/dev/null || echo 0
    ;;
  capture-pane)
    echo "fake picker snapshot line 1"
    echo "  > auto"
    echo "    low"
    ;;
  *)
    echo "fake-tmux: unknown subcommand: $1" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$SANDBOX/bin/tmux"

# Fake Telegram API — a one-shot listener via netcat-like setup is too
# heavy. Instead, run a small bun HTTP server in background that appends
# every received body to a captures file.
CAPTURES="$SANDBOX/telegram.captures"
: > "$CAPTURES"

# Pick an unused port.
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("", 0)); print(s.getsockname()[1]); s.close()')

cat > "$SANDBOX/server.ts" <<EOF
const captures = "$CAPTURES";
Bun.serve({
  port: $PORT,
  async fetch(req) {
    const body = await req.text();
    await Bun.write(captures, await Bun.file(captures).text() + body + "\n---\n");
    return new Response(JSON.stringify({ ok: true, result: { message_id: 1 } }), {
      headers: { "Content-Type": "application/json" },
    });
  },
});
EOF
bun "$SANDBOX/server.ts" >/dev/null 2>&1 &
SERVER_PID=$!
# Give the server a moment to bind.
for _ in 1 2 3 4 5; do
  if curl -s "http://127.0.0.1:$PORT/" -o /dev/null --max-time 0.2; then break; fi
  sleep 0.1
done

cleanup() {
  kill $SERVER_PID 2>/dev/null || true
  rm -rf "$SANDBOX"
}
trap cleanup EXIT

# Start watcher with state file at 0 (not in picker).
#
# Clear the captures file first — the readiness-probe curl above lands in
# the captures too (the fake server logs every request regardless of path)
# and would pollute the "off → no notice" assertion below.
: > "$CAPTURES"
STATE="$SANDBOX/alt_state"
echo 0 > "$STATE"

# Run the watcher in background. Use small interval so the test isn't slow.
# PATH-shim tmux via PICKER_WATCHER_TMUX (preferred — direct path, no PATH
# games — the watcher honors it).
PICKER_WATCHER_TMUX="$SANDBOX/bin/tmux" \
STATE_FILE="$STATE" \
TELEGRAM_BOT_TOKEN="test-token" \
TELEGRAM_API_BASE="http://127.0.0.1:$PORT/bot-fake" \
  bun "$WATCHER" \
    --session topic-test \
    --chat-id 999 \
    --thread-id 42 \
    --interval-ms 100 \
  >/dev/null 2>&1 &
WATCHER_PID=$!

# Two ticks of "not in picker" — nothing should be sent.
sleep 0.3
LINES_BEFORE=$(wc -l < "$CAPTURES" | tr -d ' ')

# Flip to alt-screen and let two ticks pass.
echo 1 > "$STATE"
sleep 0.5
LINES_AFTER_ENTER=$(wc -l < "$CAPTURES" | tr -d ' ')

# Flip back and let one tick pass.
echo 0 > "$STATE"
sleep 0.3
LINES_AFTER_EXIT=$(wc -l < "$CAPTURES" | tr -d ' ')

kill $WATCHER_PID 2>/dev/null || true
wait $WATCHER_PID 2>/dev/null || true

if [[ "$LINES_BEFORE" -eq 0 ]]; then
  ok "no notice while alt-screen off"
else
  ng "unexpected $LINES_BEFORE notice lines when off"
fi

# enter notice should have come in: at least one body + separator.
if grep -q "claude opened a picker" "$CAPTURES" 2>/dev/null; then
  ok "enter notice sent on alt-screen entry"
else
  ng "enter notice missing — captures:"
  cat "$CAPTURES" || true
fi

if grep -q "fake picker snapshot" "$CAPTURES" 2>/dev/null; then
  ok "enter notice includes pane snapshot"
else
  ng "snapshot missing from enter notice"
fi

if grep -q "Picker closed" "$CAPTURES" 2>/dev/null; then
  ok "closed notice sent on alt-screen exit"
else
  ng "closed notice missing"
fi

# message_thread_id should be passed through
if grep -q '"message_thread_id":42' "$CAPTURES" 2>/dev/null; then
  ok "message_thread_id forwarded into Bot API call"
else
  ng "message_thread_id missing — captures: $(head -c 500 "$CAPTURES")"
fi

echo
if [[ "$FAIL" -eq 0 ]]; then
  echo "✅ test_picker_watcher.sh: $PASS passed"
  exit 0
else
  echo "❌ test_picker_watcher.sh: $PASS passed, $FAIL failed"
  exit 1
fi
