#!/bin/bash
# Unit tests for scripts/restart_claude.sh helpers.
#
# Strategy: source the script (which exposes the functions but skips main_loop
# because of the BASH_SOURCE guard), then call compute_next_delay directly
# with known inputs. Pure arithmetic — no mocking needed.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../scripts/restart_claude.sh
source "$SCRIPT_DIR/scripts/restart_claude.sh"

PASS=0
FAIL=0

ok() { echo "  ok  $1";   PASS=$((PASS + 1)); }
ng() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }

# Shorthand: assert that compute_next_delay produces expected output.
#   $1 = label, $2 = expected, $3..$7 = compute_next_delay args
assert_delay() {
  local label="$1" expected="$2"
  shift 2
  local actual
  actual=$(compute_next_delay "$@")
  if [[ "$actual" == "$expected" ]]; then
    ok "$label (got $actual)"
  else
    ng "$label (expected $expected, got $actual)"
  fi
}

# Constants used by the running script. The tests pin their own values so the
# script's defaults can shift later without invalidating the test contract.
MIN=3
MAX=60
HEALTHY=30

# ─── First-crash recovery ────────────────────────────────────────────────────

# Seed=0 (loop init), unhealthy run → promote to MIN. First crash recovers in
# MIN seconds, not MIN*2 — important for fast first-restart UX.
assert_delay "seed 0, short run → MIN" \
  "$MIN" 0 1 "$HEALTHY" "$MIN" "$MAX"

# ─── Doubling ladder ─────────────────────────────────────────────────────────

assert_delay "3, short run → 6" \
  6 3 1 "$HEALTHY" "$MIN" "$MAX"
assert_delay "6, short run → 12" \
  12 6 1 "$HEALTHY" "$MIN" "$MAX"
assert_delay "12, short run → 24" \
  24 12 1 "$HEALTHY" "$MIN" "$MAX"
assert_delay "24, short run → 48" \
  48 24 1 "$HEALTHY" "$MIN" "$MAX"

# ─── Cap at MAX ──────────────────────────────────────────────────────────────

# 48 * 2 = 96 → capped at 60.
assert_delay "48, short run → 60 (cap)" \
  "$MAX" 48 1 "$HEALTHY" "$MIN" "$MAX"
# Stays at cap.
assert_delay "60, short run → 60 (still cap)" \
  "$MAX" 60 1 "$HEALTHY" "$MIN" "$MAX"

# ─── Healthy-run reset ───────────────────────────────────────────────────────

# A run that lasted ≥ HEALTHY_RUN_SECS resets the ladder to MIN, regardless
# of how high it had climbed. Prevents "transient hiccup then steady" from
# leaving the next failure at a 60s delay.
assert_delay "any delay, healthy run → MIN" \
  "$MIN" 60 "$HEALTHY" "$HEALTHY" "$MIN" "$MAX"
assert_delay "delay 12, run for exactly HEALTHY → MIN" \
  "$MIN" 12 "$HEALTHY" "$HEALTHY" "$MIN" "$MAX"

# Boundary: ran_for one second below HEALTHY is NOT healthy → still grows.
assert_delay "delay 12, just-short run → 24 (no reset)" \
  24 12 $((HEALTHY - 1)) "$HEALTHY" "$MIN" "$MAX"

# ─── session_arg_flag: --session-id vs --resume ──────────────────────────────
#
# `claude --session-id <uuid>` only succeeds on first launch; once the session
# jsonl exists, claude refuses with "Session ID is already in use" and exits
# in <1s — restart_claude.sh then crashlooped forever (hit on 2026-05-12 after
# a connectivity-restored kick). session_arg_flag picks the right flag based
# on whether the jsonl already exists for this (cwd, uuid) pair.

# Use a tmp HOME so we don't touch the real ~/.claude/projects.
TMP_HOME=$(mktemp -d)
ORIG_HOME="$HOME"
export HOME="$TMP_HOME"
trap 'rm -rf "$TMP_HOME"; export HOME="$ORIG_HOME"' EXIT

CWD="/tmp/fakehome/agent-home"
ENCODED_CWD="-tmp-fakehome-agent-home"
UUID="11111111-2222-3333-4444-555555555555"

# No jsonl yet → fresh start, must use --session-id so claude creates with our UUID.
flag=$(session_arg_flag "$CWD" "$UUID")
[[ "$flag" == "--session-id" ]] && ok "no jsonl → --session-id" \
  || ng "no jsonl → expected --session-id, got $flag"

# Create the jsonl claude would have written. Note the path-encoding (/ → -).
mkdir -p "$HOME/.claude/projects/${ENCODED_CWD}"
touch "$HOME/.claude/projects/${ENCODED_CWD}/${UUID}.jsonl"

# jsonl exists → restart, must use --resume to pick up the existing transcript.
flag=$(session_arg_flag "$CWD" "$UUID")
[[ "$flag" == "--resume" ]] && ok "jsonl exists → --resume" \
  || ng "jsonl exists → expected --resume, got $flag"

# Different UUID at same cwd → first launch for THAT id.
flag=$(session_arg_flag "$CWD" "99999999-2222-3333-4444-555555555555")
[[ "$flag" == "--session-id" ]] && ok "different uuid → --session-id" \
  || ng "different uuid → expected --session-id, got $flag"

# Same UUID under different cwd → first launch in the new project dir.
flag=$(session_arg_flag "/tmp/fakehome/other-home" "$UUID")
[[ "$flag" == "--session-id" ]] && ok "different cwd → --session-id" \
  || ng "different cwd → expected --session-id, got $flag"

# ─── resolve_append_prompt: env-driven prompt selection ──────────────────────
#
# The bot passes claude `--append-system-prompt <text>` so its replies stop
# emitting Markdown that Telegram renders literally. The helper picks the
# right text given the user's .env value:
#   ""    → default
#   "off" → empty (no append)
#   "..." → custom text passes through verbatim

DEFAULT="default prompt text"

# Unset / empty → default.
[[ "$(resolve_append_prompt "" "$DEFAULT")" == "$DEFAULT" ]] \
  && ok "resolve_append_prompt: empty env → default" \
  || ng "resolve_append_prompt: empty env should yield default"

# "off" → empty string (caller drops the --append-system-prompt arg entirely).
[[ -z "$(resolve_append_prompt "off" "$DEFAULT")" ]] \
  && ok "resolve_append_prompt: 'off' → empty (no append)" \
  || ng "resolve_append_prompt: 'off' should yield empty"

# Custom text passes through, even when it happens to be long.
CUSTOM="be brief; no markdown"
[[ "$(resolve_append_prompt "$CUSTOM" "$DEFAULT")" == "$CUSTOM" ]] \
  && ok "resolve_append_prompt: custom text → custom (override)" \
  || ng "resolve_append_prompt: custom override broken"

# "off" is case-sensitive — guard against accidental "Off" treating it as
# "use this string verbatim". (Belt-and-suspenders: makes the contract
# explicit in tests.)
[[ "$(resolve_append_prompt "Off" "$DEFAULT")" == "Off" ]] \
  && ok "resolve_append_prompt: 'Off' (capital) treated as custom" \
  || ng "resolve_append_prompt: case-sensitivity contract broken"

# ─── summary ─────────────────────────────────────────────────────────────────

echo
echo "restart_claude.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
