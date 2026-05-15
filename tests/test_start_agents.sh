#!/bin/bash
# Tests for agent/start_agents.sh — focused on the file-permission
# guarantees added after the 2026-05-13 security audit. The destructive tmux
# dance (kill + new-session) is skipped via the BASH_SOURCE guard.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

PASS=0
FAIL=0
ok() { echo "  ok  $1";   PASS=$((PASS + 1)); }
ng() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }

# ─── umask: agent.log + future inbox/* land at 0600 ──────────────────────────
#
# The agent.log file mirrors the full Telegram conversation via
# `tmux pipe-pane`, so a 0644 mode would leak chat history to any other user
# on the Mac (and to backup tools that walk $HOME with their own ACLs).
# Catch regressions in start_agents.sh's umask declaration by sourcing the
# script and asserting on the umask state.

ENV_FILE_FAKE=$(mktemp)
cat > "$ENV_FILE_FAKE" <<'EOF'
TMUX_SESSION_CLAUDE=test-claude
TMUX_SESSION_WATCHDOG=test-watchdog
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

# ─── pipe_to_log: pre-creates LOG_FILE at 0600 ───────────────────────────────
#
# Even if umask is somehow bypassed (caller pre-set, tmux's child shell drops
# it, etc.), pipe_to_log MUST end up with a 0600 file. Stub tmux so the
# actual pipe-pane call is a no-op; the touch + chmod path runs unchanged.

WORK=$(mktemp -d)
HOME_OVERRIDE="$WORK"
mkdir -p "$HOME_OVERRIDE/.pager"
cp "$ENV_FILE_FAKE" "$HOME_OVERRIDE/.pager/.env"

PERM=$(
  HOME="$HOME_OVERRIDE" \
  bash -c "
    # Stub tmux to a no-op so pipe-pane doesn't try to attach to a real session.
    tmux() { return 0; }
    export -f tmux
    source '$SCRIPT_DIR/agent/start_agents.sh' 2>/dev/null
    pipe_to_log dummy-session
    stat -f %Sp \"\$HOME/.pager/agent.log\"
  "
)
if [[ "$PERM" == "-rw-------" ]]; then
  ok "pipe_to_log creates agent.log at 0600"
else
  ng "pipe_to_log: expected 0600 (-rw-------), got '$PERM'"
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

# Cleanup tempfiles. mktemp -d dirs are small; let macOS reap them.
rm -f "$ENV_FILE_FAKE"

# ─── summary ─────────────────────────────────────────────────────────────────

echo
echo "start_agents.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
