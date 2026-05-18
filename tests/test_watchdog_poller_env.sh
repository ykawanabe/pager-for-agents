#!/bin/bash
# P1.7 / D12 — kick_poller_session must propagate the full project .env
# to the spawned poller, not just TELEGRAM_BOT_TOKEN + MAIN_CHAT_ID.
#
# Today only those two vars are forwarded via `-e`. Custom env vars like
# PAGER_DISABLE_HELPER (operator opt-out for auto-mount) are silently
# dropped on every watchdog kick — a user who set the flag to 1 finds
# the helper re-enabled after a single poller respawn.
#
# Test strategy: source watch_network.sh, mock tmux to capture the
# new-session call, assert the command string sources $STATE_DIR/.env
# (so all .env vars propagate, not just the two cherry-picked ones).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

export CTA_STATE_DIR="$SANDBOX/state"
export CTA_INSTALL_DIR="$SANDBOX/install"
mkdir -p "$CTA_STATE_DIR" "$CTA_INSTALL_DIR/agent/poller"

# Project .env (sourced by start_agents.sh and load_env). Custom flag we
# want to see propagated end-to-end.
cat > "$CTA_STATE_DIR/.env" <<'EOF'
MAIN_CHAT_ID=12345
MULTI_TOPIC=1
PAGER_DISABLE_HELPER=1
EOF

# Plugin .env (where kick_poller_session reads TELEGRAM_BOT_TOKEN from).
mkdir -p "$HOME/.claude/channels/telegram"  # may already exist on dev hosts
PLUGIN_ENV_BACKUP=""
if [[ -f "$HOME/.claude/channels/telegram/.env" ]]; then
  PLUGIN_ENV_BACKUP=$(mktemp)
  cp "$HOME/.claude/channels/telegram/.env" "$PLUGIN_ENV_BACKUP"
fi
echo 'TELEGRAM_BOT_TOKEN=fake-token-for-test' > "$HOME/.claude/channels/telegram/.env"
restore_plugin_env() {
  if [[ -n "$PLUGIN_ENV_BACKUP" ]]; then
    mv "$PLUGIN_ENV_BACKUP" "$HOME/.claude/channels/telegram/.env"
  else
    rm -f "$HOME/.claude/channels/telegram/.env"
  fi
}
trap 'restore_plugin_env; rm -rf "$SANDBOX"' EXIT

# Stub poller.ts so the install-dir check passes
touch "$CTA_INSTALL_DIR/agent/poller/poller.ts"

# Need MAIN_CHAT_ID in the environment too (kick_poller_session reads it
# from env directly, not from .env — it's load_env's job to set it).
export MAIN_CHAT_ID="12345"

# shellcheck source=../agent/watch_network.sh
source "$SCRIPT_DIR/agent/watch_network.sh"

# Mock tmux + sleep. Capture every call.
TMUX_CALLS=()
tmux() {
  TMUX_CALLS+=("$*")
  case "$1" in
    has-session) return 0 ;;
    *)           return 0 ;;
  esac
}
sleep() { :; }

kick_poller_session "unit test"

# Find the new-session call.
NEW_CALL=""
for c in "${TMUX_CALLS[@]}"; do
  case "$c" in
    "new-session"*) NEW_CALL="$c" ;;
  esac
done

PASS=0
FAIL=0
ok() { echo "  ok  $1";   PASS=$((PASS + 1)); }
ng() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }

if [[ -n "$NEW_CALL" ]]; then
  ok "kick_poller_session: called tmux new-session"
else
  ng "kick_poller_session: did not call tmux new-session. All calls: ${TMUX_CALLS[*]}"
fi

# The fix uses `bash -c 'set -a; . "$STATE_DIR/.env"; set +a; exec bun ...'`
# so the command string must reference both the .env file and bun. We
# check for the .env path AND for bun in the command string.

if [[ "$NEW_CALL" == *".env"* ]]; then
  ok "new-session command references .env (env-source pattern present)"
else
  ng "new-session command does NOT reference .env — env vars from \$STATE_DIR/.env are NOT propagated (D12 regression). Command: $NEW_CALL"
fi

if [[ "$NEW_CALL" == *"$CTA_STATE_DIR/.env"* ]]; then
  ok "new-session command sources \$STATE_DIR/.env specifically"
else
  ng "new-session command does NOT source \$STATE_DIR/.env. Command: $NEW_CALL"
fi

if [[ "$NEW_CALL" == *"bun"* ]] && [[ "$NEW_CALL" == *"poller.ts"* ]]; then
  ok "new-session command still runs bun + poller.ts"
else
  ng "new-session command lost bun/poller.ts invocation. Command: $NEW_CALL"
fi

echo
if [[ "$FAIL" -eq 0 ]]; then
  echo "✅ test_watchdog_poller_env.sh: $PASS passed"
  exit 0
else
  echo "❌ test_watchdog_poller_env.sh: $PASS passed, $FAIL failed"
  exit 1
fi
