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

# ─── summary ─────────────────────────────────────────────────────────────────

echo
echo "restart_claude.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
