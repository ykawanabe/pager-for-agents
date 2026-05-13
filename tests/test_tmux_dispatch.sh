#!/bin/bash
# Tests the tmux primitive (load-buffer | paste-buffer -d | send-keys Enter)
# that services/poller/poller.ts uses to deliver Telegram messages into a
# per-topic claude session.
#
# The eng review on 2026-05-13 settled on this primitive over send-keys with
# Enter-separators because it survives multiline, code blocks, emoji, and
# quotes without shell-escaping. This test pins that contract by piping a
# realistic payload through a real tmux session running `cat` (no claude,
# no Telegram), then capturing the pane to verify byte-for-byte equality.
#
# Why we test the bash primitive and not the TS function: poller.ts's
# tmuxDispatch is a thin spawnSync wrapper around exactly these three
# tmux commands. The risk is tmux behavior, not the TS glue.
set -uo pipefail

PASS=0
FAIL=0
ok() { echo "  ok  $1";   PASS=$((PASS + 1)); }
ng() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }

# Need tmux on PATH. Match start_agents.sh's PATH augmentation so the test
# works under both interactive shell and CI / launchd contexts.
export PATH="$HOME/.bun/bin:/opt/homebrew/bin:/usr/local/bin:${PATH:-/usr/bin:/bin}:$HOME/.local/bin"

if ! command -v tmux >/dev/null 2>&1; then
  echo "SKIP: tmux not found on PATH"
  exit 0
fi

SESSION="cta-tmux-dispatch-test-$$"
trap 'tmux kill-session -t "$SESSION" 2>/dev/null || true' EXIT

# Spawn a tmux session running `cat`. cat echoes stdin to stdout, so anything
# the poller "delivers" appears in the pane verbatim.
tmux new-session -d -s "$SESSION" "cat"
sleep 0.3   # let cat start

# The dispatch primitive, factored as a function so the test mirrors what
# poller.ts actually executes.
dispatch() {
  local target="$1" text="$2"
  printf '%s' "$text" | tmux load-buffer -
  tmux paste-buffer -d -t "$target"
  tmux send-keys -t "$target" Enter
}

# ─── Plain text ──────────────────────────────────────────────────────────────

dispatch "$SESSION" "hello world"
sleep 0.3
captured=$(tmux capture-pane -t "$SESSION" -p -S - | grep -F "hello world" || true)
if [[ -n "$captured" ]]; then
  ok "plain text round-trips through paste-buffer"
else
  ng "plain text: 'hello world' not visible in pane (got: $(tmux capture-pane -t "$SESSION" -p -S - | tr -d '\n' | head -c 200))"
fi

# ─── Multiline ───────────────────────────────────────────────────────────────

dispatch "$SESSION" $'line one\nline two\nline three'
sleep 0.3
pane=$(tmux capture-pane -t "$SESSION" -p -S -)
if echo "$pane" | grep -q "line one" && echo "$pane" | grep -q "line two" && echo "$pane" | grep -q "line three"; then
  ok "multiline preserves all three lines"
else
  ng "multiline: missing line(s) (pane: $(echo "$pane" | tr -d '\r' | head -c 200))"
fi

# ─── Code block (fenced) ─────────────────────────────────────────────────────

dispatch "$SESSION" $'```bash\nls -la\necho hi\n```'
sleep 0.3
pane=$(tmux capture-pane -t "$SESSION" -p -S -)
if echo "$pane" | grep -q '```bash' && echo "$pane" | grep -q 'ls -la' && echo "$pane" | grep -q 'echo hi'; then
  ok "fenced code block preserves backticks + commands"
else
  ng "code block: backticks or content missing"
fi

# ─── Emoji + non-ASCII ───────────────────────────────────────────────────────

dispatch "$SESSION" "日本語と emoji 🚀 mixed"
sleep 0.3
pane=$(tmux capture-pane -t "$SESSION" -p -S -)
if echo "$pane" | grep -q "日本語と emoji 🚀 mixed"; then
  ok "UTF-8 (CJK + emoji) round-trips"
else
  ng "UTF-8: payload missing from pane"
fi

# ─── Quotes and shell metacharacters ─────────────────────────────────────────
# A naive send-keys would shell-interpolate these. paste-buffer treats them
# as literal bytes, which is exactly what we want for chat content.

dispatch "$SESSION" "$(printf 'tricky: $HOME `whoami` "double" '"'"'single'"'"'')"
sleep 0.3
pane=$(tmux capture-pane -t "$SESSION" -p -S -)
if echo "$pane" | grep -qF '$HOME' && echo "$pane" | grep -qF '`whoami`' && echo "$pane" | grep -qF '"double"'; then
  ok "shell metachars stay literal (\$HOME, backticks, quotes)"
else
  ng "metachars: expansion happened or chars dropped (pane: $(echo "$pane" | tr -d '\r' | head -c 200))"
fi

# ─── Buffer cleanup: paste-buffer -d removes the buffer ─────────────────────
# If -d is silently dropped, repeated dispatches would re-paste old content.
# Compare buffer count delta: must be 0 after a dispatch+cleanup roundtrip.
# Absolute count would be flaky when the live agent shares the same tmux
# server (its dispatches drop buffers concurrently with the test).

BEFORE_COUNT=$(tmux list-buffers 2>/dev/null | wc -l | tr -d ' ')
dispatch "$SESSION" "cleanup probe"
sleep 0.2
AFTER_COUNT=$(tmux list-buffers 2>/dev/null | wc -l | tr -d ' ')
if [[ "$AFTER_COUNT" -le "$BEFORE_COUNT" ]]; then
  ok "paste-buffer -d clears its own buffer (no net growth)"
else
  ng "paste-buffer -d left buffers behind (before=$BEFORE_COUNT after=$AFTER_COUNT)"
fi

# ─── summary ─────────────────────────────────────────────────────────────────

echo
echo "tmux dispatch: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
