#!/bin/bash
# Tests for services/mount-store/mount-store.ts.
#
# Strategy: run the bun CLI against a tempdir state, assert JSON output via
# jq, exercise lock contention by firing N parallel adds.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STORE="$SCRIPT_DIR/services/mount-store/mount-store.ts"

PASS=0
FAIL=0
ok() { echo "  ok  $1";   PASS=$((PASS + 1)); }
ng() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }

# Fresh state dir per test run.
STATE=$(mktemp -d)
export CTA_STATE_DIR="$STATE"
trap 'rm -rf "$STATE"' EXIT

# ─── basic round-trip ───────────────────────────────────────────────────────

if bun run "$STORE" list >/dev/null 2>&1; then
  ok "list on empty state: succeeds"
else
  ng "list on empty state: succeeds"
fi

COUNT=$(bun run "$STORE" list | jq '.mounts | length')
[[ "$COUNT" == "0" ]] && ok "list on empty state: 0 mounts" || ng "list on empty state: 0 mounts (got $COUNT)"

MOUNT=$(bun run "$STORE" add 42 /tmp iron-flow)
[[ "$(echo "$MOUNT" | jq -r '.thread_id')" == "42" ]] && ok "add 42: thread_id=42" || ng "add 42: thread_id=42"
[[ "$(echo "$MOUNT" | jq -r '.tmux_session')" == "topic-42" ]] && ok "add 42: tmux_session=topic-42" || ng "add 42: tmux_session=topic-42"
[[ "$(echo "$MOUNT" | jq -r '.label')" == "iron-flow" ]] && ok "add 42: label preserved" || ng "add 42: label preserved"
[[ -n "$(echo "$MOUNT" | jq -r '.session_id')" ]] && ok "add 42: session_id non-empty" || ng "add 42: session_id non-empty"

# DM as a special thread_id
DM=$(bun run "$STORE" add dm /tmp claude-home)
[[ "$(echo "$DM" | jq -r '.thread_id')" == "dm" ]] && ok "add dm: thread_id=dm (string)" || ng "add dm: thread_id=dm (string)"
[[ "$(echo "$DM" | jq -r '.tmux_session')" == "topic-dm" ]] && ok "add dm: tmux_session=topic-dm" || ng "add dm: tmux_session=topic-dm"

# Dup rejection
if bun run "$STORE" add 42 /tmp duplicate >/dev/null 2>&1; then
  ng "add 42 twice: rejects duplicate"
else
  ok "add 42 twice: rejects duplicate"
fi

# get
[[ "$(bun run "$STORE" get 42 | jq -r '.thread_id')" == "42" ]] && ok "get 42: round-trip" || ng "get 42: round-trip"
[[ "$(bun run "$STORE" get 999)" == "null" ]] && ok "get missing: returns null" || ng "get missing: returns null"

# Invalid thread_id
if bun run "$STORE" add foo /tmp 2>/dev/null; then
  ng "add with non-numeric thread_id: rejects"
else
  ok "add with non-numeric thread_id: rejects"
fi

if bun run "$STORE" add -1 /tmp 2>/dev/null; then
  ng "add with negative thread_id: rejects"
else
  ok "add with negative thread_id: rejects"
fi

# Remove
REMOVED=$(bun run "$STORE" remove 42)
[[ "$(echo "$REMOVED" | jq -r '.thread_id')" == "42" ]] && ok "remove 42: returns removed entry" || ng "remove 42: returns removed entry"
[[ "$(bun run "$STORE" remove 999)" == "null" ]] && ok "remove missing: returns null" || ng "remove missing: returns null"

# ─── concurrent writes ──────────────────────────────────────────────────────

# Fresh state for concurrency tests.
rm -rf "$STATE" && mkdir -p "$STATE"

PIDS=()
for i in 1 2 3 4 5 6 7 8 9 10; do
  (bun run "$STORE" add "$i" /tmp "label-$i" >/dev/null 2>&1) &
  PIDS+=($!)
done
for p in "${PIDS[@]}"; do wait "$p"; done

PARALLEL_COUNT=$(bun run "$STORE" list | jq '.mounts | length')
[[ "$PARALLEL_COUNT" == "10" ]] && ok "10 parallel distinct adds: all 10 persist" || ng "10 parallel distinct adds: got $PARALLEL_COUNT"

# Race 5 adds with the same thread_id — exactly one should win.
rm -rf "$STATE" && mkdir -p "$STATE"
WIN_COUNT=0
for i in 1 2 3 4 5; do
  (bun run "$STORE" add 99 /tmp "dup-$i" >/dev/null 2>&1 && echo win) &
done
wait
WIN_COUNT=$(bun run "$STORE" list | jq '.mounts | length')
[[ "$WIN_COUNT" == "1" ]] && ok "5 parallel dup adds: exactly 1 winner" || ng "5 parallel dup adds: got $WIN_COUNT winners"

# ─── tmux_session override (used by cta bind) ───────────────────────────────

rm -rf "$STATE" && mkdir -p "$STATE"

# 4th arg overrides the default `topic-<thread_id>` tmux session name.
BOUND=$(bun run "$STORE" add 7 /tmp iron-flow my-custom-tmux)
[[ "$(echo "$BOUND" | jq -r '.tmux_session')" == "my-custom-tmux" ]] && ok "add: tmux_session override pins caller name" || ng "add: tmux_session override pins caller name"
[[ "$(echo "$BOUND" | jq -r '.label')" == "iron-flow" ]] && ok "add: label preserved with override" || ng "add: label preserved with override"

# Empty 4th arg → defaults back to topic-<thread_id>
DEFAULT_TMUX=$(bun run "$STORE" add 8 /tmp another-label "")
[[ "$(echo "$DEFAULT_TMUX" | jq -r '.tmux_session')" == "topic-8" ]] && ok "add: empty tmux_session arg → default" || ng "add: empty tmux_session arg → default"

# ─── result ─────────────────────────────────────────────────────────────────

echo
if [[ "$FAIL" -eq 0 ]]; then
  echo "✅ test_mount_store.sh: $PASS passed"
  exit 0
else
  echo "❌ test_mount_store.sh: $PASS passed, $FAIL failed"
  exit 1
fi
