#!/bin/bash
# Tests for cta's mount/umount/list subcommands.
#
# Strategy: run cli/cta against a tempdir state with CTA_AGENT_DIR
# pointing at the repo (no install needed). Use a private tmux socket
# (-L test-cta) so we never touch the live tmux server.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CTA="$SCRIPT_DIR/cli/cta"
PRIVATE_SOCKET="test-cta-$$"

PASS=0
FAIL=0
ok() { echo "  ok  $1";   PASS=$((PASS + 1)); }
ng() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }

STATE=$(mktemp -d)
TMP_PROJECT=$(mktemp -d)
export CTA_STATE_DIR="$STATE"
export CTA_AGENT_DIR="$SCRIPT_DIR/agent"

# Run cta against an isolated tmux server so tests can never touch the
# user's live tmux. Two layers of isolation:
#   1. TMUX_TMPDIR — tells tmux where to put its socket. Setting this for
#      the cta invocation routes any unqualified `tmux …` calls inside cta
#      to a socket dir we control. (PATH-shim alone is insufficient because
#      cta prepends /opt/homebrew/bin in its own header, defeating the shim.)
#   2. PATH shim with `-L <socket>` — pins the socket name as well so a
#      stray default-socket session in TMUX_TMPDIR can't be mistaken for ours.
#   3. Unset TMUX/TMUX_PANE — if the test itself is run from inside a tmux
#      pane, child tmux invocations inherit TMUX and connect back to the
#      OUTER server (ignoring TMUX_TMPDIR + -L). That makes the user's real
#      poller session visible to cta has-session checks and breaks the
#      no-poller assertion. Stripping these vars forces tmux to fall back
#      to TMUX_TMPDIR resolution.
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
  rm -rf "$STATE" "$TMP_PROJECT"
}
trap cleanup EXIT

# ─── cta list: empty ────────────────────────────────────────────────────────

OUT=$(cta list 2>&1)
if echo "$OUT" | grep -q "No mounts"; then
  ok "cta list (empty): friendly message"
else
  ng "cta list (empty): friendly message (got '$OUT')"
fi

# ─── cta mount: rejects non-dir ─────────────────────────────────────────────

if cta mount 42 /no/such/dir 2>/dev/null; then
  ng "cta mount: rejects non-dir path"
else
  ok "cta mount: rejects non-dir path"
fi

# ─── cta mount: happy path ──────────────────────────────────────────────────

OUT=$(cta mount 42 "$TMP_PROJECT" iron-flow 2>&1)
if echo "$OUT" | grep -q "Mounted thread 42"; then
  ok "cta mount: success message"
else
  ng "cta mount: success message (got '$OUT')"
fi

# cta mount only writes mounts.json; the poller's daemon registry lazy-spawns
# the claude process on next inbound message. The success message has a poller-
# state-dependent suffix ("daemon spawns on next inbound" vs "will route on next
# 'cta start'") — P6c computes that from pgrep liveness, which in a subprocess
# test can't be isolated from a real poller on the host. Assert the stable
# success line + that one of the two valid suffixes is present.
if echo "$OUT" | grep -q "Mounted thread 42 at" \
   && echo "$OUT" | grep -Eq "daemon spawns on next inbound|will route on next 'cta start'"; then
  ok "cta mount: success message with route hint"
else
  ng "cta mount: success message with route hint (got '$OUT')"
fi

# ─── cta list: with one mount ───────────────────────────────────────────────

# P6c: per-topic tmux/STATUS columns are gone (daemons live inside the poller;
# there's no per-topic process to probe). The row still surfaces the thread +
# label + path.
OUT=$(cta list 2>&1)
if echo "$OUT" | grep -q "iron-flow" && echo "$OUT" | grep -q "42"; then
  ok "cta list: shows the mounted row (thread 42, label iron-flow)"
else
  ng "cta list: shows the mounted row (got '$OUT')"
fi

# ─── cta list --json: parseable ─────────────────────────────────────────────

JSON=$(cta list --json 2>&1)
if echo "$JSON" | jq -e '.mounts | length == 1' >/dev/null; then
  ok "cta list --json: valid JSON with 1 mount"
else
  ng "cta list --json: valid JSON with 1 mount (got '$JSON')"
fi

# ─── cta umount: happy path ─────────────────────────────────────────────────

OUT=$(cta umount 42 2>&1)
if echo "$OUT" | grep -q "Unmounted thread 42"; then
  ok "cta umount: success message"
else
  ng "cta umount: success message (got '$OUT')"
fi

# ─── cta umount: no-op on missing ───────────────────────────────────────────

OUT=$(cta umount 99999 2>&1)
if echo "$OUT" | grep -q "was not mounted"; then
  ok "cta umount missing: friendly no-op"
else
  ng "cta umount missing: friendly no-op (got '$OUT')"
fi

# ─── cta bind: removed in P6c ────────────────────────────────────────────────
# `cta bind` was a tmux-only affordance (pin the current tmux session to a
# thread). With tmux gone it has no meaning and was removed; assert the
# subcommand is now unknown.

OUT=$("$CTA" bind 42 2>&1 || true)
if echo "$OUT" | grep -q "Unknown command: bind"; then
  ok "cta bind: removed (unknown command)"
else
  ng "cta bind: expected 'Unknown command: bind' (got '$OUT')"
fi

# ─── result ─────────────────────────────────────────────────────────────────

echo
if [[ "$FAIL" -eq 0 ]]; then
  echo "✅ test_cta_mounts.sh: $PASS passed"
  exit 0
else
  echo "❌ test_cta_mounts.sh: $PASS passed, $FAIL failed"
  exit 1
fi
