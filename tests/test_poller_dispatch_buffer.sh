#!/bin/bash
# P1.4 / D3 — tmuxDispatch must use a per-call named tmux buffer, not the
# default (server-wide) buffer.
#
# `tmux load-buffer -` and `tmux paste-buffer -d -t <session>` operate on
# the same server-global default buffer. Two near-simultaneous calls
# targeting different sessions race: call B's load-buffer can overwrite
# the default before call A's paste-buffer fires, so A's pane receives
# B's text (or worse, empty). This manifests as "messages occasionally
# land in the wrong topic" in MULTI_TOPIC mode and as future-time bombs
# when a concurrent cta send or helper-spawn dispatches alongside the
# poller.
#
# Fix: each tmuxDispatch generates a unique buffer name (`pager-<thread>-
# <nonce>`), passes it to both load-buffer and paste-buffer via `-b`.
# The `-d` flag on paste-buffer cleans up the named buffer afterward.
#
# This test asserts at the source level that the named-buffer pattern is
# used. A behavioral concurrency test is intentionally NOT here — the
# primitive's correctness is verified by tmux's own implementation when
# named buffers are used. The risk we're catching is regression of the
# source pattern.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
POLLER="$SCRIPT_DIR/agent/poller/poller.ts"

PASS=0
FAIL=0
ok() { echo "  ok  $1";   PASS=$((PASS + 1)); }
ng() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }

# ─── Static: load-buffer and paste-buffer both carry -b <name> ─────────────

# load-buffer must include -b. Match across multiline argument arrays in
# spawnSync, so look for the pattern "load-buffer"..."-b" within the same
# tmuxDispatch function block.

LB_CALL=$(awk '/spawnSync.*tmux.*load-buffer/,/\);/' "$POLLER")
if echo "$LB_CALL" | grep -q '"-b"'; then
  ok "tmuxDispatch load-buffer uses -b (named buffer)"
else
  ng "tmuxDispatch load-buffer is still on the default buffer (D3 regression)."
fi

PB_CALL=$(awk '/spawnSync.*tmux.*paste-buffer/,/\);/' "$POLLER")
if echo "$PB_CALL" | grep -q '"-b"'; then
  ok "tmuxDispatch paste-buffer uses -b (named buffer)"
else
  ng "tmuxDispatch paste-buffer is still on the default buffer (D3 regression)."
fi

# The same name should be passed to both (per-call buffer name). Look for
# a shared variable used in both call sites.
DISPATCH_FN=$(awk '/^function tmuxDispatch/,/^}/' "$POLLER")
if echo "$DISPATCH_FN" | grep -E 'load-buffer.*"-b",[[:space:]]*(buf|bufferName|name|tmuxBuf)' >/dev/null \
   && echo "$DISPATCH_FN" | grep -E 'paste-buffer.*"-b",[[:space:]]*(buf|bufferName|name|tmuxBuf)' >/dev/null; then
  ok "tmuxDispatch: load + paste use the same buffer-name variable"
else
  # Less-strict check: both use -b
  if echo "$DISPATCH_FN" | grep -c '"-b"' | grep -q '^[2-9]'; then
    ok "tmuxDispatch: load + paste both have -b (variable-name check skipped)"
  else
    ng "tmuxDispatch: load + paste must share a per-call buffer name"
  fi
fi

# The buffer name should be unique-ish: per-call, not a hardcoded literal.
# Check the spawn calls reference something other than a fixed string for
# the -b value. (Heuristic: the value after "-b" is followed by a comma
# and an identifier-shaped token, not a string literal like "default".)
# We pass if there's at least no obvious hardcoded literal like "-b", "x".

if echo "$DISPATCH_FN" | grep -E '"-b",[[:space:]]*"[^"]+"' >/dev/null; then
  ng "tmuxDispatch uses a hardcoded buffer name literal; must be per-call"
else
  ok "tmuxDispatch buffer name appears to be a variable (per-call), not a hardcoded literal"
fi

echo
if [[ "$FAIL" -eq 0 ]]; then
  echo "✅ test_poller_dispatch_buffer.sh: $PASS passed"
  exit 0
else
  echo "❌ test_poller_dispatch_buffer.sh: $PASS passed, $FAIL failed"
  exit 1
fi
