#!/bin/bash
# Regression guard for topic-wrapper.sh setup_pane_log — pins the tmux
# pipe-pane invocation that backs `cta watch --follow` and Pager's
# WatchLive streaming.
#
# Why this exists: on 2026-05-18 we shipped Phase B.1 of pager-watch-live
# with `tmux pipe-pane -O -o "cmd"` flags. The `-O -o` combination is a
# silent no-op on macOS tmux 3.5 — the log file stays 0 bytes and `tail
# -F` blocks forever waiting for content. Users saw a stuck "Starting…"
# screen with no signal that anything was wrong.
#
# This test inlines the EXACT commands setup_pane_log runs (no sourcing
# the wrapper, which spawns claude and requires env setup) and verifies
# them on a real tmux session. If anyone re-adds `-O -o` or the seed
# step gets dropped, this test catches it.
#
# IMPORTANT: the inlined commands MUST stay in sync with
# agent/topic-wrapper.sh setup_pane_log. If you change one, change both
# AND verify this test still passes.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WRAPPER="$SCRIPT_DIR/agent/topic-wrapper.sh"

PASS=0
FAIL=0
ok() { echo "  ok  $1";   PASS=$((PASS + 1)); }
ng() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }

[[ -f "$WRAPPER" ]] || { ng "topic-wrapper.sh missing"; exit 1; }

STATE=$(mktemp -d)

# Private tmux server so the test never touches the user's real server.
mkdir -p "$STATE/tmux-$(id -u)"
chmod 700 "$STATE/tmux-$(id -u)"
TMUX_TMPDIR="$STATE"
export TMUX_TMPDIR

cleanup() {
  tmux kill-server 2>/dev/null || true
  rm -rf "$STATE"
}
trap cleanup EXIT

# ─── Mirror of agent/topic-wrapper.sh setup_pane_log ────────────────────────
# If this drifts from the production function, the test fails to lock
# what production actually does.
test_setup_pane_log() {
  local session="$1" thread_id="$2" state_dir="$3"
  local log_dir="$state_dir/topics"
  local log_file="$log_dir/$thread_id.log"
  mkdir -p "$log_dir" || return 0
  tmux capture-pane -p -S - -e -t "$session" > "$log_file" 2>/dev/null || : > "$log_file"
  tmux pipe-pane -t "$session" 2>/dev/null || true
  tmux pipe-pane -t "$session" "cat >> '$log_file'" 2>/dev/null || true
}

# Source-level sanity: production setup_pane_log must use the EXACT
# command form we inlined. Catches drift from someone "improving" the
# flags in agent/topic-wrapper.sh without re-running this test.
EXPECTED='tmux pipe-pane -t "$session" "cat >> '"'"'$log_file'"'"'"'
if grep -F -- "$EXPECTED" "$WRAPPER" >/dev/null; then
  ok "agent/topic-wrapper.sh uses the flag-free pipe-pane form"
else
  ng "agent/topic-wrapper.sh setup_pane_log flag form drifted"
  echo "    Expected line containing: $EXPECTED"
  echo "    Actual setup_pane_log:"
  awk '/^setup_pane_log\(\)/,/^}/' "$WRAPPER" | sed 's/^/      /'
fi

# Also forbid `-O -o` from re-appearing — that's the known-broken form.
if grep -E 'pipe-pane[^"]*-O[[:space:]]+-o' "$WRAPPER" >/dev/null; then
  ng "agent/topic-wrapper.sh contains the broken -O -o flag combination"
else
  ok "agent/topic-wrapper.sh has no broken -O -o pipe-pane flags"
fi

# ─── Behavior: spawn a real tmux, set up pipe-pane, trigger output ──────────

SESSION="test-pipe-pane-$$"
tmux new-session -d -s "$SESSION" cat
test_setup_pane_log "$SESSION" "999" "$STATE"

LOG="$STATE/topics/999.log"
[[ -f "$LOG" ]] || { ng "log file not created"; exit 1; }

# Send a known string via send-keys + Enter — `cat` echoes it back to the
# pane, which pipe-pane should mirror into the log.
MARKER="WATCH_PIPE_TEST_$(date +%s)"
tmux send-keys -t "$SESSION" "$MARKER" Enter
sleep 0.5

if grep -q "$MARKER" "$LOG"; then
  ok "pipe-pane mirrors pane output to the log file"
else
  ng "pipe-pane silent failure — log has no marker (size: $(wc -c < "$LOG"))"
  head -c 300 "$LOG" | od -c | head -5
fi

# ─── Seed step: a fresh log should be primed with capture-pane content ─────

SESSION2="test-pipe-seed-$$"
tmux new-session -d -s "$SESSION2" 'bash -c "echo SEED_MARKER; sleep 60"'
sleep 0.3  # let the echo render

# Fresh log for this scenario.
LOG2="$STATE/topics/seed.log"
test_setup_pane_log "$SESSION2" "seed" "$STATE"

if grep -q "SEED_MARKER" "$LOG2"; then
  ok "setup_pane_log seeds the log with existing pane content (capture-pane)"
else
  ng "log not seeded — fresh log lacks pre-existing pane content"
  echo "    log size: $(wc -c < "$LOG2")"
  head -c 200 "$LOG2"
fi

echo
if [[ "$FAIL" -eq 0 ]]; then
  echo "✅ test_topic_wrapper_pipe_pane.sh: $PASS passed"
  exit 0
else
  echo "❌ test_topic_wrapper_pipe_pane.sh: $PASS passed, $FAIL failed"
  exit 1
fi
