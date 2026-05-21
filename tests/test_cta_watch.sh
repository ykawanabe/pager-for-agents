#!/bin/bash
# Tests for `cta watch <thread>` (P6: renders the topic's claude session JSONL
# transcript — Phase 4 daemons have no per-topic tmux pane to capture).
# Exit codes: 0=ok, 1=no mount / bad args, 2=no transcript yet.
#
# Strategy: mount a thread against a temp project dir, drop a session UUID +
# a fixture JSONL under a sandbox $HOME/.claude/projects/, and assert cta watch
# renders the user/assistant turns (and skips thinking / non-message events).
#
# NOTE: no `set -e` — assertions deliberately run commands that exit non-zero
# and capture $? by hand. errexit would abort the script on the first one.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CTA="$SCRIPT_DIR/cli/cta"

PASS=0
FAIL=0
ok() { echo "  ok  $1";   PASS=$((PASS + 1)); }
ng() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }

STATE=$(mktemp -d)
# Resolve symlinks (/var → /private/var on macOS): `cta mount` canonicalizes
# the stored path, and watch-render encodes that — so the fixture JSONL must
# live under the SAME canonical form or the encoded project dir won't match.
TMP_PROJECT=$(cd "$(mktemp -d)" && pwd -P)
HOME_DIR=$(mktemp -d)
export CTA_STATE_DIR="$STATE"
export CTA_AGENT_DIR="$SCRIPT_DIR/agent"

# cta watch shells out to `bun run watch-render.ts`, which resolves the JSONL
# under $HOME/.claude/projects/ (effectiveHome = $HOME). Pin HOME to a sandbox.
cta() { HOME="$HOME_DIR" "$CTA" "$@"; }

cleanup() { rm -rf "$STATE" "$TMP_PROJECT" "$HOME_DIR"; }
trap cleanup EXIT

# Mirror claudeProjectDirEncode: non-[a-zA-Z0-9-] → "-".
encode_path() { echo "$1" | sed 's/[^a-zA-Z0-9-]/-/g'; }

UUID="11111111-2222-3333-4444-555555555555"

# ─── Exit 1: no mount ───────────────────────────────────────────────────────
OUT=$(cta watch 99999 2>&1); RC=$?
if [[ "$RC" -eq 1 ]] && echo "$OUT" | grep -qi "no mount"; then
  ok "cta watch (no mount): exit 1"
else ng "cta watch (no mount): exit 1 (rc=$RC, out='$OUT')"; fi

# ─── Setup: mount thread 42 ─────────────────────────────────────────────────
cta mount 42 "$TMP_PROJECT" iron-flow >/dev/null 2>&1

# ─── Exit 2: mount exists, no session UUID yet ──────────────────────────────
OUT=$(cta watch 42 2>&1); RC=$?
if [[ "$RC" -eq 2 ]] && echo "$OUT" | grep -qi "no session"; then
  ok "cta watch (no session yet): exit 2"
else ng "cta watch (no session yet): exit 2 (rc=$RC, out='$OUT')"; fi

# ─── Exit 2: session UUID present but no JSONL on disk ──────────────────────
mkdir -p "$STATE/sessions"
echo "$UUID" > "$STATE/sessions/42"
OUT=$(cta watch 42 2>&1); RC=$?
if [[ "$RC" -eq 2 ]] && echo "$OUT" | grep -qi "no transcript"; then
  ok "cta watch (session, no JSONL): exit 2"
else ng "cta watch (session, no JSONL): exit 2 (rc=$RC, out='$OUT')"; fi

# ─── Exit 0: fixture JSONL → renders the transcript ─────────────────────────
ENC=$(encode_path "$TMP_PROJECT")
JDIR="$HOME_DIR/.claude/projects/$ENC"
mkdir -p "$JDIR"
cat > "$JDIR/$UUID.jsonl" <<'EOF'
{"type":"system","subtype":"init"}
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"hello from user"}]}}
{"type":"assistant","message":{"content":[{"type":"thinking","text":"secret thoughts"},{"type":"text","text":"hi from claude"}]}}
{"type":"ai-title","title":"noise-title"}
EOF

OUT=$(cta watch 42 2>&1); RC=$?
if [[ "$RC" -eq 0 ]] && echo "$OUT" | grep -q "You: hello from user" && echo "$OUT" | grep -q "Claude: hi from claude"; then
  ok "cta watch: renders user + assistant turns from JSONL"
else ng "cta watch: render (rc=$RC, out='$OUT')"; fi

if ! echo "$OUT" | grep -q "secret thoughts"; then
  ok "cta watch: skips thinking blocks"
else ng "cta watch: leaked a thinking block"; fi

if ! echo "$OUT" | grep -qi "noise-title"; then
  ok "cta watch: skips non-message events"
else ng "cta watch: leaked a non-message event"; fi

# ─── --lines N accepted ─────────────────────────────────────────────────────
OUT=$(cta watch 42 --lines 50 2>&1); RC=$?
if [[ "$RC" -eq 0 ]] && echo "$OUT" | grep -q "hello from user"; then
  ok "cta watch --lines N: accepted"
else ng "cta watch --lines N (rc=$RC, out='$OUT')"; fi

# ─── --lines abc rejected ───────────────────────────────────────────────────
OUT=$(cta watch 42 --lines abc 2>&1); RC=$?
if [[ "$RC" -ne 0 ]]; then ok "cta watch --lines abc: rejected"
else ng "cta watch --lines abc not rejected (rc=$RC)"; fi

# ─── --ansi / --follow inert (snapshot, still exit 0 + content) ─────────────
OUT=$(cta watch 42 --ansi 2>&1); RC=$?
if [[ "$RC" -eq 0 ]] && echo "$OUT" | grep -q "hi from claude"; then
  ok "cta watch --ansi: inert, returns transcript"
else ng "cta watch --ansi (rc=$RC)"; fi
OUT=$(cta watch 42 --follow 2>&1); RC=$?
if [[ "$RC" -eq 0 ]] && echo "$OUT" | grep -q "hi from claude"; then
  ok "cta watch --follow: inert one-shot snapshot (streaming dropped)"
else ng "cta watch --follow (rc=$RC)"; fi

# ─── no thread arg → usage + non-zero ───────────────────────────────────────
OUT=$(cta watch 2>&1); RC=$?
if [[ "$RC" -ne 0 ]] && echo "$OUT" | grep -qi "usage\|thread"; then
  ok "cta watch (no arg): usage + non-zero"
else ng "cta watch (no arg) (rc=$RC, out='$OUT')"; fi

# ─── dm key (shares the project path → same JSONL) ──────────────────────────
cta mount dm "$TMP_PROJECT" general >/dev/null 2>&1
echo "$UUID" > "$STATE/sessions/dm"
OUT=$(cta watch dm 2>&1); RC=$?
if [[ "$RC" -eq 0 ]] && echo "$OUT" | grep -q "hello from user"; then
  ok "cta watch dm: works for the DM key"
else ng "cta watch dm (rc=$RC, out='$OUT')"; fi

echo
if [[ "$FAIL" -eq 0 ]]; then
  echo "✅ test_cta_watch.sh: $PASS passed"
  exit 0
else
  echo "❌ test_cta_watch.sh: $PASS passed, $FAIL failed"
  exit 1
fi
