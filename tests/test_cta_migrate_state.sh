#!/bin/bash
# Tests for `cta migrate-state` — moves v0.1 ~/.claude-telegram-agent/ +
# ~/.local/share/claude-telegram-agent/ to the v0.2 ~/.pager/ +
# ~/.local/share/pager/ layout.
#
# Strategy: redirect $HOME to a tmpdir, build a fake legacy install layout
# inside it, run `cta migrate-state` as a subprocess, then assert on the
# resulting filesystem state.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CTA="$SCRIPT_DIR/cli/cta"

PASS=0
FAIL=0
ok() { echo "  ok  $1";   PASS=$((PASS + 1)); }
ng() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }

make_fake_home() {
  local h
  h=$(mktemp -d -t cta-migrate-XXXXXX)
  mkdir -p "$h/.claude-telegram-agent/sessions"
  mkdir -p "$h/.local/share/claude-telegram-agent/agent"
  echo "MAIN_CHAT_ID=42" > "$h/.claude-telegram-agent/.env"
  echo '{"thread_id":"42","path":"/x","tmux_session":"topic-42"}' \
    > "$h/.claude-telegram-agent/mounts.json"
  echo "fake-uuid" > "$h/.claude-telegram-agent/sessions/42"
  echo "#!/bin/bash" > "$h/.local/share/claude-telegram-agent/agent/poller.ts"
  echo "$h"
}

# ─── happy path: legacy exists, new doesn't ──────────────────────────────────

H=$(make_fake_home)
HOME="$H" "$CTA" migrate-state >/dev/null 2>&1
status=$?

[[ $status -eq 0 ]]                              && ok "happy: exits 0"                || ng "happy: exits 0 (got $status)"
[[ ! -d "$H/.claude-telegram-agent" ]]           && ok "happy: legacy state gone"      || ng "happy: legacy state gone"
[[ -d "$H/.pager" ]]                             && ok "happy: new state exists"       || ng "happy: new state exists"
[[ -f "$H/.pager/.env" ]]                        && ok "happy: .env moved"             || ng "happy: .env moved"
[[ -f "$H/.pager/mounts.json" ]]                 && ok "happy: mounts.json moved"      || ng "happy: mounts.json moved"
[[ -f "$H/.pager/sessions/42" ]]                 && ok "happy: sessions/ moved"        || ng "happy: sessions/ moved"
[[ ! -d "$H/.local/share/claude-telegram-agent" ]] && ok "happy: legacy install gone"  || ng "happy: legacy install gone"
[[ -d "$H/.local/share/pager" ]]                 && ok "happy: new install exists"     || ng "happy: new install exists"

# Manifest exists.
manifest_count=$(find "$H" -maxdepth 1 -name '.pager-migration-*.manifest' 2>/dev/null | wc -l | tr -d ' ')
[[ "$manifest_count" -eq 1 ]] && ok "happy: 1 manifest written" || ng "happy: 1 manifest written (got $manifest_count)"

rm -rf "$H"

# ─── no-op: nothing to migrate ───────────────────────────────────────────────

H=$(mktemp -d -t cta-migrate-noop-XXXXXX)
out=$(HOME="$H" "$CTA" migrate-state 2>&1)
status=$?

[[ $status -eq 0 ]]                            && ok "noop: exits 0"                || ng "noop: exits 0 (got $status)"
echo "$out" | grep -q "nothing to migrate"    && ok "noop: prints 'nothing'"      || ng "noop: prints 'nothing'"
[[ ! -d "$H/.pager" ]]                         && ok "noop: doesn't create new dir" || ng "noop: doesn't create new dir"

manifest_count=$(find "$H" -maxdepth 1 -name '.pager-migration-*.manifest' 2>/dev/null | wc -l | tr -d ' ')
[[ "$manifest_count" -eq 0 ]] && ok "noop: no manifest" || ng "noop: no manifest (got $manifest_count)"

rm -rf "$H"

# ─── collision: both old and new state exist → refuse ────────────────────────

H=$(make_fake_home)
mkdir -p "$H/.pager"
echo "preexisting" > "$H/.pager/.env"

out=$(HOME="$H" "$CTA" migrate-state 2>&1)
status=$?

[[ $status -ne 0 ]]                                && ok "collision: exits non-zero"     || ng "collision: exits non-zero (got $status)"
echo "$out" | grep -q "refusing"                  && ok "collision: prints 'refusing'"  || ng "collision: prints 'refusing'"
[[ -f "$H/.claude-telegram-agent/.env" ]]         && ok "collision: legacy untouched"   || ng "collision: legacy untouched"
[[ "$(cat "$H/.pager/.env")" == "preexisting" ]]  && ok "collision: new dir untouched"  || ng "collision: new dir untouched"

rm -rf "$H"

# ─── summary ─────────────────────────────────────────────────────────────────

echo
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]]
