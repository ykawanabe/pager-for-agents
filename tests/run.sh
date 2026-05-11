#!/bin/bash
# Test runner. Executes every test_*.sh in this directory and fails fast on
# the first failure. CI runs this; pre-push hook can run it too.
set -uo pipefail

cd "$(dirname "$0")"
FAILED=0

for t in test_*.sh; do
  echo "── $t ─────────────────────────────────────────────"
  if ! bash "$t"; then
    FAILED=$((FAILED + 1))
  fi
  echo
done

if [[ "$FAILED" -ne 0 ]]; then
  echo "❌ $FAILED test file(s) failed"
  exit 1
fi
echo "✅ all test files passed"
