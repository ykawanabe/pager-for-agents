#!/bin/bash
# Integration tests for scripts/check-no-secrets.sh.
#
# The hook reads `git diff --cached`, so each test spins up a fresh temp git
# repo, stages a fixture file, and runs the hook against it.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$REPO_ROOT/scripts/check-no-secrets.sh"

PASS=0
FAIL=0
ok() { echo "  ok  $1";   PASS=$((PASS + 1)); }
ng() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }

# Each test runs in its own tmp dir so git state never leaks across cases.
run_case() {
  local desc="$1"
  local expected_exit="$2"
  local fixture_name="$3"
  local fixture_body="$4"

  local tmp
  tmp="$(mktemp -d)"
  (
    cd "$tmp"
    git init -q
    git config user.email "test@example.com"
    git config user.name  "test"
    printf '%s' "$fixture_body" > "$fixture_name"
    git add "$fixture_name"
    # Use a forked PATH so the hook's relative paths resolve consistently.
    "$HOOK" > /dev/null 2>&1
    echo "$?" > .exit
  )
  local actual
  actual="$(cat "$tmp/.exit")"
  rm -rf "$tmp"

  if [[ "$actual" == "$expected_exit" ]]; then
    ok "$desc (exit=$actual)"
  else
    ng "$desc (expected=$expected_exit, actual=$actual)"
  fi
}

# Plain code with no secrets, no hardcoded paths.
run_case "clean file passes" 0 "main.go" \
  "package main
func main() { println(\"hello\") }"

# Synthetic Telegram bot token (8-12 digit prefix : 35+ url-safe chars).
# Constructed at runtime so the fixture itself doesn't contain a real-looking
# token in the test source.
SYNTH_TOKEN="$(printf '1234567890:%s' "$(printf 'A%.0s' {1..40})")"
run_case "telegram bot token blocked" 1 "leak.txt" "TOKEN=$SYNTH_TOKEN"

# Hardcoded /Users/ path — installer should use \$HOME instead.
# Built dynamically so test source stays clean for the hook itself.
HARDCODED_PATH="/Users/$(printf 'a%.0s' {1..6})/work"
run_case "hardcoded /Users path blocked" 1 "config.sh" "ROOT=$HARDCODED_PATH"

# Personal-style email blocked.
run_case "contact email blocked" 1 "AUTHORS" "$(printf 'jane%s@%s.dev' "doe" "acme")"

# Allowlisted email patterns must NOT block — example.com and GitHub noreply
# addresses are legitimate (docs, sample config, commit metadata).
run_case "example.com email allowed" 0 "CONTRIBUTING.md" "Send PRs to dev@example.com"
run_case "github noreply allowed"    0 "README.md"        "Author: 12345+contributor@users.noreply.github.com"

# Hook should skip itself even though its source contains the patterns.
SELF_CONTENT="$(cat "$HOOK")"
tmp="$(mktemp -d)"
(
  cd "$tmp"
  git init -q
  git config user.email "test@example.com"
  git config user.name  "test"
  mkdir -p scripts
  printf '%s' "$SELF_CONTENT" > scripts/check-no-secrets.sh
  git add scripts/check-no-secrets.sh
  "$HOOK" > /dev/null 2>&1
  echo "$?" > .exit
)
if [[ "$(cat "$tmp/.exit")" == "0" ]]; then
  ok "hook does not trip on its own source"
else
  ng "hook does not trip on its own source (exit=$(cat "$tmp/.exit"))"
fi
rm -rf "$tmp"

echo
echo "check-no-secrets.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
