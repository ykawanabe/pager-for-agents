#!/bin/bash
# Entry point — the launchd ProgramArguments for com.claude-agent.
#
# P6c (2026-05-22) rewrite: no terminal multiplexer. This script does preflight
# (env, log rotation, sanity checks) and then `exec`s the poller in the
# FOREGROUND so the launchd job *is* the poller process. launchd's KeepAlive
# (SuccessfulExit=false) respawns it on a crash; a clean `cta stop`
# (launchctl bootout) leaves it down. The network/heartbeat watchdog runs as
# its own launchd job (com.claude-watchdog → watch_network.sh) and force-
# restarts this job via `launchctl kickstart -k` if the heartbeat goes stale.
#
# The poller owns one long-lived `claude -p --input-format stream-json`
# subprocess per active topic via ClaudeDaemonRegistry — there are no per-topic
# or helper subprocesses to spawn here.
set -euo pipefail

# Tighten umask so every file created downstream (agent.log via the exec
# redirect below, log rotation archives, etc.) lands at 0600/0700 instead of
# the system default 0644/0755. agent.log carries the full chat transcript —
# a world-readable mode would expose it to other users on the Mac and to
# cloud-backup tooling that walks $HOME.
umask 077

# Defensive PATH augmentation: launchd-spawned callers (Pager via `cta start`,
# the LaunchAgent itself) inherit a stripped PATH. See cli/cta for the full
# explanation.
export PATH="$HOME/.bun/bin:/opt/homebrew/bin:/usr/local/bin:${PATH:-/usr/bin:/bin}:$HOME/.local/bin"

STATE_DIR="${CTA_STATE_DIR:-$HOME/.pager}"
INSTALL_DIR="${CTA_INSTALL_DIR:-$HOME/.local/share/pager}"
ENV_FILE="$STATE_DIR/.env"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing $ENV_FILE — run install.sh first." >&2
  exit 1
fi

set -a
# shellcheck source=/dev/null
source "$ENV_FILE"
set +a

LOG_FILE="$STATE_DIR/agent.log"
LOG_DIR="$(dirname "$LOG_FILE")"
LOG_ROTATE_MAX_BYTES=$((10 * 1024 * 1024))  # 10 MB
LOG_ARCHIVE_RETAIN_DAYS=30

# Archive the active log if it has grown past the size threshold, then prune
# archives older than $LOG_ARCHIVE_RETAIN_DAYS. We rotate at startup only:
# the live poller appends to agent.log via the exec redirect below, and the
# fresh `>>` open after this rename creates a new agent.log at 0600 (umask).
rotate_logs() {
  if [[ -f "$LOG_FILE" ]]; then
    local size
    size=$(stat -f %z "$LOG_FILE" 2>/dev/null || echo 0)
    if [[ "$size" -gt "$LOG_ROTATE_MAX_BYTES" ]]; then
      local rotated
      rotated="$LOG_FILE.$(date +%Y%m%d-%H%M%S)"
      /bin/mv -f "$LOG_FILE" "$rotated"
      chmod 600 "$rotated" 2>/dev/null || true
    fi
  fi
  find "$LOG_DIR" -maxdepth 1 -name 'agent.log.*' -type f \
    -mtime +"$LOG_ARCHIVE_RETAIN_DAYS" -delete 2>/dev/null || true
}

main() {
  rotate_logs

  # CTA_AGENT_DIR overrides the install location (used by tests). Legacy
  # CTA_SERVICES_DIR honored for back-compat with operator scripts that
  # pinned it; new code should use CTA_AGENT_DIR.
  local agent_dir="${CTA_AGENT_DIR:-${CTA_SERVICES_DIR:-$INSTALL_DIR/agent}}"
  local poller_path="$agent_dir/poller/poller.ts"
  local mount_store_path="$agent_dir/mount-store/mount-store.ts"
  for p in "$poller_path" "$mount_store_path"; do
    if [[ ! -e "$p" ]]; then
      echo "start_agents: missing $p — rerun install.sh" >&2
      exit 1
    fi
  done

  # Sanity: bot token must be reachable for the poller. Source the plugin .env
  # here so the exec'd poller inherits the canonical TELEGRAM_BOT_TOKEN (and
  # picks up rotations) alongside the project .env sourced above.
  local plugin_env="$HOME/.claude/channels/telegram/.env"
  local token=""
  if [[ -f "$plugin_env" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "$plugin_env"
    set +a
    token="${TELEGRAM_BOT_TOKEN:-}"
  fi
  if [[ -z "$token" ]]; then
    echo "TELEGRAM_BOT_TOKEN missing in $plugin_env" >&2
    exit 1
  fi

  # Pre-create the log at 0600 so the mode is locked in regardless of how the
  # `>>` redirect's open() honors umask, then become the poller. The redirect
  # reopens agent.log fresh (post-rotation) and carries the poller's stdout +
  # stderr — replacing the old pipe-pane log mirror. launchd now supervises
  # this very process: when the poller exits non-zero, KeepAlive respawns it.
  touch "$LOG_FILE"
  chmod 600 "$LOG_FILE" 2>/dev/null || true
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] start_agents: exec poller ($poller_path)" >> "$LOG_FILE"
  exec bun "$poller_path" >> "$LOG_FILE" 2>&1
}

# Sourcing (tests/test_start_agents.sh) exposes the helpers without running
# the exec. Direct execution still becomes the poller.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main
fi
