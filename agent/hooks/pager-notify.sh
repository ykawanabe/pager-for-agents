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

    # Holistic notification filter:
    #
    # Claude Code fires `notification` for THREE distinct things, which the
    # generic "Claude is waiting for your input" message doesn't distinguish:
    #
    #   (a) Permission prompt — claude is BLOCKED waiting for y/n on a tool
    #       call (Bash, Write, etc.). Identified by a non-empty `tool_name`.
    #       Always notify — user MUST respond or claude stalls.
    #
    #   (b) End-of-turn idle — claude finished its response and is awaiting
    #       the user's next message. No `tool_name`. The user already saw
    #       claude's response over the Telegram channel; a separate "I'm
    #       waiting" ping is pure noise. Suppress entirely.
    #
    #   (c) Custom message — claude (or an MCP server) called the
    #       notification API with a specific message_text. Non-generic msg
    #       OR explicit tool_name → forward as-is.
    #
    # The case statement below collapses (b) into exit 0 and leaves (a)+(c)
    # falling through to the Telegram send.
    case "$msg" in
      ""|"Claude is waiting for your input"|"Claude is waiting for your input.")
        # No tool_name → end-of-turn idle (b). Suppress.
        if [[ -z "$tool_name" ]]; then
          exit 0
        fi
        # Tool present → permission prompt (a). Replace the generic text
        # with something actionable so the user knows WHY they were paged.
        msg="Permission needed for $tool_name — reply yes/no in this thread."
        ;;
    esac

    # Topic label. Multi-topic users see notifications from N topics;
    # including the human-readable name disambiguates which session is
    # waiting. Lookup order:
    #   1. topics.json — Telegram forum-topic name (from service msgs)
    #   2. mounts.json — operator-supplied label (cta mount ... <label>)
    #   3. raw thread_id — at least the user knows WHICH topic
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
      if [[ -z "$topic_label" ]]; then
        mounts_json="${CTA_STATE_DIR:-$HOME/.pager}/mounts.json"
        if [[ -f "$mounts_json" ]]; then
          topic_label=$(python3 -c "
import json
try:
    d = json.load(open('$mounts_json'))
    for m in d.get('mounts', []):
        if str(m.get('thread_id')) == '${THREAD_ID}':
            print(m.get('label') or '')
            break
except Exception:
    pass
" 2>/dev/null)
        fi
      fi
      [[ -z "$topic_label" ]] && topic_label="topic #$THREAD_ID"
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
