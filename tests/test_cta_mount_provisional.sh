#!/bin/bash
# P1.1 / D1 — cta mount must atomically replace a provisional row,
# not throw "already mounted".
#
# Helper auto-mount writes a provisional row at thread_id pointing at
# $HOME, then the helper claude runs `cta mount <thread_id> <real_path>
# <label>` to commit the user's choice. mount-store ships replaceMount
# as the primitive for this; cta wasn't calling it. addMount throws on
# duplicate including provisional, so the helper could never commit.
#
# Strategy: pre-add a provisional row via mount-store CLI, run cta mount
# pointing at a different real directory, assert the row is replaced
# atomically (not duplicated, no throw).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CTA="$SCRIPT_DIR/cli/cta"
MOUNT_STORE="$SCRIPT_DIR/agent/mount-store/mount-store.ts"
PRIVATE_SOCKET="test-cta-prov-$$"

PASS=0
FAIL=0
ok() { echo "  ok  $1";   PASS=$((PASS + 1)); }
ng() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }

STATE=$(mktemp -d)
# Resolve through pwd -P because cta does the same (so abs_path matches
# the row written by mount-store, regardless of /var → /private/var symlink
# on macOS).
HELPER_HOME=$(cd "$(mktemp -d)" && pwd -P)
REAL_PROJECT=$(cd "$(mktemp -d)" && pwd -P)
export CTA_STATE_DIR="$STATE"
export CTA_AGENT_DIR="$SCRIPT_DIR/agent"

cta() {
  TMUX_TMPDIR="$STATE" PATH="$STATE/bin:$PATH" \
    env -u TMUX -u TMUX_PANE "$CTA" "$@"
}

mkdir -p "$STATE/bin" "$STATE/tmux-$(id -u)"
cat > "$STATE/bin/tmux" <<EOF
#!/bin/bash
exec $(command -v tmux) -L "$PRIVATE_SOCKET" "\$@"
EOF
chmod +x "$STATE/bin/tmux"

cleanup() {
  TMUX_TMPDIR="$STATE" "$(command -v tmux)" -L "$PRIVATE_SOCKET" kill-server 2>/dev/null || true
  rm -rf "$STATE" "$HELPER_HOME" "$REAL_PROJECT"
}
trap cleanup EXIT

# ─── Setup: helper-spawned provisional row at thread 77 ─────────────────────

bun run "$MOUNT_STORE" add 77 "$HELPER_HOME" "helper-mount" "helper-77" --provisional >/dev/null

# Sanity: the row is there and marked provisional
JSON=$(bun run "$MOUNT_STORE" get 77)
if echo "$JSON" | jq -e '.provisional == true' >/dev/null; then
  ok "setup: provisional row exists with provisional=true"
else
  ng "setup: expected provisional=true on thread 77 row, got: $JSON"
fi

# ─── The bug: cta mount over a provisional row ──────────────────────────────

OUT=$(cta mount 77 "$REAL_PROJECT" "iron-flow" 2>&1)
RC=$?
if [[ "$RC" -eq 0 ]]; then
  ok "cta mount over provisional: exit 0 (no 'already mounted' throw)"
else
  ng "cta mount over provisional: expected exit 0, got $RC. Output: $OUT"
fi

# ─── Assert state after replace ─────────────────────────────────────────────

JSON=$(bun run "$MOUNT_STORE" get 77)

if ! echo "$JSON" | jq -e '.provisional // false | not' >/dev/null; then
  ng "after replace: provisional flag should be cleared. Got: $JSON"
else
  ok "after replace: provisional flag cleared"
fi

if echo "$JSON" | jq -e --arg p "$REAL_PROJECT" '.path == $p' >/dev/null; then
  ok "after replace: path is the real project ($REAL_PROJECT)"
else
  ng "after replace: expected path=$REAL_PROJECT. Got: $JSON"
fi

if echo "$JSON" | jq -e '.label == "iron-flow"' >/dev/null; then
  ok "after replace: label updated to 'iron-flow'"
else
  ng "after replace: expected label=iron-flow. Got: $JSON"
fi

# Exactly one row should exist for thread 77 (no duplicate)
COUNT=$(bun run "$MOUNT_STORE" list | jq '[.mounts[] | select(.thread_id == 77)] | length')
if [[ "$COUNT" -eq 1 ]]; then
  ok "after replace: exactly 1 row for thread 77 (no duplicate)"
else
  ng "after replace: expected 1 row for thread 77, got $COUNT"
fi

# ─── Non-regression: cta mount on a REAL (non-provisional) row still errors ─
# We don't want cta mount to blindly overwrite real mounts. Replace is for
# provisional only.

bun run "$MOUNT_STORE" add 88 "$REAL_PROJECT" "real-mount" >/dev/null
# Capture exit code directly — `|| true` would mask it.
OUT2=$(cta mount 88 "$HELPER_HOME" "should-not-overwrite" 2>&1)
RC2=$?
if [[ "$RC2" -ne 0 ]]; then
  ok "cta mount over REAL row: refuses (exit nonzero)"
else
  ng "cta mount over REAL row: should refuse, got exit 0. Output: $OUT2"
fi

# And the original row should be unchanged
JSON2=$(bun run "$MOUNT_STORE" get 88)
if echo "$JSON2" | jq -e --arg p "$REAL_PROJECT" '.path == $p' >/dev/null \
   && echo "$JSON2" | jq -e '.label == "real-mount"' >/dev/null; then
  ok "cta mount over REAL row: original row unchanged"
else
  ng "cta mount over REAL row: original was modified. Got: $JSON2"
fi

# ─── Result ─────────────────────────────────────────────────────────────────

echo
if [[ "$FAIL" -eq 0 ]]; then
  echo "✅ test_cta_mount_provisional.sh: $PASS passed"
  exit 0
else
  echo "❌ test_cta_mount_provisional.sh: $PASS passed, $FAIL failed"
  exit 1
fi
