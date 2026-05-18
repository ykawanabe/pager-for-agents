#!/bin/bash
# Project-wide regression guard against legacy state-dir hardcodes.
#
# Bug class: the v0.1 paths ~/.claude-telegram-agent/ and
# ~/.local/share/claude-telegram-agent/ keep leaking back into new code
# and config after refactors, even after the v0.2 rename to ~/.pager/
# and ~/.local/share/pager/. Two prior incidents:
#
#   - cli/cta hardcoded $HOME/.claude-telegram-agent/* for pairing-code,
#     paired.json, mounts.json. Fixed 2026-05-16. A 3-layer regression
#     guard was added inside tests/test_cta.sh — but only for cli/cta.
#   - The LaunchAgent plist template wrote StandardOutPath /
#     StandardErrorPath to __HOME__/.claude-telegram-agent/agent{,.err}.log,
#     re-creating the legacy state dir on every install. Fixed in commit
#     04fdfe4 (2026-05-18). cta's internal guard didn't cover the plist
#     template or other files outside cta.
#
# This test is the cross-repo complement: grep every tracked file for the
# legacy path followed by a real filename character. Bare brand mentions
# ("claude-telegram-agent CLI") and slash-followed-by-space-or-arrow
# ("~/.claude-telegram-agent/ →") in design docs are fine — they're not
# runtime path usages.
#
# Allowed:
#   1. Files in ALLOW_FILES (release notes, migration test, this test).
#   2. Comment lines (start with `#`, `//`, or `*` after optional space).
#
# Anything else fails. To unblock a true false positive, either:
#   - convert the line to a comment, or
#   - add the file to ALLOW_FILES with a comment explaining why.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"

# Files where legacy-path mentions are intentional and don't reflect
# runtime behavior. Keep this list short — every entry weakens the guard.
ALLOW_FILES=(
  "CHANGELOG.md"                            # historical release notes
  "pager/CHANGELOG.md"                      # historical release notes
  "tests/test_cta_migrate_state.sh"         # sets up v0.1 state to test migration
  "tests/test_state_path_no_hardcode.sh"    # this file references the pattern
)

is_allow_file() {
  local f="$1" af
  for af in "${ALLOW_FILES[@]}"; do
    [[ "$f" == "$af" ]] && return 0
  done
  return 1
}

is_comment_line() {
  [[ "$1" =~ ^[[:space:]]*(#|//|\*) ]]
}

# Path-form patterns: legacy dir followed by a real filename character.
# Skips `~/.claude-telegram-agent/ → ~/.pager/` (slash-space-arrow) in
# design docs, and bare brand mentions without a slash.
PATTERN='\.claude-telegram-agent/[a-zA-Z.]|share/claude-telegram-agent/[a-zA-Z.]'

violations=()
while IFS= read -r match; do
  [[ -z "$match" ]] && continue
  file="${match%%:*}"
  rest="${match#*:}"
  line_num="${rest%%:*}"
  content="${rest#*:}"

  is_allow_file "$file"   && continue
  is_comment_line "$content" && continue

  violations+=("$file:$line_num: $content")
done < <(git grep -nE "$PATTERN" 2>/dev/null || true)

PASS=0
FAIL=0
if [[ "${#violations[@]}" -eq 0 ]]; then
  echo "  ok  no legacy state-dir path used at runtime outside allowed contexts"
  PASS=1
else
  echo "  FAIL legacy state-dir path used outside allowed contexts:"
  for v in "${violations[@]}"; do
    echo "    $v"
  done
  echo
  echo "  If intentional: either convert the line to a comment, or add the"
  echo "  file to ALLOW_FILES in this test with a comment explaining why."
  echo "  Otherwise: replace the legacy path with \$STATE_DIR / ~/.pager/"
  echo "  (state) or \$INSTALL_DIR / ~/.local/share/pager/ (install)."
  FAIL=1
fi

echo
if [[ "$FAIL" -eq 0 ]]; then
  echo "✅ test_state_path_no_hardcode.sh: $PASS passed"
  exit 0
else
  echo "❌ test_state_path_no_hardcode.sh failed"
  exit 1
fi
