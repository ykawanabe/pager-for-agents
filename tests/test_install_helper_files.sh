#!/bin/bash
# P1.2 / D2 — install.sh must ship helper-prompt.md and helper-permissions.json
# to $INSTALL_DIR/agent/.
#
# Strategy: two complementary checks.
#
#   1. Static: grep install.sh for the cp commands. Catches the "someone
#      removed the line" regression.
#
#   2. Integration: drive the agent-copy section in a sandbox with
#      $CTA_INSTALL_DIR pointing at a fresh tempdir. Asserts the files
#      land at the expected install path with non-zero size.
#
# Why both: static passes/fails on intent (the cp commands exist), but
# the file path itself could be wrong. Integration catches that.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_SH="$SCRIPT_DIR/install.sh"

PASS=0
FAIL=0
ok() { echo "  ok  $1";   PASS=$((PASS + 1)); }
ng() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }

# ─── Static: install.sh references both helper files ───────────────────────

if grep -q 'helper-prompt\.md' "$INSTALL_SH"; then
  ok "install.sh references helper-prompt.md"
else
  ng "install.sh does NOT reference helper-prompt.md (D2 regression)"
fi

if grep -q 'helper-permissions\.json' "$INSTALL_SH"; then
  ok "install.sh references helper-permissions.json"
else
  ng "install.sh does NOT reference helper-permissions.json (D2 regression)"
fi

# ─── Integration: actually copy and verify destination ─────────────────────

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
DEST_AGENT="$SANDBOX/install/agent"
mkdir -p "$DEST_AGENT"

# Run only the cp commands we care about, against the REAL repo source.
REPO_DIR="$SCRIPT_DIR"
if [[ -f "$REPO_DIR/agent/helper-prompt.md" ]]; then
  cp "$REPO_DIR/agent/helper-prompt.md" "$DEST_AGENT/" 2>/dev/null || true
fi
if [[ -f "$REPO_DIR/agent/helper-permissions.json" ]]; then
  cp "$REPO_DIR/agent/helper-permissions.json" "$DEST_AGENT/" 2>/dev/null || true
fi

# The integration test above only verifies the files COULD be copied. The
# install.sh test must verify install.sh ITSELF does the copy. Simulate
# install.sh's agent-copy block in isolation by sourcing the variables and
# running just the cp commands. Done by extracting via grep.

# Extract the lines that copy helper files (proves they exist in the script
# AND are syntactically valid bash). Skip if static checks failed.
DEST2="$SANDBOX/dest2"
mkdir -p "$DEST2"

CP_LINES=$(grep -E 'cp .*"\$REPO_DIR/agent/helper-(prompt\.md|permissions\.json)"' "$INSTALL_SH" || true)
if [[ -n "$CP_LINES" ]]; then
  # Replace $AGENT_DIR placeholder with our sandbox dest and execute the cp lines.
  REPO_DIR="$SCRIPT_DIR" AGENT_DIR="$DEST2" bash -c "$CP_LINES"
  if [[ -s "$DEST2/helper-prompt.md" ]]; then
    ok "install.sh cp line lands helper-prompt.md with non-zero size"
  else
    ng "install.sh cp line did NOT produce helper-prompt.md at \$AGENT_DIR"
  fi
  if [[ -s "$DEST2/helper-permissions.json" ]]; then
    ok "install.sh cp line lands helper-permissions.json with non-zero size"
  else
    ng "install.sh cp line did NOT produce helper-permissions.json at \$AGENT_DIR"
  fi
else
  ng "install.sh has no `cp \$REPO_DIR/agent/helper-*` lines (D2 not fixed)"
fi

echo
if [[ "$FAIL" -eq 0 ]]; then
  echo "✅ test_install_helper_files.sh: $PASS passed"
  exit 0
else
  echo "❌ test_install_helper_files.sh: $PASS passed, $FAIL failed"
  exit 1
fi
