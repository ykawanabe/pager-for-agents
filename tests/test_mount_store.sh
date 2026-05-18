#!/bin/bash
# Tests for agent/mount-store/mount-store.ts.
#
# Strategy: run the bun CLI against a tempdir state, assert JSON output via
# jq, exercise lock contention by firing N parallel adds.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STORE="$SCRIPT_DIR/agent/mount-store/mount-store.ts"

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

# ─── wildcard "*" thread_id (catch-all template) ────────────────────────────

rm -rf "$STATE" && mkdir -p "$STATE"

WILD=$(bun run "$STORE" add '*' /tmp default)
[[ "$(echo "$WILD" | jq -r '.thread_id')" == "*" ]] && ok "add *: thread_id=* (string sentinel)" || ng "add *: thread_id=* (string sentinel)"

# Wildcard + specific mounts coexist
SPECIFIC=$(bun run "$STORE" add 42 /tmp specific)
[[ "$(echo "$SPECIFIC" | jq -r '.thread_id')" == "42" ]] && ok "add 42 alongside *: both persist" || ng "add 42 alongside *: both persist"

COUNT=$(bun run "$STORE" list | jq '.mounts | length')
[[ "$COUNT" == "2" ]] && ok "list shows both * and 42" || ng "list shows both * and 42 (got $COUNT)"

# get * works
[[ "$(bun run "$STORE" get '*' | jq -r '.thread_id')" == "*" ]] && ok "get *: round-trip" || ng "get *: round-trip"

# Dup * rejection
if bun run "$STORE" add '*' /tmp dup 2>/dev/null; then
  ng "add * twice: rejects duplicate"
else
  ok "add * twice: rejects duplicate"
fi

# Other invalid sentinels rejected
if bun run "$STORE" add 'all' /tmp 2>/dev/null; then
  ng "add with non-sentinel string ('all') rejects"
else
  ok "add with non-sentinel string ('all') rejects"
fi

# ─── tmux_session override (used by cta bind) ───────────────────────────────

rm -rf "$STATE" && mkdir -p "$STATE"

# 4th arg overrides the default `topic-<thread_id>` tmux session name.
BOUND=$(bun run "$STORE" add 7 /tmp iron-flow my-custom-tmux)
[[ "$(echo "$BOUND" | jq -r '.tmux_session')" == "my-custom-tmux" ]] && ok "add: tmux_session override pins caller name" || ng "add: tmux_session override pins caller name"
[[ "$(echo "$BOUND" | jq -r '.label')" == "iron-flow" ]] && ok "add: label preserved with override" || ng "add: label preserved with override"

# Empty 4th arg → defaults back to topic-<thread_id>
DEFAULT_TMUX=$(bun run "$STORE" add 8 /tmp another-label "")
[[ "$(echo "$DEFAULT_TMUX" | jq -r '.tmux_session')" == "topic-8" ]] && ok "add: empty tmux_session arg → default" || ng "add: empty tmux_session arg → default"

# ─── schema v1 → v2 read upgrade ────────────────────────────────────────────
# v0.1 installs wrote `{"version":1, "mounts":[{"thread_id",...}]}` without a
# `channel` field. readMounts must stamp `channel: "telegram"` on each row
# without rewriting the file (writes happen lazily on the next mutation).

rm -rf "$STATE" && mkdir -p "$STATE"
cat > "$STATE/mounts.json" <<'EOF'
{
  "version": 1,
  "mounts": [
    {
      "thread_id": 42,
      "path": "/tmp/iron-flow",
      "label": "iron-flow",
      "session_id": "legacy-uuid-1",
      "tmux_session": "topic-42",
      "created_at": "2026-05-13T04:26:39.826Z"
    }
  ]
}
EOF

V1_OUT=$(bun run "$STORE" list)
[[ "$(echo "$V1_OUT" | jq -r '.version')" == "2" ]] && ok "v1 read: upgraded to version 2 in memory" || ng "v1 read: upgraded to version 2 in memory"
[[ "$(echo "$V1_OUT" | jq -r '.mounts[0].channel')" == "telegram" ]] && ok "v1 read: stamps channel=telegram" || ng "v1 read: stamps channel=telegram"
[[ "$(echo "$V1_OUT" | jq -r '.mounts[0].thread_id')" == "42" ]] && ok "v1 read: thread_id preserved" || ng "v1 read: thread_id preserved"
[[ "$(echo "$V1_OUT" | jq -r '.mounts[0].session_id')" == "legacy-uuid-1" ]] && ok "v1 read: session_id preserved" || ng "v1 read: session_id preserved"

# File on disk stays v1 until a mutation rewrites it (no surprise writes).
[[ "$(jq -r '.version' "$STATE/mounts.json")" == "1" ]] && ok "v1 read: file on disk untouched" || ng "v1 read: file on disk untouched"

# Next mutation upgrades the file to v2.
bun run "$STORE" add 99 /tmp/other >/dev/null
[[ "$(jq -r '.version' "$STATE/mounts.json")" == "2" ]] && ok "post-mutation: file rewritten to v2" || ng "post-mutation: file rewritten to v2"
[[ "$(jq -r '.mounts[0].channel' "$STATE/mounts.json")" == "telegram" ]] && ok "post-mutation: legacy row gets channel" || ng "post-mutation: legacy row gets channel"
[[ "$(jq -r '.mounts[1].channel' "$STATE/mounts.json")" == "telegram" ]] && ok "post-mutation: new row defaults to telegram" || ng "post-mutation: new row defaults to telegram"

# ─── schema v2 round-trip ────────────────────────────────────────────────────
# A native-v2 file (with explicit channel) reads back without modification.

rm -rf "$STATE" && mkdir -p "$STATE"
cat > "$STATE/mounts.json" <<'EOF'
{
  "version": 2,
  "mounts": [
    {
      "channel": "telegram",
      "thread_id": 42,
      "path": "/tmp/iron-flow",
      "session_id": "v2-uuid-1",
      "tmux_session": "topic-42",
      "created_at": "2026-05-13T04:26:39.826Z"
    }
  ]
}
EOF

V2_OUT=$(bun run "$STORE" list)
[[ "$(echo "$V2_OUT" | jq -r '.version')" == "2" ]] && ok "v2 read: version=2" || ng "v2 read: version=2"
[[ "$(echo "$V2_OUT" | jq -r '.mounts[0].channel')" == "telegram" ]] && ok "v2 read: explicit channel preserved" || ng "v2 read: explicit channel preserved"

# ─── provisional / replace / gc-provisional ─────────────────────────────────
# Helper-mode features added 2026-05-17 for auto-mount.

rm -rf "$STATE" && mkdir -p "$STATE"

# Round-trip the provisional flag through add → get.
PROV=$(bun run "$STORE" add 11 /tmp/foo helper-test --provisional)
[[ "$(echo "$PROV" | jq -r '.provisional')" == "true" ]] && ok "add --provisional: flag set on returned mount" || ng "add --provisional: flag set on returned mount"
[[ "$(jq -r '.mounts[] | select(.thread_id==11) | .provisional' "$STATE/mounts.json")" == "true" ]] && ok "add --provisional: flag persisted to disk" || ng "add --provisional: flag persisted to disk"

# Plain add omits provisional entirely (absent, not false).
bun run "$STORE" add 12 /tmp/bar baz >/dev/null
PROV_PLAIN=$(jq -r '.mounts[] | select(.thread_id==12) | .provisional // "absent"' "$STATE/mounts.json")
[[ "$PROV_PLAIN" == "absent" ]] && ok "add without flag: provisional field absent on disk" || ng "add without flag: provisional field absent (got $PROV_PLAIN)"

# replace overwrites a provisional row and clears the flag.
REPLACED=$(bun run "$STORE" replace 11 /tmp/foo-real real-label)
[[ "$(echo "$REPLACED" | jq -r '.path')" == "/tmp/foo-real" ]] && ok "replace 11: path updated" || ng "replace 11: path updated"
[[ "$(echo "$REPLACED" | jq -r '.label')" == "real-label" ]] && ok "replace 11: label updated" || ng "replace 11: label updated"
[[ "$(echo "$REPLACED" | jq -r '.provisional // "absent"')" == "absent" ]] && ok "replace 11: provisional flag cleared" || ng "replace 11: provisional flag cleared"

# replace on a missing thread_id creates the row (no throw).
REPLACED_NEW=$(bun run "$STORE" replace 22 /tmp/new new-label)
[[ "$(echo "$REPLACED_NEW" | jq -r '.thread_id')" == "22" ]] && ok "replace on missing thread_id: creates row" || ng "replace on missing thread_id: creates row"

# gc-provisional drops provisional rows whose tmux is dead, keeps live rows.
rm -rf "$STATE" && mkdir -p "$STATE"
bun run "$STORE" add 33 /tmp/dead helper --provisional --tmux-session helper-33-DEAD >/dev/null
bun run "$STORE" add 44 /tmp/real real-mount >/dev/null
GC_OUT=$(bun run "$STORE" gc-provisional)
[[ "$(echo "$GC_OUT" | jq -r '.dropped')" == "1" ]] && ok "gc-provisional: drops orphan helper" || ng "gc-provisional: drops orphan helper (got $GC_OUT)"
[[ "$(bun run "$STORE" get 33)" == "null" ]] && ok "gc-provisional: removed thread 33" || ng "gc-provisional: removed thread 33"
[[ "$(bun run "$STORE" get 44 | jq -r '.thread_id')" == "44" ]] && ok "gc-provisional: kept non-provisional mount" || ng "gc-provisional: kept non-provisional mount"

# gc-provisional is idempotent.
GC_OUT_2=$(bun run "$STORE" gc-provisional)
[[ "$(echo "$GC_OUT_2" | jq -r '.dropped')" == "0" ]] && ok "gc-provisional: idempotent (0 on second run)" || ng "gc-provisional: idempotent"

# ─── gc-provisional grace period (P2.3 / D15) ───────────────────────────────
# Cold-boot scenario: every helper-<id> tmux is dead after a Mac reboot,
# but the provisional row was created seconds ago by spawnHelper. Without
# a grace window, gc wipes the user's in-progress helper conversation.

rm -rf "$STATE" && mkdir -p "$STATE"

# A fresh provisional row + a long grace window → preserved despite dead tmux.
bun run "$STORE" add 55 /tmp/fresh helper-fresh --provisional --tmux-session helper-55-DEAD >/dev/null
GC_GRACE=$(bun run "$STORE" gc-provisional --grace-ms 60000)
[[ "$(echo "$GC_GRACE" | jq -r '.dropped')" == "0" ]] \
  && ok "gc-provisional --grace-ms: fresh provisional row preserved within grace" \
  || ng "gc-provisional --grace-ms: fresh provisional should be preserved (got $GC_GRACE)"
[[ "$(bun run "$STORE" get 55 | jq -r '.thread_id')" == "55" ]] \
  && ok "gc-provisional --grace-ms: fresh row still present after gc" \
  || ng "gc-provisional --grace-ms: fresh row missing"

# An old provisional row (created_at backdated) + a short grace → still dropped.
# We backdate by rewriting mounts.json directly (the only test-friendly way).
jq '.mounts |= map(if .thread_id == 55 then .created_at = "2000-01-01T00:00:00Z" else . end)' \
  "$STATE/mounts.json" > "$STATE/mounts.json.tmp" && mv "$STATE/mounts.json.tmp" "$STATE/mounts.json"
GC_AGED=$(bun run "$STORE" gc-provisional --grace-ms 60000)
[[ "$(echo "$GC_AGED" | jq -r '.dropped')" == "1" ]] \
  && ok "gc-provisional --grace-ms: aged provisional (older than grace) dropped" \
  || ng "gc-provisional --grace-ms: aged provisional should be dropped (got $GC_AGED)"

# Real (non-provisional) rows untouched regardless of grace.
rm -rf "$STATE" && mkdir -p "$STATE"
bun run "$STORE" add 66 /tmp/real real-mount >/dev/null
GC_REAL=$(bun run "$STORE" gc-provisional --grace-ms 60000)
[[ "$(echo "$GC_REAL" | jq -r '.dropped')" == "0" ]] \
  && ok "gc-provisional --grace-ms: real rows untouched" \
  || ng "gc-provisional --grace-ms: real row was dropped (got $GC_REAL)"

# Default (no --grace-ms) preserves current behavior: dead tmux → drop.
rm -rf "$STATE" && mkdir -p "$STATE"
bun run "$STORE" add 77 /tmp/x helper-x --provisional --tmux-session helper-77-DEAD >/dev/null
GC_DEFAULT=$(bun run "$STORE" gc-provisional)
[[ "$(echo "$GC_DEFAULT" | jq -r '.dropped')" == "1" ]] \
  && ok "gc-provisional: default (no grace) still drops dead provisional" \
  || ng "gc-provisional default behavior changed (got $GC_DEFAULT)"

# ─── clear op (P2.5) ────────────────────────────────────────────────────────
# `cta unpair` historically `rm -f mounts.json` which bypassed the mount-store
# lock. A concurrent `cta mount` mid-rename could see the file vanish under
# it. The `clear` op writes an empty mounts list under withLock for atomicity.

rm -rf "$STATE" && mkdir -p "$STATE"
bun run "$STORE" add 11 /tmp/a a >/dev/null
bun run "$STORE" add 22 /tmp/b b >/dev/null
bun run "$STORE" clear >/dev/null
[[ -f "$STATE/mounts.json" ]] \
  && ok "clear: mounts.json STILL exists (not unlinked)" \
  || ng "clear: mounts.json was unlinked instead of emptied"
[[ "$(jq '.mounts | length' "$STATE/mounts.json")" == "0" ]] \
  && ok "clear: mounts array is empty" \
  || ng "clear: mounts array not empty (got $(jq '.mounts | length' "$STATE/mounts.json"))"
[[ "$(jq -r '.version' "$STATE/mounts.json")" == "2" ]] \
  && ok "clear: preserves schema version 2" \
  || ng "clear: version field not 2 (got $(jq -r '.version' "$STATE/mounts.json"))"

# clear is idempotent.
bun run "$STORE" clear >/dev/null
[[ "$(jq '.mounts | length' "$STATE/mounts.json")" == "0" ]] \
  && ok "clear: idempotent (already empty stays empty)" \
  || ng "clear: idempotent failure"

# clear on a never-existed file creates an empty one.
rm -rf "$STATE" && mkdir -p "$STATE"
bun run "$STORE" clear >/dev/null
[[ -f "$STATE/mounts.json" ]] \
  && ok "clear: creates mounts.json if absent" \
  || ng "clear: did not create mounts.json"

# ─── result ─────────────────────────────────────────────────────────────────

echo
if [[ "$FAIL" -eq 0 ]]; then
  echo "✅ test_mount_store.sh: $PASS passed"
  exit 0
else
  echo "❌ test_mount_store.sh: $PASS passed, $FAIL failed"
  exit 1
fi
