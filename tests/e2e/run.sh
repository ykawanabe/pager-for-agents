#!/bin/bash
# tests/e2e/run.sh — agent-runnable E2E scenario runner.
#
# Usage:
#   bash tests/e2e/run.sh                     # all scenarios
#   bash tests/e2e/run.sh <scenario_name>     # specific (with or without .sh)
#
# Each scenario lives at tests/e2e/scenarios/<name>.sh and is self-contained
# (sources lib/harness.sh, sets up its own sandbox, tears down on exit).
# This runner orchestrates scenario discovery, sequencing, and result tally.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCENARIOS_DIR="$SCRIPT_DIR/scenarios"

# Tool prereqs.
need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing tool: $1 — install before running" >&2
    exit 1
  }
}
need bash
need bun
need tmux
need curl
need jq

run_one() {
  local s="$1"
  local name
  name=$(basename "$s" .sh)
  echo "════════════════════════════════════════════════════════"
  echo " scenario: $name"
  echo "════════════════════════════════════════════════════════"
  if bash "$s"; then
    return 0
  else
    return 1
  fi
}

if [[ $# -gt 0 ]]; then
  arg="$1"
  s="$SCENARIOS_DIR/${arg%.sh}.sh"
  if [[ ! -f "$s" ]]; then
    echo "scenario not found: $s" >&2
    exit 1
  fi
  run_one "$s"
  exit $?
fi

# All scenarios.
total=0
passed=0
failed_names=()
for s in "$SCENARIOS_DIR"/*.sh; do
  [[ -f "$s" ]] || continue
  total=$((total + 1))
  if run_one "$s"; then
    passed=$((passed + 1))
  else
    failed_names+=("$(basename "$s" .sh)")
  fi
  echo
done

echo "════════════════════════════════════════════════════════"
echo " E2E suite: $passed/$total passed"
if [[ ${#failed_names[@]} -gt 0 ]]; then
  echo " failed: ${failed_names[*]}"
fi
echo "════════════════════════════════════════════════════════"
exit "${#failed_names[@]}"
