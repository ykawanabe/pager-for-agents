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
#      ${CTA_STATE_DIR:-~/.pager}/sessions/<thread_id>.
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
#   $4 = mode (optional)  e.g. "topic" (default) or "helper" for auto-mount

set -uo pipefail

# Match start_agents.sh's PATH augmentation: launchd-spawned callers (Pager
# via cta start) get a stripped PATH where neither tmux nor bun resolve.
export PATH="$HOME/.bun/bin:/opt/homebrew/bin:/usr/local/bin:${PATH:-/usr/bin:/bin}:$HOME/.local/bin"

# ─── args ────────────────────────────────────────────────────────────────────

THREAD_ID="${1:-}"
PROJECT_PATH="${2:-}"
TMUX_SESSION="${3:-}"
MODE="${4:-topic}"

if [[ -z "$THREAD_ID" || -z "$PROJECT_PATH" || -z "$TMUX_SESSION" ]]; then
  echo "Usage: topic-wrapper.sh <thread_id> <project_path> <tmux_session> [mode]" >&2
  exit 1
fi
if [[ "$MODE" != "topic" && "$MODE" != "helper" ]]; then
  echo "topic-wrapper: mode must be 'topic' or 'helper' (got '$MODE')" >&2
  exit 1
fi
if [[ ! -d "$PROJECT_PATH" ]]; then
  echo "topic-wrapper: project_path '$PROJECT_PATH' is not a directory" >&2
  exit 1
fi

# ─── load env ────────────────────────────────────────────────────────────────

# State + install dirs honor env overrides so tests and operator customization
# can redirect them. Defaults match agent/lib/paths.ts.
STATE_DIR="${CTA_STATE_DIR:-$HOME/.pager}"
INSTALL_DIR="${CTA_INSTALL_DIR:-$HOME/.local/share/pager}"

AGENT_ENV="$STATE_DIR/.env"
PLUGIN_ENV="$HOME/.claude/channels/telegram/.env"

if [[ ! -f "$AGENT_ENV" ]]; then
  echo "topic-wrapper: missing $AGENT_ENV — run install.sh first." >&2
  exit 1
fi
set -a
# shellcheck source=/dev/null
source "$AGENT_ENV"
set +a

# Prefer paired.json's chat_id over .env's MAIN_CHAT_ID. The .env value is
# stamped at install time and goes stale the moment the user re-pairs (e.g.
# DM → group). MCP outbound then sends replies to the dead chat and the user
# sees silence. paired.json is the live source of truth; .env is a fallback
# for unpaired / pre-Phase-3 setups.
PAIRED_FILE="$STATE_DIR/paired.json"
if [[ -f "$PAIRED_FILE" ]]; then
  PAIRED_CHAT_ID=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["chat_id"])' "$PAIRED_FILE" 2>/dev/null || true)
  if [[ -n "$PAIRED_CHAT_ID" ]]; then
    MAIN_CHAT_ID="$PAIRED_CHAT_ID"
  fi
fi

if [[ -z "${MAIN_CHAT_ID:-}" ]]; then
  echo "topic-wrapper: MAIN_CHAT_ID must be set in $AGENT_ENV (or pair via /pair)" >&2
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
# Pin location: $STATE_DIR/sessions/<thread_id>. Living outside the project
# dir means user-mounted directories that aren't git repos don't get random
# dotfiles. cta umount can delete it explicitly; cta mount creates it.
SESSIONS_DIR="$STATE_DIR/sessions"
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
MCP_SERVER_PATH="${TOPIC_WRAPPER_MCP_PATH:-$INSTALL_DIR/agent/mcp-telegram/server.ts}"

# Bot-scoped Claude Code settings file containing PreCompact / PostCompact /
# Notification hooks that push status to Telegram (so compaction and idle
# waits don't read as "bot died"). Passed via --settings so it only affects
# bot-spawned claude sessions, not the user's desktop Claude Code.
BOT_HOOKS_PATH="${TOPIC_WRAPPER_HOOKS_PATH:-$INSTALL_DIR/bot-hooks.json}"

if [[ ! -f "$MCP_SERVER_PATH" ]]; then
  echo "topic-wrapper: mcp-telegram server.ts not found at $MCP_SERVER_PATH — install.sh out of date?" >&2
  exit 1
fi

# CTA_STATE_DIR pass-through: mcp-telegram clears the poller's typing-keepalive
# marker after each reply. Both sides must resolve the same state dir or the
# bubble keeps re-firing until the hard cap. Defaults match if unset.
CTA_STATE_DIR_VAL="$STATE_DIR"

MCP_CFG=$(python3 - "$MCP_SERVER_PATH" "$TELEGRAM_BOT_TOKEN" "$MAIN_CHAT_ID" "$THREAD_ID" "$CTA_STATE_DIR_VAL" <<'PY'
import json, sys
server_path, token, chat_id, thread_id, state_dir = sys.argv[1:6]
cfg = {
    "mcpServers": {
        "telegram": {
            "command": "bun",
            "args": [server_path],
            "env": {
                "TELEGRAM_BOT_TOKEN": token,
                "TELEGRAM_CHAT_ID": chat_id,
                "TELEGRAM_THREAD_ID": thread_id,
                "CTA_STATE_DIR": state_dir,
            },
        }
    }
}
print(json.dumps(cfg))
PY
)

# ─── claude argv ─────────────────────────────────────────────────────────────

# shellcheck disable=SC2016  # backticks in this prompt are literal markdown, not command subs
DEFAULT_BOT_APPEND_SYSTEM_PROMPT='You are responding through a Telegram bot. The user is on Telegram; your terminal output is NOT visible to them. To deliver ANY reply, you MUST call the `send_telegram` MCP tool with your response text. A reply that only appears in the terminal never reaches the user.

Workflow for every user message:
  1. Read the message, do any tool work needed (file reads, code edits, etc.).
  2. Compose your reply.
  3. Call `send_telegram(text=...)` to deliver it.
You can call `send_telegram` multiple times in one turn if the response is long or progresses through phases (e.g. "looking into it" → final answer).

When you need the user to choose between a small fixed set of options (Yes/No, A/B/C, two paths forward), pass `buttons=["Option A","Option B",...]` to `send_telegram` instead of asking with prose alone. Up to 8 buttons, each ≤50 chars. The user taps one and the chosen label is dispatched back as their next message — natural turn boundary, no extra typing on mobile. Do NOT use `AskUserQuestion` over Telegram (it opens a local modal that the user cannot see or answer).

Telegram renders replies as plain text, so do NOT use Markdown syntax (no **bold**, no headers, no - bullets, no backtick code fences) — those characters appear literally. Prefer 1-3 short paragraphs over walls of text. Write code or commands on plain lines without fences. Users are typically on phones; readability beats completeness.

You also have access to ~/.pager/shared-context.md — a cross-session memory file shared with every other Pager-bot claude session on this host. Read it when the user references prior context, or near the start of substantive conversations. Append durable notes there (user preferences, ongoing concerns, decisions, recurring patterns) so future sessions across other topics/projects benefit. Keep entries short and avoid duplication. Do not log every interaction — only durable signal.

IMPORTANT — Telegram pairing / access is handled by claude-telegram-agent, NOT by the official @claude-plugins-official/telegram plugin. If the user asks about pairing, unpair, allowlist, or access changes, DO NOT invoke skills named `telegram:access`, `telegram:configure`, or anything from `@claude-plugins-official/telegram` — those describe a different system and their advice is incorrect here. Instead:
  - To unpair the current chat: tell the user to send `/unpair confirm` in the Telegram chat, OR to run `cta unpair` in their terminal.
  - To re-pair to a different chat: unpair first, then either invite the bot to a new chat (auto-pair prompt fires) or send `/pair <code>` (code visible via `cta pair-code` on the host).
  - To mount a project to a topic: `/mount <path>` inside that topic.
  - Source of truth for these mechanisms: this repository (claude-telegram-agent), specifically cli/cta and agent/poller.'

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

helper_loop() {
  # Helper mode: one-shot. cwd is $HOME (no cd into PROJECT_PATH — the helper
  # is finding the project, not running inside one). No restart loop — the
  # helper either commits a mount and gets torn down by cta mount, or exits
  # naturally on user cancel / claude turn limit.
  cd "$HOME" || { echo "topic-wrapper(helper): cd to HOME failed" >&2; exit 1; }

  export TELEGRAM_CHAT_ID="$MAIN_CHAT_ID"
  export TELEGRAM_THREAD_ID="$THREAD_ID"
  export PAGER_TOPIC_NAME="${PAGER_TOPIC_NAME:-}"

  local helper_prompt_path="$INSTALL_DIR/agent/helper-prompt.md"
  local helper_perms_path="$INSTALL_DIR/agent/helper-permissions.json"
  # Dev-mode fallback: tests and source-tree invocations point at the repo
  # directly. resolve relative to this script's directory.
  if [[ ! -f "$helper_prompt_path" ]]; then
    local self_dir; self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    helper_prompt_path="$self_dir/helper-prompt.md"
    helper_perms_path="$self_dir/helper-permissions.json"
  fi
  if [[ ! -f "$helper_prompt_path" || ! -f "$helper_perms_path" ]]; then
    echo "topic-wrapper(helper): helper-prompt.md or helper-permissions.json not found (looked in $INSTALL_DIR/agent and script dir)" >&2
    exit 1
  fi
  local append_prompt; append_prompt=$(cat "$helper_prompt_path")

  local args=(--mcp-config "$MCP_CFG" --strict-mcp-config --dangerously-skip-permissions)
  # Settings layering: bot-hooks gives us PreCompact/PostCompact/Notification
  # status pings; helper-permissions adds the deny list. claude code accepts
  # multiple --settings flags; later layers compose with earlier.
  [[ -f "$BOT_HOOKS_PATH" ]] && args+=(--settings "$BOT_HOOKS_PATH")
  args+=(--settings "$helper_perms_path")
  args+=(--append-system-prompt "$append_prompt")

  local flag
  flag=$(session_arg_flag "$HOME" "$SESSION_UUID")
  args+=("$flag" "$SESSION_UUID")

  echo "[$(date '+%Y-%m-%d %H:%M:%S')] helper for topic $THREAD_ID: claude starting in \$HOME (no restart loop)"
  claude "${args[@]}" || true
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] helper for topic $THREAD_ID: exited"
}

main_loop() {
  cd "$PROJECT_PATH" || { echo "topic-wrapper: cd to PROJECT_PATH=$PROJECT_PATH failed" >&2; exit 1; }

  # Export the chat/thread targets so claude's hook subprocesses (PreCompact /
  # PostCompact / Notification — see bot-hooks.json) can curl Bot API back to
  # the right chat. The --mcp-config "env" map only scopes to the mcp-telegram
  # process; hook scripts inherit claude's env, not the MCP server's.
  export TELEGRAM_CHAT_ID="$MAIN_CHAT_ID"
  export TELEGRAM_THREAD_ID="$THREAD_ID"

  local append_prompt
  append_prompt=$(resolve_append_prompt "${BOT_APPEND_SYSTEM_PROMPT:-}" "$DEFAULT_BOT_APPEND_SYSTEM_PROMPT")

  local delay=0
  while true; do
    local args=(--mcp-config "$MCP_CFG" --strict-mcp-config --dangerously-skip-permissions)
    [[ -f "$BOT_HOOKS_PATH" ]] && args+=(--settings "$BOT_HOOKS_PATH")
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
  if [[ "$MODE" == "helper" ]]; then
    helper_loop
  else
    main_loop
  fi
fi
