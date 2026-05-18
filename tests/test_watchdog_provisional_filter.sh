#!/bin/bash
# P1.6 / D11 — kick_dead_topic_sessions must NOT respawn provisional rows
# (helper-mode placeholders) as topic-mode sessions. Helper lifecycle is
# owned by gcOrphanedProvisionals; the watchdog respawning a dead
# helper-<id> as a topic-mode claude in $HOME is a behavioral regression.
#
# Strategy: source watch_network.sh (BASH_SOURCE guard skips main_loop),
# point CTA_STATE_DIR / CTA_INSTALL_DIR at a sandbox with a mounts.json
# carrying one real row + one provisional row, mock tmux to report all
# sessions dead, run kick_dead_topic_sessions, assert new-session was
# called for the REAL row only.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Sandbox isolation: each invocation gets a fresh state + install dir.
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

export CTA_STATE_DIR="$SANDBOX/state"
export CTA_INSTALL_DIR="$SANDBOX/install"
mkdir -p "$CTA_STATE_DIR" "$CTA_INSTALL_DIR/agent"

# kick_dead_topic_sessions early-returns if topic-wrapper.sh is missing
# or non-executable. Place a no-op stub so the function progresses past
# that check and reaches the per-row loop we want to test.
cat > "$CTA_INSTALL_DIR/agent/topic-wrapper.sh" <<'STUB'
#!/bin/bash
exit 0
STUB
chmod +x "$CTA_INSTALL_DIR/agent/topic-wrapper.sh"

# kick_dead_topic_sessions also requires `[[ -d "$project_path" ]]` to
# pass. Create a real directory for both rows to point at.
mkdir -p "$SANDBOX/proj"

cat > "$CTA_STATE_DIR/mounts.json" <<EOF
{
  "version": 2,
  "mounts": [
    {
      "channel": "telegram",
      "thread_id": 42,
      "path": "$SANDBOX/proj",
      "tmux_session": "topic-42",
      "session_id": "u1",
      "created_at": "2026-05-18T00:00:00Z"
    },
    {
      "channel": "telegram",
      "thread_id": 99,
      "path": "$SANDBOX/proj",
      "tmux_session": "helper-99",
      "session_id": "u2",
      "created_at": "2026-05-18T00:00:00Z",
      "provisional": true
    }
  ]
}
EOF

# shellcheck source=../agent/watch_network.sh
source "$SCRIPT_DIR/agent/watch_network.sh"

# Mock tmux + sleep. Capture every call; report has-session as dead
# (the situation the function is designed to recover from).
TMUX_CALLS=()
tmux() {
  TMUX_CALLS+=("$*")
  case "$1" in
    has-session) return 1 ;;  # all sessions dead
    *)           return 0 ;;
  esac
}
sleep() { :; }

kick_dead_topic_sessions

# Tally new-session calls.
NEW_CALLS=()
for c in "${TMUX_CALLS[@]}"; do
  case "$c" in
    "new-session"*) NEW_CALLS+=("$c") ;;
  esac
done

PASS=0
FAIL=0
ok() { echo "  ok  $1"; PASS=$((PASS + 1)); }
ng() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }

# Real (non-provisional) row should respawn.
real_count=0
for c in "${NEW_CALLS[@]}"; do
  [[ "$c" == *"topic-42"* ]] && real_count=$((real_count + 1))
done
if [[ "$real_count" -eq 1 ]]; then
  ok "non-provisional row (topic-42) respawned"
else
  ng "expected 1 new-session for topic-42, got $real_count (calls: ${NEW_CALLS[*]})"
fi

# Provisional row must NOT respawn — that's the bug we're closing.
prov_count=0
for c in "${NEW_CALLS[@]}"; do
  [[ "$c" == *"helper-99"* ]] && prov_count=$((prov_count + 1))
done
if [[ "$prov_count" -eq 0 ]]; then
  ok "provisional row (helper-99) skipped"
else
  ng "provisional row was respawned $prov_count time(s) — D11 regression (calls: ${NEW_CALLS[*]})"
fi

# Total new-session count: exactly 1 (the non-provisional row).
if [[ "${#NEW_CALLS[@]}" -eq 1 ]]; then
  ok "exactly 1 respawn fired (no provisional leak)"
else
  ng "expected 1 total new-session, got ${#NEW_CALLS[@]}: ${NEW_CALLS[*]}"
fi

echo
echo "watchdog_provisional_filter.sh: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
