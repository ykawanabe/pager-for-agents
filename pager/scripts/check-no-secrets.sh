#!/bin/bash
# Project-specific privacy / secret regex check. Run by pre-commit on every
# commit. Catches:
#   - Telegram bot tokens (canonical pattern)
#   - Hardcoded `/Users/<name>` paths (we always use $HOME or ~)
#   - Personal contact emails (we prefer routing via GitHub for support/security)
#
# Returns 0 = clean, 1 = blocking match.
set -uo pipefail

CHANGED=$(git diff --cached --name-only --diff-filter=ACM)
if [[ -z "$CHANGED" ]]; then
  exit 0
fi

PATTERNS=(
  '\b[0-9]{8,12}:[A-Za-z0-9_-]{35,}\b'
  '/Users/[a-z][a-z0-9_-]+'
  '\b[A-Za-z0-9._%+-]+@(?!example\.com)[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b'
)

HIT=0
for file in $CHANGED; do
  case "$file" in
    scripts/check-no-secrets.sh) continue ;;
    .pre-commit-config.yaml)     continue ;;
  esac
  [[ -f "$file" ]] || continue

  for pat in "${PATTERNS[@]}"; do
    if grep -nE "$pat" "$file" > /tmp/precommit-hit.$$ 2>/dev/null; then
      if [[ -s /tmp/precommit-hit.$$ ]]; then
        printf '\033[31m✗ %s — matched %s\033[0m\n' "$file" "$pat" >&2
        cat /tmp/precommit-hit.$$ | sed 's/^/    /' >&2
        HIT=1
      fi
    fi
  done
done
rm -f /tmp/precommit-hit.$$

if [[ $HIT -ne 0 ]]; then
  cat >&2 <<EOF

Commit blocked. The patterns above look like personal info or secrets.

If a match is a false positive, either:
  - Reword to avoid the pattern, OR
  - Add an inline exception comment and adjust scripts/check-no-secrets.sh.

EOF
  exit 1
fi
