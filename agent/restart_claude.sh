#!/bin/bash
# Restart loop for the Claude Code Telegram agent.
# Runs claude with the Telegram channel plugin. If claude exits for any reason
# (crash, network drop, OOM, etc.) it sleeps briefly and starts again.
#
# Sourcing this script (BASH_SOURCE != $0) exposes helper functions without
# starting the loop — the test suite uses this to unit-test compute_next_delay.
set -uo pipefail

# Defensive PATH augmentation. `claude` is typically at ~/.local/bin/claude
# (a symlink to a per-version install); under launchd's stripped PATH neither
# the symlink dir nor /opt/homebrew/bin/bun are resolvable. See cli/cta.
export PATH="$HOME/.bun/bin:/opt/homebrew/bin:/usr/local/bin:${PATH:-/usr/bin:/bin}:$HOME/.local/bin"

# Exponential backoff defaults. A healthy run that survived ≥HEALTHY_RUN_SECS
# resets the delay to DELAY_MIN; rapid-fire crashes (config error, bad token,
# missing plugin) grow it 3 → 6 → 12 → 24 → 48 → 60s (cap). The LaunchAgent has
# KeepAlive=false, so the main_loop IS the recovery mechanism — never exit it.
# The cap keeps log volume bounded without giving up: start_agents.sh only
# rotates at boot, so a hot-loop at 3s could outpace the 10MB rotation
# threshold before the user noticed.
DELAY_MIN=3
DELAY_MAX=60
HEALTHY_RUN_SECS=30

# Default Telegram-friendly system-prompt append. The official plugin sends
# replies with parse_mode unset (`format: 'text'`, server.ts:529), so any
# Markdown claude emits is rendered literally — `**bold**` shows as two
# asterisks, `## header` as two hashes. Telling claude the rendering target
# is the cheapest way to get clean replies. Scope is this bot's claude
# process only (argv-passed, not CLAUDE.md), so the user's other claude
# sessions are untouched.
#
# Override by setting BOT_APPEND_SYSTEM_PROMPT in .env. Set to "off" to
# disable the append entirely. Empty / unset → use this default.
DEFAULT_BOT_APPEND_SYSTEM_PROMPT='You are responding through a Telegram bot. Telegram renders replies as plain text, so do NOT use Markdown syntax (no **bold**, no headers, no - bullets, no backtick code fences) — those characters appear literally. Prefer 1-3 short paragraphs over walls of text. Write code or commands on plain lines without fences. Users are typically on phones; readability beats completeness.'

# Given the previous delay and how long the last claude run lasted, compute
# the next delay. Pure arithmetic, easy to unit-test.
#   $1 = current delay (seconds)
#   $2 = ran_for (seconds the last claude invocation lasted)
#   $3 = healthy threshold (seconds; ran_for ≥ this resets the delay)
#   $4 = delay min (reset target)
#   $5 = delay max (cap)
compute_next_delay() {
  local current=$1 ran_for=$2 healthy=$3 dmin=$4 dmax=$5
  # Healthy run → start the next failure at the minimum delay, not from where
  # the ladder previously climbed.
  if [[ "$ran_for" -ge "$healthy" ]]; then
    echo "$dmin"
    return
  fi
  local next=$(( current * 2 ))
  [[ "$next" -lt "$dmin" ]] && next=$dmin
  [[ "$next" -gt "$dmax" ]] && next=$dmax
  echo "$next"
}

# Returns the right claude session flag for the given cwd + session-id pair:
# `--session-id` for first launch (no jsonl yet) so claude creates the session
# with our chosen UUID, `--resume` for every subsequent restart so it picks up
# the existing transcript. Pure path arithmetic — easy to unit-test.
#   $1 = absolute cwd (matches CLAUDE_CWD; becomes the projects/<encoded> dir)
#   $2 = session UUID
session_arg_flag() {
  local cwd="$1" uuid="$2"
  # claude encodes both `/` and `.` as `-` when naming the project dir under
  # ~/.claude/projects. Match that exactly — a `/` only translation makes
  # github.com paths miss the jsonl, fall through to --session-id, and crash
  # claude with "already in use" (it finds the file via its own encoding).
  local encoded
  encoded="${cwd//\//-}"
  encoded="${encoded//./-}"
  if [[ -f "$HOME/.claude/projects/${encoded}/${uuid}.jsonl" ]]; then
    echo "--resume"
  else
    echo "--session-id"
  fi
}

# Return the prompt text to pass to --append-system-prompt, or empty if the
# user has opted out via BOT_APPEND_SYSTEM_PROMPT=off. Empty / unset env var
# means "use the baked-in default" so existing .env files don't need editing.
#   $1 = the .env value (may be empty, "off", or a custom string)
#   $2 = the default to fall back to
resolve_append_prompt() {
  local env_val="$1" default="$2"
  if [[ "$env_val" == "off" ]]; then
    echo ""
    return
  fi
  if [[ -z "$env_val" ]]; then
    echo "$default"
    return
  fi
  echo "$env_val"
}

load_env_and_chdir() {
  local env_file="${CTA_STATE_DIR:-$HOME/.pager}/.env"
  if [[ ! -f "$env_file" ]]; then
    echo "Missing $env_file — run install.sh first." >&2
    exit 1
  fi
  set -a
  # shellcheck source=/dev/null
  source "$env_file"
  set +a
  cd "$CLAUDE_CWD" || { echo "restart_claude: cd to CLAUDE_CWD=$CLAUDE_CWD failed" >&2; exit 1; }
}

main_loop() {
  load_env_and_chdir

  # Build the claude argv. BOT_SESSION_ID is a stable UUID generated at install
  # time so the bot resumes the same conversation across restarts (Mac sleep,
  # network drops, MCP kicks). Without it, every restart wipes context.
  #
  # `--session-id <uuid>` only works for FIRST launch — once the session jsonl
  # exists under ~/.claude/projects/<cwd>/<uuid>.jsonl, claude refuses with
  # "Session ID is already in use" and exits in <1s. After a network kick or
  # any restart that finds an existing jsonl, switch to `--resume <uuid>` so
  # the conversation continues instead of crash-looping forever (we hit this
  # at 14:37 on 2026-05-12: connectivity restored → kick → endless restart
  # loop because --session-id couldn't reclaim its own ID).
  #
  # When MULTI_TOPIC ships, each topic owns its own session via a per-topic
  # .tg-session-id file and this global flag goes away. See roadmap.md.
  local args=(--channels "plugin:${TELEGRAM_PLUGIN}" --dangerously-skip-permissions)
  local append_prompt
  append_prompt=$(resolve_append_prompt "${BOT_APPEND_SYSTEM_PROMPT:-}" "$DEFAULT_BOT_APPEND_SYSTEM_PROMPT")
  if [[ -n "$append_prompt" ]]; then
    args+=(--append-system-prompt "$append_prompt")
  fi
  if [[ -n "${BOT_SESSION_ID:-}" ]]; then
    local flag
    flag=$(session_arg_flag "$CLAUDE_CWD" "$BOT_SESSION_ID")
    args+=("$flag" "$BOT_SESSION_ID")
  fi

  # Seed below MIN so the first compute_next_delay call promotes to MIN
  # rather than to MIN*2. First crash should still recover in 3s, not 6s.
  local delay=0
  while true; do
    local start_ts end_ts ran_for
    start_ts=$(date +%s)
    claude "${args[@]}" || true
    end_ts=$(date +%s)
    ran_for=$(( end_ts - start_ts ))

    delay=$(compute_next_delay "$delay" "$ran_for" "$HEALTHY_RUN_SECS" "$DELAY_MIN" "$DELAY_MAX")

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] claude exited after ${ran_for}s — restarting in ${delay}s..."
    sleep "$delay"
  done
}

# When sourced (e.g. by tests/test_restart_claude.sh) we expose the functions
# but skip the runtime loop. Direct execution still behaves identically.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main_loop
fi
