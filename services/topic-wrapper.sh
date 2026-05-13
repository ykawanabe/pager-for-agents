#!/bin/bash
# topic-wrapper.sh — per-topic claude launcher with restart loop.
#
# Run inside a tmux session that the start_agents.sh MULTI_TOPIC branch
# creates: `tmux new-session -d -s topic-<id> "topic-wrapper.sh <thread_id>
# <project_path> <tmux_session>"`.
#
# Responsibilities:
#   1. cd into the topic's project dir.
#   2. Pin / read the per-topic session UUID at
#      ~/.claude-telegram-agent/sessions/<thread_id>.
#   3. Build the --mcp-config JSON that wires mcp-telegram with the right
#      chat_id + thread_id pinned at spawn time (so claude itself can't
#      redirect outbound).
#   4. Run `claude --mcp-config '<json>' --strict-mcp-config --session-id
#      <uuid>` (first launch) or `--resume <uuid>` (subsequent), with the
#      Telegram-friendly --append-system-prompt.
#   5. Restart on exit with exponential backoff — same compute_next_delay
#      semantics as restart_claude.sh.
#
# Phase 1 caller signature (3 positional args):
#   $1 = thread_id        e.g. 42
#   $2 = project_path     e.g. ~/projects/iron-flow
#   $3 = tmux_session     e.g. topic-42

set -uo pipefail

# Match start_agents.sh's PATH augmentation: launchd-spawned callers (Pager
# via cta start) get a stripped PATH where neither tmux nor bun resolve.
export PATH="$HOME/.bun/bin:/opt/homebrew/bin:/usr/local/bin:${PATH:-/usr/bin:/bin}:$HOME/.local/bin"

# ─── args ────────────────────────────────────────────────────────────────────

THREAD_ID="${1:-}"
PROJECT_PATH="${2:-}"
TMUX_SESSION="${3:-}"

if [[ -z "$THREAD_ID" || -z "$PROJECT_PATH" || -z "$TMUX_SESSION" ]]; then
  echo "Usage: topic-wrapper.sh <thread_id> <project_path> <tmux_session>" >&2
  exit 1
fi
if [[ ! -d "$PROJECT_PATH" ]]; then
  echo "topic-wrapper: project_path '$PROJECT_PATH' is not a directory" >&2
  exit 1
fi

# ─── load env ────────────────────────────────────────────────────────────────

AGENT_ENV="$HOME/.claude-telegram-agent/.env"
PLUGIN_ENV="$HOME/.claude/channels/telegram/.env"

if [[ ! -f "$AGENT_ENV" ]]; then
  echo "topic-wrapper: missing $AGENT_ENV — run install.sh first." >&2
  exit 1
fi
set -a
# shellcheck source=/dev/null
source "$AGENT_ENV"
set +a

if [[ -z "${MAIN_CHAT_ID:-}" ]]; then
  echo "topic-wrapper: MAIN_CHAT_ID must be set in $AGENT_ENV" >&2
  exit 1
fi

TELEGRAM_BOT_TOKEN=""
if [[ -f "$PLUGIN_ENV" ]]; then
  # Reuse the plugin's token storage so the user keeps a single source of
  # truth. set -a would clobber unrelated vars, so grep one line out.
  TELEGRAM_BOT_TOKEN=$(grep '^TELEGRAM_BOT_TOKEN=' "$PLUGIN_ENV" | head -1 | cut -d= -f2- | sed 's/^"//; s/"$//')
fi
if [[ -z "$TELEGRAM_BOT_TOKEN" ]]; then
  echo "topic-wrapper: TELEGRAM_BOT_TOKEN missing in $PLUGIN_ENV" >&2
  exit 1
fi

# ─── per-topic session UUID ──────────────────────────────────────────────────
# Pin location: ~/.claude-telegram-agent/sessions/<thread_id>. Living outside
# the project dir means user-mounted directories that aren't git repos don't
# get random dotfiles. cta umount can delete it explicitly; cta mount creates
# it.
SESSIONS_DIR="$HOME/.claude-telegram-agent/sessions"
SESSION_FILE="$SESSIONS_DIR/$THREAD_ID"
mkdir -p "$SESSIONS_DIR"
chmod 700 "$SESSIONS_DIR" 2>/dev/null || true

if [[ ! -s "$SESSION_FILE" ]]; then
  uuidgen | tr '[:upper:]' '[:lower:]' > "$SESSION_FILE"
  chmod 600 "$SESSION_FILE" 2>/dev/null || true
fi
SESSION_UUID=$(cat "$SESSION_FILE")

# ─── --mcp-config JSON ───────────────────────────────────────────────────────
# Build the JSON that wires mcp-telegram with the right env pinned at spawn.
# We use Python (always present on macOS) to escape correctly — json.dumps
# avoids hand-quoting hell when the user's project path contains spaces or
# special characters.
REPO_BIN_DIR="${TOPIC_WRAPPER_REPO_BIN:-$HOME/.local/bin}"
MCP_SERVER_PATH="${TOPIC_WRAPPER_MCP_PATH:-$HOME/.local/share/claude-telegram-agent/services/mcp-telegram/server.ts}"

if [[ ! -f "$MCP_SERVER_PATH" ]]; then
  echo "topic-wrapper: mcp-telegram server.ts not found at $MCP_SERVER_PATH — install.sh out of date?" >&2
  exit 1
fi

MCP_CFG=$(python3 - "$MCP_SERVER_PATH" "$TELEGRAM_BOT_TOKEN" "$MAIN_CHAT_ID" "$THREAD_ID" <<'PY'
import json, sys
server_path, token, chat_id, thread_id = sys.argv[1:5]
cfg = {
    "mcpServers": {
        "telegram": {
            "command": "bun",
            "args": [server_path],
            "env": {
                "TELEGRAM_BOT_TOKEN": token,
                "TELEGRAM_CHAT_ID": chat_id,
                "TELEGRAM_THREAD_ID": thread_id,
            },
        }
    }
}
print(json.dumps(cfg))
PY
)

# ─── claude argv ─────────────────────────────────────────────────────────────

DEFAULT_BOT_APPEND_SYSTEM_PROMPT='You are responding through a Telegram bot. Telegram renders replies as plain text, so do NOT use Markdown syntax (no **bold**, no headers, no - bullets, no backtick code fences) — those characters appear literally. Prefer 1-3 short paragraphs over walls of text. Write code or commands on plain lines without fences. Users are typically on phones; readability beats completeness.

You also have access to ~/.claude-telegram-agent/shared-context.md — a cross-session memory file shared with every other Telegram-bot claude session on this host. Read it when the user references prior context, or near the start of substantive conversations. Append durable notes there (user preferences, ongoing concerns, decisions, recurring patterns) so future sessions across other topics/projects benefit. Keep entries short and avoid duplication. Do not log every interaction — only durable signal.'

resolve_append_prompt() {
  local env_val="$1" default="$2"
  if [[ "$env_val" == "off" ]]; then echo ""; return; fi
  if [[ -z "$env_val" ]]; then echo "$default"; return; fi
  echo "$env_val"
}

session_arg_flag() {
  local cwd="$1" uuid="$2"
  local encoded="${cwd//\//-}"
  if [[ -f "$HOME/.claude/projects/${encoded}/${uuid}.jsonl" ]]; then
    echo "--resume"
  else
    echo "--session-id"
  fi
}

# ─── restart loop (mirrors restart_claude.sh's compute_next_delay) ───────────

DELAY_MIN=3
DELAY_MAX=60
HEALTHY_RUN_SECS=30

compute_next_delay() {
  local current=$1 ran_for=$2 healthy=$3 dmin=$4 dmax=$5
  if [[ "$ran_for" -ge "$healthy" ]]; then echo "$dmin"; return; fi
  local next=$(( current * 2 ))
  [[ "$next" -lt "$dmin" ]] && next=$dmin
  [[ "$next" -gt "$dmax" ]] && next=$dmax
  echo "$next"
}

main_loop() {
  cd "$PROJECT_PATH"

  local append_prompt
  append_prompt=$(resolve_append_prompt "${BOT_APPEND_SYSTEM_PROMPT:-}" "$DEFAULT_BOT_APPEND_SYSTEM_PROMPT")

  local delay=0
  while true; do
    local args=(--mcp-config "$MCP_CFG" --strict-mcp-config --dangerously-skip-permissions)
    [[ -n "$append_prompt" ]] && args+=(--append-system-prompt "$append_prompt")
    local flag
    flag=$(session_arg_flag "$PROJECT_PATH" "$SESSION_UUID")
    args+=("$flag" "$SESSION_UUID")

    local start_ts end_ts ran_for
    start_ts=$(date +%s)
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] topic $THREAD_ID: claude starting in $PROJECT_PATH ($flag $SESSION_UUID)"
    claude "${args[@]}" || true
    end_ts=$(date +%s)
    ran_for=$(( end_ts - start_ts ))

    delay=$(compute_next_delay "$delay" "$ran_for" "$HEALTHY_RUN_SECS" "$DELAY_MIN" "$DELAY_MAX")
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] topic $THREAD_ID: claude exited after ${ran_for}s, restarting in ${delay}s"
    sleep "$delay"
  done
}

# Sourcing for tests exposes the helpers (compute_next_delay,
# session_arg_flag, resolve_append_prompt) without spawning claude.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main_loop
fi
