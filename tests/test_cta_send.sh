#!/bin/bash
# Tests for `cta send <thread> <text>` (watch-live plan, Phase C.1).
#
# Delivers text into a topic's tmux pane via load-buffer + paste-buffer +
# send-keys Enter (same dispatch primitive the poller uses — D3 fix
# applies here too: per-call named buffer eliminates inter-process races).
#
# Exit codes mirror cta watch: 0=delivered, 1=no mount/usage, 2=tmux dead.
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

mkdir -p "$STATE/tmux-$(id -u)"
chmod 700 "$STATE/tmux-$(id -u)"

cta() {
  TMUX_TMPDIR="$STATE" env -u TMUX -u TMUX_PANE "$CTA" "$@"
}
tmux_test() {
  TMUX_TMPDIR="$STATE" env -u TMUX -u TMUX_PANE "$(command -v tmux)" "$@"
}

cleanup() {
  tmux_test kill-server 2>/dev/null || true
  rm -rf "$STATE" "$TMP_PROJECT"
}
trap cleanup EXIT

# ─── No mount → exit 1 ─────────────────────────────────────────────────────

set +e
OUT=$(cta send 99999 "hello" 2>&1)
RC=$?
set -e
if [[ "$RC" -eq 1 ]] && echo "$OUT" | grep -qi "no mount\|not mounted"; then
  ok "cta send (no mount): exit 1"
else
  ng "cta send (no mount): exit 1 (rc=$RC, out='$OUT')"
fi

# ─── Mount but no tmux → exit 2 ────────────────────────────────────────────

cta mount 42 "$TMP_PROJECT" iron-flow >/dev/null 2>&1
set +e
OUT=$(cta send 42 "hello" 2>&1)
RC=$?
set -e
if [[ "$RC" -eq 2 ]]; then
  ok "cta send (dead tmux): exit 2"
else
  ng "cta send (dead tmux): exit 2 (rc=$RC, out='$OUT')"
fi

# ─── Happy path: delivers text + Enter ─────────────────────────────────────

# Spawn a tmux session backed by `cat` so anything pasted + Enter is
# echoed to the pane.
tmux_test new-session -d -s topic-42 cat

OUT=$(cta send 42 "WATCH_SEND_TEST_ABC" 2>&1)
RC=$?
sleep 0.2  # paste→echo

PANE=$(tmux_test capture-pane -p -t topic-42 2>&1)
if [[ "$RC" -eq 0 ]] && echo "$PANE" | grep -q "WATCH_SEND_TEST_ABC"; then
  ok "cta send: delivers text to pane (visible via capture-pane)"
else
  ng "cta send: text not delivered (rc=$RC, pane='$PANE')"
fi

# ─── Multiline content survives paste-buffer ──────────────────────────────

cta send 42 $'first-line-XYZ\nsecond-line-XYZ' >/dev/null 2>&1
sleep 0.2

PANE=$(tmux_test capture-pane -p -t topic-42 2>&1)
if echo "$PANE" | grep -q "first-line-XYZ" && echo "$PANE" | grep -q "second-line-XYZ"; then
  ok "cta send: multiline content delivered intact"
else
  ng "cta send: multiline delivery (pane='$PANE')"
fi

# ─── DM key ────────────────────────────────────────────────────────────────

cta mount dm "$TMP_PROJECT" general >/dev/null 2>&1
tmux_test new-session -d -s topic-dm cat

cta send dm "DM_SEND_TEST_LINE" >/dev/null 2>&1
sleep 0.2
PANE=$(tmux_test capture-pane -p -t topic-dm 2>&1)
if echo "$PANE" | grep -q "DM_SEND_TEST_LINE"; then
  ok "cta send dm: works for DM key"
else
  ng "cta send dm: works (pane='$PANE')"
fi

# ─── Missing args → usage ─────────────────────────────────────────────────

set +e
OUT=$(cta send 2>&1)
RC=$?
set -e
if [[ "$RC" -ne 0 ]] && echo "$OUT" | grep -qi "usage"; then
  ok "cta send (no args): usage message"
else
  ng "cta send (no args): usage (rc=$RC, out='$OUT')"
fi

set +e
OUT=$(cta send 42 2>&1)
RC=$?
set -e
if [[ "$RC" -ne 0 ]] && echo "$OUT" | grep -qi "usage\|text"; then
  ok "cta send (no text): usage message"
else
  ng "cta send (no text): usage (rc=$RC, out='$OUT')"
fi

echo
if [[ "$FAIL" -eq 0 ]]; then
  echo "✅ test_cta_send.sh: $PASS passed"
  exit 0
else
  echo "❌ test_cta_send.sh: $PASS passed, $FAIL failed"
  exit 1
fi
