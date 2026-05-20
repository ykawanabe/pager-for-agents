#!/bin/bash
# Tests for `cta send <thread> <text>` (watch-live plan, Phase C.1).
#
# Phase 4 (daemon mode): topics are claude daemons, not tmux sessions. `cta
# send` drops an atomic file into $STATE_DIR/inject/<thread_id>__<nonce>.txt
# which the poller watches and enqueues into the topic's daemon. This test
# verifies the drop behavior (the poller side is covered by poller tests).
#
# Exit codes: 0=queued, 1=no mount/usage/write-failure.
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
INJECT="$STATE/inject"

cta() {
  env -u TMUX -u TMUX_PANE "$CTA" "$@"
}

cleanup() { rm -rf "$STATE" "$TMP_PROJECT"; }
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

# ─── Mount + send → exit 0, inject file dropped with content ───────────────

cta mount 42 "$TMP_PROJECT" iron-flow >/dev/null 2>&1
set +e
OUT=$(cta send 42 "WATCH_SEND_TEST_ABC" 2>&1)
RC=$?
set -e
f=$(ls "$INJECT"/42__*.txt 2>/dev/null | head -1)
if [[ "$RC" -eq 0 && -n "$f" ]] && [[ "$(cat "$f")" == "WATCH_SEND_TEST_ABC" ]]; then
  ok "cta send: exit 0 + inject file with exact content"
else
  ng "cta send: drop failed (rc=$RC, file='$f', out='$OUT')"
fi

# ─── No stray .tmp left behind (atomic publish) ────────────────────────────

if ! ls "$INJECT"/.*.tmp >/dev/null 2>&1; then
  ok "cta send: no leftover .tmp (atomic rename)"
else
  ng "cta send: leftover .tmp found"
fi

# ─── Multiline content preserved verbatim ──────────────────────────────────

cta send 42 $'first-line-XYZ\nsecond-line-XYZ' >/dev/null 2>&1
# newest 42__*.txt
f=$(ls -t "$INJECT"/42__*.txt 2>/dev/null | head -1)
if [[ -n "$f" ]] && grep -q "first-line-XYZ" "$f" && grep -q "second-line-XYZ" "$f"; then
  ok "cta send: multiline content preserved"
else
  ng "cta send: multiline (file='$f')"
fi

# ─── DM key → dm__*.txt ─────────────────────────────────────────────────────

cta mount dm "$TMP_PROJECT" general >/dev/null 2>&1
cta send dm "DM_SEND_TEST_LINE" >/dev/null 2>&1
f=$(ls "$INJECT"/dm__*.txt 2>/dev/null | head -1)
if [[ -n "$f" ]] && [[ "$(cat "$f")" == "DM_SEND_TEST_LINE" ]]; then
  ok "cta send dm: drops dm__*.txt with content"
else
  ng "cta send dm: drop (file='$f')"
fi

# ─── inject dir is private (0700) ──────────────────────────────────────────

mode=$(stat -f '%Lp' "$INJECT" 2>/dev/null || stat -c '%a' "$INJECT" 2>/dev/null)
if [[ "$mode" == "700" ]]; then
  ok "cta send: inject dir is mode 700"
else
  ng "cta send: inject dir mode (got '$mode')"
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
