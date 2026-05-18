#!/bin/bash
# pager-notify.sh — Claude Code hook script for the Telegram bridge.
#
# Invoked by bot-hooks.json with one of: precompact | postcompact | notification.
# Pushes a short status message to the paired Telegram chat so the user can
# see what claude is doing during otherwise-silent windows (compaction, idle
# waits for user input, etc.).
#
# Reads:
#   - $1                                         — event tag
#   - stdin                                      — Claude Code hook JSON payload
#   - env TELEGRAM_CHAT_ID / TELEGRAM_THREAD_ID  — set by topic-wrapper.sh's
#                                                  --mcp-config; we lift them
#                                                  out of the same scope.
#   - $HOME/.claude/channels/telegram/.env       — TELEGRAM_BOT_TOKEN
#
# Silent no-op (exit 0) on any missing piece — hooks must never fail the
# session. We tolerate a slightly-out-of-sync install over a broken claude.

set -u

EVENT="${1:-unknown}"

PAYLOAD=$(cat)

TOKEN_ENV="$HOME/.claude/channels/telegram/.env"
[[ -f "$TOKEN_ENV" ]] || exit 0
# shellcheck disable=SC1090
source "$TOKEN_ENV"
TOKEN="${TELEGRAM_BOT_TOKEN:-}"
[[ -n "$TOKEN" ]] || exit 0

CHAT_ID="${TELEGRAM_CHAT_ID:-}"
THREAD_ID="${TELEGRAM_THREAD_ID:-}"
[[ -n "$CHAT_ID" ]] || exit 0

# Extract matcher/message from the JSON payload. python3 over jq because
# install.sh already requires python3 (used in topic-wrapper.sh).
extract() {
  local key=$1
  printf '%s' "$PAYLOAD" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(data.get('$key', ''))
except Exception:
    pass
" 2>/dev/null
}

case "$EVENT" in
  precompact)
    TEXT="💭 Compacting context — this may take a moment."
    ;;
  postcompact)
    TEXT="✓ Compaction done — continuing."
    ;;
  notification)
    msg=$(extract message)
    tool_name=$(extract tool_name)
    [[ -z "$msg" ]] && msg="Claude is waiting for your input — reply in this thread to continue."

    # Best-effort topic name lookup. Multi-topic users see notifications
    # from N topics; including the human-readable name disambiguates
    # which session is waiting. Falls back to no-prefix when the topic
    # isn't in topics.json yet (forum-topic-created service message
    # hasn't arrived, or this is a DM).
    topic_label=""
    if [[ -n "$THREAD_ID" && "$THREAD_ID" != "0" ]]; then
      topics_json="${CTA_STATE_DIR:-$HOME/.pager}/topics.json"
      if [[ -f "$topics_json" ]]; then
        topic_label=$(python3 -c "
import json
try:
    d = json.load(open('$topics_json'))
    print(d.get('topics', {}).get('${CHAT_ID}/${THREAD_ID}', {}).get('name', ''))
except Exception:
    pass
" 2>/dev/null)
      fi
    fi

    # Compose: [topic] [tool:Bash] message
    prefix=""
    [[ -n "$topic_label" ]] && prefix="[$topic_label] "
    [[ -n "$tool_name"   ]] && prefix="${prefix}[tool:$tool_name] "
    TEXT="🔔 ${prefix}${msg}"
    ;;
  *)
    exit 0
    ;;
esac

ARGS=(--data-urlencode "chat_id=$CHAT_ID" --data-urlencode "text=$TEXT")
if [[ -n "$THREAD_ID" && "$THREAD_ID" != "0" ]]; then
  ARGS+=(--data-urlencode "message_thread_id=$THREAD_ID")
fi

curl -sS --max-time 5 -G \
  "https://api.telegram.org/bot${TOKEN}/sendMessage" \
  "${ARGS[@]}" >/dev/null 2>&1 || true

exit 0
