#!/bin/bash
# Watchdog: network connectivity + MCP plugin health.
#
# Recovers from two distinct failure modes:
#   1. Network outage — kick claude session when connection returns.
#   2. Silent plugin death — claude process alive, but bun MCP server has
#      exited (we've seen this happen without taking claude itself down,
#      leaving the bot unreachable). Kick after 3 consecutive failed checks
#      (~30s) so we don't false-trigger during normal plugin startup.
#
# The loop itself never exits — failures inside the loop are caught with
# `|| true` so a single ping or tmux error can't take the watchdog down.
#
# NOTE: We intentionally do NOT enable `set -e` here because the main loop
# must survive transient errors.
set -uo pipefail

# Number of consecutive failed MCP checks before we kick the session. At a
# 10s loop interval that's ~30s of grace, which covers the plugin's cold-start
# window after `claude --channels` boots.
MCP_FAILURE_THRESHOLD=3

load_env() {
  local env_file="$HOME/.claude-telegram-agent/.env"
  if [[ ! -f "$env_file" ]]; then
    echo "Missing $env_file — run install.sh first." >&2
    exit 1
  fi
  set -a
  # shellcheck source=/dev/null
  source "$env_file"
  set +a
}

kick_claude_session() {
  local reason="$1"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $reason — restarting claude session"
  tmux kill-session -t "$TMUX_SESSION_CLAUDE" 2>/dev/null || true
  sleep 2
  tmux new-session -d -s "$TMUX_SESSION_CLAUDE" "$HOME/.local/bin/restart_claude.sh" || true
  # Re-attach pipe-pane so the recreated session's output keeps landing in
  # the activity log; otherwise the log goes silent after the first kick.
  tmux pipe-pane -t "$TMUX_SESSION_CLAUDE" -o "cat >> $HOME/.claude-telegram-agent/agent.log" || true
}

# Returns 0 (healthy) if claude isn't running yet, OR if both claude and the
# bun MCP server are running. Returns 1 (unhealthy) only when claude is alive
# but bun is missing — the silent-plugin-death state.
mcp_healthy() {
  pgrep -f "claude --channels plugin:telegram" >/dev/null || return 0
  pgrep -f "bun .*server\.ts" >/dev/null
}

main_loop() {
  load_env
  local WAS_OFFLINE=0
  local MCP_FAILS=0

  while true; do
    if ping -c 1 -W 2 "$PING_TARGET" > /dev/null 2>&1; then
      if [[ "$WAS_OFFLINE" -eq 1 ]]; then
        kick_claude_session "Network restored"
        WAS_OFFLINE=0
        MCP_FAILS=0
      else
        if mcp_healthy; then
          MCP_FAILS=0
          echo "[$(date '+%Y-%m-%d %H:%M:%S')] Online"
        else
          MCP_FAILS=$((MCP_FAILS + 1))
          echo "[$(date '+%Y-%m-%d %H:%M:%S')] Online — MCP plugin missing ($MCP_FAILS/$MCP_FAILURE_THRESHOLD)"
          if [[ "$MCP_FAILS" -ge "$MCP_FAILURE_THRESHOLD" ]]; then
            kick_claude_session "MCP plugin dead (bun server.ts gone while claude alive)"
            MCP_FAILS=0
          fi
        fi
      fi
    else
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] Offline"
      WAS_OFFLINE=1
      MCP_FAILS=0
    fi
    sleep "$PING_INTERVAL"
  done
}

# When sourced (e.g. by tests/test_watch_network.sh) we expose the functions
# but skip the runtime loop. Direct execution still behaves identically.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main_loop
fi
