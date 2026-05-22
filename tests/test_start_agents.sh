#!/bin/bash
# Tests for agent/start_agents.sh — the launchd entrypoint for the poller.
#
# P6c (2026-05-22): tmux removed. start_agents.sh no longer spawns detached
# sessions + pipe-pane; it does preflight, rotates the log, then `exec`s the
# poller in the foreground so launchd supervises the poller process directly.
# agent.log is fed by the exec redirect (kept at 0600 via umask). The
# destructive exec is skipped via the BASH_SOURCE guard, so we can source the
# script and assert on its helpers.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

PASS=0
FAIL=0
ok() { echo "  ok  $1";   PASS=$((PASS + 1)); }
ng() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }

# ─── umask: agent.log + future inbox/* land at 0600 ──────────────────────────
#
# agent.log mirrors the full Telegram conversation, so a 0644 mode would leak
# chat history to any other user on the Mac (and to backup tools that walk
# $HOME). Catch regressions in start_agents.sh's umask declaration by sourcing
# the script and asserting on the umask state.

ENV_FILE_FAKE=$(mktemp)
cat > "$ENV_FILE_FAKE" <<'EOF'
MAIN_CHAT_ID=123
EOF
# Trick the script's "Missing .env" guard so we can source it cleanly.
# Source in a subshell + capture umask.
RESOLVED_UMASK=$(
  HOME="$(mktemp -d)" \
  bash -c "
    mkdir -p \"\$HOME/.pager\"
    cp '$ENV_FILE_FAKE' \"\$HOME/.pager/.env\"
    source '$SCRIPT_DIR/agent/start_agents.sh' 2>/dev/null
    umask
  "
)
if [[ "$RESOLVED_UMASK" == "0077" ]]; then
  ok "start_agents.sh sets umask 077 at entry"
else
  ng "start_agents.sh expected umask 0077, got '$RESOLVED_UMASK'"
fi

# ─── rotate_logs: rotated archives also 0600 ─────────────────────────────────
#
# The mode on the renamed archive is preserved by /bin/mv, but if a prior
# install left a 0644 active log, the archive carries that mode forward.
# rotate_logs explicitly chmods the archive after rename — verify.

WORK2=$(mktemp -d)
HOME_OVERRIDE2="$WORK2"
mkdir -p "$HOME_OVERRIDE2/.pager"
cp "$ENV_FILE_FAKE" "$HOME_OVERRIDE2/.pager/.env"
# Seed an oversized active log at intentionally-loose 0644.
LARGE_LOG="$HOME_OVERRIDE2/.pager/agent.log"
dd if=/dev/zero of="$LARGE_LOG" bs=1024 count=$((11 * 1024)) 2>/dev/null
chmod 644 "$LARGE_LOG"

ROTATED_PERM=$(
  HOME="$HOME_OVERRIDE2" \
  bash -c "
    source '$SCRIPT_DIR/agent/start_agents.sh' 2>/dev/null
    rotate_logs
    stat -f %Sp \"\$HOME/.pager/\"agent.log.* 2>/dev/null | head -1
  "
)
if [[ "$ROTATED_PERM" == "-rw-------" ]]; then
  ok "rotate_logs chmods archive to 0600"
else
  ng "rotate_logs: expected 0600 on archive, got '$ROTATED_PERM'"
fi

# ─── no tmux anywhere in the script ─────────────────────────────────────────
# P6c removed tmux from the runtime entrypoint. A single tmux call would
# reintroduce the FDA prompt + the multiplexer dependency.

if grep -q '\btmux\b' "$SCRIPT_DIR/agent/start_agents.sh"; then
  ng "start_agents.sh: still references tmux ($(grep -c '\btmux\b' "$SCRIPT_DIR/agent/start_agents.sh") lines)"
else
  ok "start_agents.sh: tmux-free"
fi

# ─── execs the poller in the foreground ──────────────────────────────────────
# launchd supervision relies on start_agents.sh becoming the poller process
# (via exec), so a poller crash propagates to launchd's KeepAlive. Assert the
# script execs bun on the poller path rather than backgrounding it.

if grep -Eq 'exec bun .*poller_path|exec bun .*poller/poller\.ts' "$SCRIPT_DIR/agent/start_agents.sh"; then
  ok "start_agents.sh: execs bun on the poller (foreground, launchd-supervised)"
else
  ng "start_agents.sh: expected 'exec bun …poller.ts' in main()"
fi

# Cleanup tempfiles. mktemp -d dirs are small; let macOS reap them.
rm -f "$ENV_FILE_FAKE"

# ─── summary ─────────────────────────────────────────────────────────────────

echo
echo "start_agents.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
