#!/bin/bash
# Tests for `cta watch <thread>` (watch-live plan, Phase A.1).
#
# Captures a topic's tmux pane content via tmux capture-pane and prints
# to stdout. Exit codes: 0=ok, 1=no mount, 2=tmux session dead.
#
# Strategy: isolated tmux server on a private socket; mount a thread;
# spawn a real tmux session under the same socket emitting known text;
# assert cta watch reads it back.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CTA="$SCRIPT_DIR/cli/cta"

PASS=0
FAIL=0
ok() { echo "  ok  $1";   PASS=$((PASS + 1)); }
ng() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }

STATE=$(mktemp -d)
TMP_PROJECT=$(mktemp -d)
export CTA_STATE_DIR="$STATE"
export CTA_AGENT_DIR="$SCRIPT_DIR/agent"

# Isolation: route every tmux call (cta-internal AND test-side) to a
# private socket dir under $STATE via TMUX_TMPDIR. Both sides use the
# tmux "default" socket — no `-L name` — because cta's header
# overwrites $PATH (defeating any PATH shim), and unifying on the
# default socket means cta's plain `tmux ...` calls find the same
# session our test-side `tmux new-session` created.
mkdir -p "$STATE/tmux-$(id -u)"
# tmux refuses to run if its socket dir has group/world perms.
chmod 700 "$STATE/tmux-$(id -u)"

cta() {
  TMUX_TMPDIR="$STATE" \
    env -u TMUX -u TMUX_PANE "$CTA" "$@"
}

tmux_test() {
  TMUX_TMPDIR="$STATE" \
    env -u TMUX -u TMUX_PANE "$(command -v tmux)" "$@"
}

cleanup() {
  tmux_test kill-server 2>/dev/null || true
  rm -rf "$STATE" "$TMP_PROJECT"
}
trap cleanup EXIT

# ─── Exit 1: no mount for thread ───────────────────────────────────────────

set +e
OUT=$(cta watch 99999 2>&1)
RC=$?
set -e
if [[ "$RC" -eq 1 ]] && echo "$OUT" | grep -qi "no mount\|not mounted"; then
  ok "cta watch (no mount): exit 1 with friendly message"
else
  ng "cta watch (no mount): exit 1 (rc=$RC, out='$OUT')"
fi

# ─── Setup: mount thread 42, no tmux session yet ───────────────────────────

cta mount 42 "$TMP_PROJECT" iron-flow >/dev/null 2>&1

# ─── Exit 2: tmux session dead (mount exists, no tmux) ─────────────────────

set +e
OUT=$(cta watch 42 2>&1)
RC=$?
set -e
if [[ "$RC" -eq 2 ]] && echo "$OUT" | grep -qi "tmux\|not alive\|dead"; then
  ok "cta watch (dead tmux): exit 2 with friendly message"
else
  ng "cta watch (dead tmux): exit 2 (rc=$RC, out='$OUT')"
fi

# ─── Spawn a real tmux session with known text + a color escape ────────────
# bash -c keeps the pane alive after the initial output. printf with
# an ANSI red escape lets us test --ansi preservation later.

tmux_test new-session -d -s topic-42 \
  'bash -c "printf \"\\033[31mWATCH_TEST_HEADER\\033[0m\\nSECOND_LINE\\n\"; sleep 300"'
sleep 0.3  # let bash + tmux render

# ─── Exit 0: happy path, returns pane content ──────────────────────────────

OUT=$(cta watch 42 2>&1)
RC=$?
if [[ "$RC" -eq 0 ]] && echo "$OUT" | grep -q "WATCH_TEST_HEADER"; then
  ok "cta watch: rc=0 + captures pane header line"
else
  ng "cta watch: rc=0 + captures header (rc=$RC, out='$OUT')"
fi

if echo "$OUT" | grep -q "SECOND_LINE"; then
  ok "cta watch: captures multi-line content"
else
  ng "cta watch: captures multi-line content (out='$OUT')"
fi

# Default mode strips ANSI escapes (raw \033 byte should NOT appear).
if ! printf '%s' "$OUT" | grep -q $'\x1b\['; then
  ok "cta watch (default): strips ANSI escape codes"
else
  ng "cta watch (default): strips ANSI escape codes"
fi

# ─── --ansi: preserves escape codes ────────────────────────────────────────

OUT=$(cta watch 42 --ansi 2>&1)
RC=$?
if [[ "$RC" -eq 0 ]] && printf '%s' "$OUT" | grep -q $'\x1b\['; then
  ok "cta watch --ansi: preserves ANSI escape codes"
else
  ng "cta watch --ansi: preserves ANSI escape codes (rc=$RC)"
fi

# ─── --lines N: accepted without crash, returns content ────────────────────

OUT=$(cta watch 42 --lines 50 2>&1)
RC=$?
if [[ "$RC" -eq 0 ]] && echo "$OUT" | grep -q "WATCH_TEST_HEADER"; then
  ok "cta watch --lines N: accepted, returns content"
else
  ng "cta watch --lines N: accepted (rc=$RC, out='$OUT')"
fi

# Bad --lines value → reject (don't silently pass through to tmux).
set +e
OUT=$(cta watch 42 --lines abc 2>&1)
RC=$?
set -e
if [[ "$RC" -ne 0 ]]; then
  ok "cta watch --lines abc: rejects non-numeric value"
else
  ng "cta watch --lines abc: rejects non-numeric (rc=$RC, out='$OUT')"
fi

# ─── DM key support ────────────────────────────────────────────────────────

cta mount dm "$TMP_PROJECT" general >/dev/null 2>&1
tmux_test new-session -d -s topic-dm \
  'bash -c "printf \"DM_TEST_LINE\\n\"; sleep 300"'
sleep 0.3

OUT=$(cta watch dm 2>&1)
RC=$?
if [[ "$RC" -eq 0 ]] && echo "$OUT" | grep -q "DM_TEST_LINE"; then
  ok "cta watch dm: works for DM key"
else
  ng "cta watch dm: works for DM key (rc=$RC, out='$OUT')"
fi

# ─── Missing thread arg ────────────────────────────────────────────────────

set +e
OUT=$(cta watch 2>&1)
RC=$?
set -e
if [[ "$RC" -ne 0 ]] && echo "$OUT" | grep -qi "usage\|thread"; then
  ok "cta watch (no arg): usage message + non-zero exit"
else
  ng "cta watch (no arg): usage message (rc=$RC, out='$OUT')"
fi

# ─── --follow with no per-topic log file → exit 2 + hint ───────────────────

# topic 42 mount exists, tmux is alive, but the per-topic log file
# under $STATE/topics/42.log was never created (B.1 hasn't run yet).
set +e
OUT=$(cta watch 42 --follow 2>&1)
RC=$?
set -e
if [[ "$RC" -eq 2 ]] && echo "$OUT" | grep -qi "log not yet available\|cta start"; then
  ok "cta watch --follow (no log): exit 2 + actionable hint"
else
  ng "cta watch --follow (no log): rc=$RC out='$OUT'"
fi

# ─── --follow with log file present → streams from file ────────────────────
# Pre-populate $STATE/topics/42.log with known content. tail -F doesn't
# exit on its own (waits for more file writes), so we run cta watch in
# the background, give it 500ms to flush the initial lines, then kill it.
mkdir -p "$STATE/topics"
echo "TAIL_FOLLOW_TEST_LINE_AAA" > "$STATE/topics/42.log"

OUT_FILE=$(mktemp)
cta watch 42 --follow --lines 100 > "$OUT_FILE" 2>&1 &
WATCH_PID=$!
# tail -F's startup is bounded by file open + initial seek + first read;
# under load (parallel test runs) 500ms wasn't enough — bumped to 2s to
# stay reliable on a busy CI machine without adding meaningful wall-time
# to the green path.
sleep 2
kill -TERM "$WATCH_PID" 2>/dev/null || true
wait "$WATCH_PID" 2>/dev/null || true

if grep -q "TAIL_FOLLOW_TEST_LINE_AAA" "$OUT_FILE"; then
  ok "cta watch --follow: streams from per-topic log file"
else
  ng "cta watch --follow: expected tail output, got '$(cat "$OUT_FILE")'"
fi
rm -f "$OUT_FILE"

echo
if [[ "$FAIL" -eq 0 ]]; then
  echo "✅ test_cta_watch.sh: $PASS passed"
  exit 0
else
  echo "❌ test_cta_watch.sh: $PASS passed, $FAIL failed"
  exit 1
fi
