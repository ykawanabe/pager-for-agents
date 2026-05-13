#!/bin/bash
# Tests for cli/cta.
#
# Strategy: source cta (BASH_SOURCE guard skips main), override the data-source
# helpers (_la_loaded, _claude_ps_line, etc.) with stubs, then call cmd_status
# and assert against the captured output. Pure-function helpers (_json_*) are
# tested directly.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../cli/cta
source "$SCRIPT_DIR/cli/cta"

PASS=0
FAIL=0
ok() { echo "  ok  $1";   PASS=$((PASS + 1)); }
ng() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }

# ─── _json_int_or_null ───────────────────────────────────────────────────────

[[ "$(_json_int_or_null "")"     == "null" ]] && ok "_json_int_or_null: empty → null"     || ng "_json_int_or_null: empty → null"
[[ "$(_json_int_or_null "0")"    == "0"    ]] && ok "_json_int_or_null: 0 → 0 (not null)" || ng "_json_int_or_null: 0 → 0 (not null)"
[[ "$(_json_int_or_null "1234")" == "1234" ]] && ok "_json_int_or_null: 1234 → 1234"      || ng "_json_int_or_null: 1234 → 1234"

# ─── _json_str_or_null ───────────────────────────────────────────────────────

[[ "$(_json_str_or_null "")"        == "null"        ]] && ok "_json_str_or_null: empty → null"            || ng "_json_str_or_null: empty → null"
[[ "$(_json_str_or_null "hello")"   == '"hello"'     ]] && ok "_json_str_or_null: hello → quoted"          || ng "_json_str_or_null: hello → quoted"
[[ "$(_json_str_or_null 'a"b')"     == '"a\"b"'      ]] && ok "_json_str_or_null: escapes double-quote"    || ng "_json_str_or_null: escapes double-quote"
[[ "$(_json_str_or_null 'a\b')"     == '"a\\b"'      ]] && ok "_json_str_or_null: escapes backslash"       || ng "_json_str_or_null: escapes backslash"

# ─── cmd_status (json) — all alive ───────────────────────────────────────────

# Stub every data source. cta's cmd_status calls these directly, so overriding
# the function is enough — no need to mock launchctl/ps/tmux/stat themselves.
_la_loaded()         { return 0; }
_claude_ps_line()    { echo "12345 524288"; }   # PID=12345, RSS=524288 KB = 512 MB
_mcp_alive()         { return 0; }
_tmux_session_alive() { return 0; }
_last_activity()     { echo "2026-05-12T10:00:00Z"; }

TMUX_SESSION_CLAUDE="claude"
TMUX_SESSION_WATCHDOG="watchdog"

JSON=$(cmd_status json)

# Validate JSON is parseable. python3 ships on macOS by default.
if echo "$JSON" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
  ok "cmd_status json: produces valid JSON"
else
  ng "cmd_status json: produces valid JSON"
  echo "---- OUTPUT ----"
  echo "$JSON"
  echo "----------------"
fi

# Spot-check key fields.
echo "$JSON" | grep -q '"schema_version": 1'              && ok "json: schema_version=1"             || ng "json: schema_version=1"
echo "$JSON" | grep -q '"pid": 12345'                     && ok "json: pid=12345"                    || ng "json: pid=12345"
echo "$JSON" | grep -q '"rss_mb": 512'                    && ok "json: rss_mb=512 (KB → MB)"         || ng "json: rss_mb=512 (KB → MB)"
echo "$JSON" | grep -q '"loaded": true'                   && ok "json: launch_agent.loaded=true"     || ng "json: launch_agent.loaded=true"
echo "$JSON" | grep -q '"telegram_mcp": {"alive": true}'  && ok "json: telegram_mcp.alive=true"      || ng "json: telegram_mcp.alive=true"
echo "$JSON" | grep -q '"last_activity": "2026-05-12T10:00:00Z"' && ok "json: last_activity present" || ng "json: last_activity present"

# ─── cmd_status (json) — everything dead ─────────────────────────────────────

_la_loaded()         { return 1; }
_claude_ps_line()    { echo ""; }
_mcp_alive()         { return 1; }
_tmux_session_alive() { return 1; }
_last_activity()     { echo ""; }

JSON=$(cmd_status json)
echo "$JSON" | python3 -c 'import json,sys; json.load(sys.stdin)' >/dev/null 2>&1 \
  && ok "cmd_status json (down): valid JSON" || ng "cmd_status json (down): valid JSON"
echo "$JSON" | grep -q '"loaded": false'      && ok "json (down): launch_agent.loaded=false" || ng "json (down): launch_agent.loaded=false"
echo "$JSON" | grep -q '"pid": null'          && ok "json (down): pid=null"                  || ng "json (down): pid=null"
echo "$JSON" | grep -q '"rss_mb": null'       && ok "json (down): rss_mb=null"               || ng "json (down): rss_mb=null"
echo "$JSON" | grep -q '"last_activity": null' && ok "json (down): last_activity=null"       || ng "json (down): last_activity=null"

# ─── tmux session name comes from .env (the dual-repo bug we fixed) ──────────

# Simulate a user who renamed their tmux sessions in .env. This covers single-
# topic v0 mode; the MULTI_TOPIC override below covers Phase-1.
MULTI_TOPIC=0
TMUX_SESSION_CLAUDE="my-bot"
TMUX_SESSION_WATCHDOG="my-watchdog"
_tmux_session_alive() { return 0; }
JSON=$(cmd_status json)
echo "$JSON" | grep -q '"name": "my-bot"'      && ok "json: respects custom claude session name"   || ng "json: respects custom claude session name"
echo "$JSON" | grep -q '"name": "my-watchdog"' && ok "json: respects custom watchdog session name" || ng "json: respects custom watchdog session name"

# MULTI_TOPIC=1: tmux.claude.name should become 'poller' regardless of
# TMUX_SESSION_CLAUDE, because the v0 control session doesn't exist in
# Phase-1 mode and Pager would otherwise report claude=✗ forever.
MULTI_TOPIC=1
JSON=$(cmd_status json)
echo "$JSON" | grep -q '"name": "poller"'      && ok "json (MULTI_TOPIC): tmux.claude → poller"  || ng "json (MULTI_TOPIC): tmux.claude → poller"
echo "$JSON" | grep -q '"name": "my-watchdog"' && ok "json (MULTI_TOPIC): watchdog name preserved" || ng "json (MULTI_TOPIC): watchdog name preserved"
MULTI_TOPIC=0

# ─── cmd_status (text) — runs without error ──────────────────────────────────

# Restore an alive state and verify text format works at all. We don't pin
# the exact text shape since it's for human eyes.
_la_loaded() { return 0; }
_claude_ps_line() { echo "999 102400"; }
TMUX_SESSION_CLAUDE="claude"
TMUX_SESSION_WATCHDOG="watchdog"

TEXT=$(cmd_status text)
echo "$TEXT" | grep -q "claude PID:.*999" && ok "cmd_status text: shows pid" || ng "cmd_status text: shows pid"
echo "$TEXT" | grep -q "MB"                && ok "cmd_status text: shows RSS in MB" || ng "cmd_status text: shows RSS in MB"

# ─── cmd_start idempotency (regression: bot kill on Pager launch) ────────────
# Regression: v0.1.0 — Pager's ensureBotRunning() calls `cta start`, which
# called start_agents.sh, which kills both tmux sessions before respawning.
# Result: every Pager launch took the live bot offline for ~3 seconds and
# churned the claude PID. Found by /qa on 2026-05-12 when Pager restarted
# during the live install and the watchdog log showed claude respawned.
#
# Contract: `cta start` is idempotent. When both sessions are alive, it
# does NOT invoke start_agents.sh. Test by stubbing the session check to
# return alive, then asserting START_SCRIPT was never called.

# Override session check to report both alive.
_tmux_session_alive() { return 0; }
# Stub launchctl so cmd_start's "load LaunchAgent" call doesn't actually run.
launchctl() { return 0; }
# Capture whether start_agents.sh would have been invoked. We override the
# variable to point at a tripwire script — if cmd_start invokes it, the
# tripwire writes a sentinel file we can grep for.
TRIPWIRE=$(mktemp)
rm -f "$TRIPWIRE"   # ensure absent before test
START_SCRIPT="/bin/bash"   # use a real executable; trick is the arg below
# Bash invocation as "start script": writes the tripwire file. If cmd_start
# invokes START_SCRIPT, the tripwire appears.
cmd_start_test() {
  # Inline replacement that records invocation. Simulates what start_agents.sh
  # would do (the destructive thing we want to prevent when already alive).
  touch "$TRIPWIRE"
}
# Redefine START_SCRIPT path to a faux executable that touches the tripwire.
# Use a here-doc to write a tiny script.
FAUX_START=$(mktemp)
cat > "$FAUX_START" <<EOF
#!/bin/bash
touch "$TRIPWIRE"
EOF
chmod +x "$FAUX_START"
START_SCRIPT="$FAUX_START"
PLIST_PATH="/nonexistent/com.claude-agent.plist"   # avoid touching real plist

cmd_start >/dev/null

if [[ -f "$TRIPWIRE" ]]; then
  ng "cmd_start (both sessions alive): MUST NOT invoke start_agents.sh"
else
  ok "cmd_start (both sessions alive): correctly skipped start_agents.sh"
fi

# Now invert: report sessions as DOWN. cmd_start MUST invoke start_agents.sh.
rm -f "$TRIPWIRE"
_tmux_session_alive() { return 1; }
cmd_start >/dev/null

if [[ -f "$TRIPWIRE" ]]; then
  ok "cmd_start (sessions down): invoked start_agents.sh as expected"
else
  ng "cmd_start (sessions down): SHOULD have invoked start_agents.sh"
fi

# Cleanup tripwire + faux scripts.
rm -f "$TRIPWIRE" "$FAUX_START"
unset -f _tmux_session_alive launchctl 2>/dev/null

# ─── cmd_stop bun cleanup (regression: orphan bun → double-poller race) ─────
# Regression: v0.1.1 — cta stop killed the tmux session but left the bun MCP
# grandchildren that the official telegram plugin spawned. They reparented to
# launchd and kept long-polling Telegram's getUpdates. The next cta start
# spawned a fresh bun → two consumers raced for getUpdates → ~half of inbound
# messages went to the orphan (no claude listening) and were silently dropped.
# Found by /qa on 2026-05-12 when the user observed "no response" after a bot
# restart cycle.
#
# Contract: cmd_stop targets ONLY the plugin's own bun processes — identified
# by `pgrep -f "claude-plugins-official.*telegram.*start"` for the wrapper,
# then `pgrep -P <wrapper-pid>` for the bun server.ts child. Never kills an
# unrelated `bun server.ts` the user might run in a different project.

# cmd_stop calls pgrep + kill inside `$(...)` subshells, so we can't capture
# their args into a parent-shell array. Use tempfiles instead — every call
# appends a line, and the parent reads the file after cmd_stop returns.
PGREP_LOG=$(mktemp)
KILL_LOG=$(mktemp)

pgrep() {
  echo "$*" >> "$PGREP_LOG"
  case "$*" in
    *"-f"*"claude-plugins-official"*) echo "1001" ;;   # wrapper PID
    *"-P 1001"*)                       echo "1002" ;;   # bun server.ts child
    *)                                  return 1 ;;     # nothing else matches
  esac
}
kill() {
  echo "$*" >> "$KILL_LOG"
  return 0
}
tmux() { return 0; }
launchctl() { return 0; }

# Plist path doesn't exist so the launchctl-unload branch's if-guard returns
# false. Same shape as a fresh install before install.sh has written the plist.
PLIST_PATH="/nonexistent/com.claude-agent.plist"

cmd_stop >/dev/null

# Were the right kills issued? Both wrapper and child should appear.
all_kills=$(cat "$KILL_LOG" 2>/dev/null | tr '\n' ' ')
if [[ "$all_kills" == *"1002"* ]]; then
  ok "cmd_stop: killed plugin bun server (PID 1002)"
else
  ng "cmd_stop: did NOT kill plugin bun server (got: $all_kills)"
fi
if [[ "$all_kills" == *"1001"* ]]; then
  ok "cmd_stop: killed plugin wrapper (PID 1001)"
else
  ng "cmd_stop: did NOT kill plugin wrapper (got: $all_kills)"
fi

# Was the plugin pattern actually searched for?
all_pgrep=$(cat "$PGREP_LOG" 2>/dev/null | tr '\n' ' ')
if [[ "$all_pgrep" == *"claude-plugins-official"* ]]; then
  ok "cmd_stop: pgrep'd for plugin-specific pattern"
else
  ng "cmd_stop: did NOT pgrep for plugin-specific pattern (got: $all_pgrep)"
fi

# Negative test: cmd_stop must NOT have searched for a generic 'bun.*server.ts'
# pattern. That would over-match user's unrelated bun projects.
if [[ "$all_pgrep" == *"bun.*server"* || "$all_pgrep" == *"bun .*server"* ]]; then
  ng "cmd_stop: SHOULD NOT pgrep for generic 'bun server.ts' (got: $all_pgrep)"
else
  ok "cmd_stop: correctly avoided generic 'bun server.ts' pattern"
fi

rm -f "$PGREP_LOG" "$KILL_LOG"
unset -f pgrep kill tmux launchctl 2>/dev/null

# ─── PATH augmentation (regression: launchd-spawned callers) ─────────────────
# Regression: v0.1.0 — Pager's diagnostic showed tmux=✗ even when sessions
# were alive. Found by /qa on 2026-05-12. Root cause: launchd strips PATH
# to /usr/bin:/bin:/usr/sbin:/sbin, and tmux lives in /opt/homebrew/bin.
# cta's `tmux has-session` call silently failed with "command not found".
# Fix: cta prepends $HOME/.bun/bin:/opt/homebrew/bin:/usr/local/bin and
# appends $HOME/.local/bin so child commands resolve under stripped PATH.
#
# Test approach: run cta in a forked shell with the launchd-stripped PATH,
# then check the script's effective PATH includes the homebrew locations.
# We don't need real tmux — just need to verify cta would find it if it
# existed in the canonical locations.

EFFECTIVE_PATH=$(env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
  bash -c "source '$SCRIPT_DIR/cli/cta' >/dev/null 2>&1; echo \$PATH")

if [[ "$EFFECTIVE_PATH" == *"/opt/homebrew/bin"* ]]; then
  ok "cta prepends /opt/homebrew/bin under stripped launchd PATH"
else
  ng "cta prepends /opt/homebrew/bin under stripped launchd PATH (got: $EFFECTIVE_PATH)"
fi

if [[ "$EFFECTIVE_PATH" == *"/usr/local/bin"* ]]; then
  ok "cta prepends /usr/local/bin under stripped launchd PATH"
else
  ng "cta prepends /usr/local/bin under stripped launchd PATH (got: $EFFECTIVE_PATH)"
fi

# When PATH is unset entirely (some launchd edge cases), the fallback
# /usr/bin:/bin must kick in so basic posix tools still resolve.
EFFECTIVE_PATH_UNSET=$(env -i HOME="$HOME" \
  bash -c "source '$SCRIPT_DIR/cli/cta' >/dev/null 2>&1; echo \$PATH")
if [[ "$EFFECTIVE_PATH_UNSET" == *"/usr/bin"* && "$EFFECTIVE_PATH_UNSET" == *"/bin"* ]]; then
  ok "cta provides /usr/bin:/bin fallback when PATH is unset"
else
  ng "cta provides /usr/bin:/bin fallback when PATH is unset (got: $EFFECTIVE_PATH_UNSET)"
fi

# ─── cmd_config ack: on/off round-trip ────────────────────────────────────────
#
# `cta config ack on` writes ackReaction=<default emoji> to access.json,
# `off` removes the key. Plugin reads access.json per request so the change is
# live without a bot restart. Test uses a tmp ACCESS_FILE — no risk of
# clobbering the real config.

CFG_TMP=$(mktemp -d)
ACCESS_FILE="$CFG_TMP/access.json"
cat > "$ACCESS_FILE" <<'EOF'
{
  "dmPolicy": "allowlist",
  "allowFrom": ["123"],
  "groups": {},
  "pending": {}
}
EOF

# on → key present with the default emoji
cmd_config ack on >/dev/null 2>&1
ACK_AFTER_ON=$(python3 -c "import json; print(json.load(open('$ACCESS_FILE')).get('ackReaction',''))" 2>/dev/null)
[[ "$ACK_AFTER_ON" == "$DEFAULT_ACK_EMOJI" ]] \
  && ok "cmd_config ack on: writes default emoji" \
  || ng "cmd_config ack on: expected $DEFAULT_ACK_EMOJI, got '$ACK_AFTER_ON'"

# on must not touch the allowlist or dmPolicy
KEEP_ALLOW=$(python3 -c "import json; print(','.join(json.load(open('$ACCESS_FILE'))['allowFrom']))" 2>/dev/null)
[[ "$KEEP_ALLOW" == "123" ]] \
  && ok "cmd_config ack on: preserves allowFrom" \
  || ng "cmd_config ack on: lost allowFrom (got '$KEEP_ALLOW')"

# off → key removed entirely (not just set to empty string)
cmd_config ack off >/dev/null 2>&1
HAS_KEY=$(python3 -c "import json; print('ackReaction' in json.load(open('$ACCESS_FILE')))" 2>/dev/null)
[[ "$HAS_KEY" == "False" ]] \
  && ok "cmd_config ack off: removes the key entirely" \
  || ng "cmd_config ack off: key still present (got '$HAS_KEY')"

# Invalid value rejected without mutating the file.
cmd_config ack maybe >/dev/null 2>&1 && ng "cmd_config ack maybe: should exit non-zero" \
  || ok "cmd_config ack maybe: rejected with non-zero exit"

# Missing access.json → helpful error, non-zero exit, no python traceback.
rm -f "$ACCESS_FILE"
ERR=$(cmd_config ack on 2>&1)
RC=$?
[[ "$RC" -ne 0 && "$ERR" == *"Missing"* ]] \
  && ok "cmd_config ack on: missing access.json reports cleanly" \
  || ng "cmd_config ack on: missing-file error (rc=$RC, msg='$ERR')"

rm -rf "$CFG_TMP"

# ─── _caffeinate_alive: PID-file liveness check ──────────────────────────────
#
# Pure liveness test. No file → not alive. File with bogus PID → not alive.
# File with our own $$ → alive (we're running, by definition).

CAFFEINATE_PID_FILE=$(mktemp -u)   # path, not file — start absent

! _caffeinate_alive && ok "_caffeinate_alive: missing file → not alive" \
                    || ng "_caffeinate_alive: missing file should be not-alive"

# Bogus PID — pick something unlikely to exist. PIDs > 99999 are
# vanishingly rare on macOS in normal sessions.
echo "999999" > "$CAFFEINATE_PID_FILE"
! _caffeinate_alive && ok "_caffeinate_alive: stale PID → not alive" \
                    || ng "_caffeinate_alive: PID 999999 should be not-alive"

# Use our own PID — guaranteed alive while this test runs.
echo "$$" > "$CAFFEINATE_PID_FILE"
_caffeinate_alive && ok "_caffeinate_alive: live PID (self) → alive" \
                  || ng "_caffeinate_alive: own PID $$ should be alive"

# Empty PID file (zero bytes) is a degenerate state we should handle, not
# crash on. A `kill -0 ""` would error noisily; the helper must treat it as
# "not alive" cleanly.
: > "$CAFFEINATE_PID_FILE"
! _caffeinate_alive && ok "_caffeinate_alive: empty file → not alive" \
                    || ng "_caffeinate_alive: empty file should be not-alive"

rm -f "$CAFFEINATE_PID_FILE"

# ─── _config_caffeinate: arg validation ──────────────────────────────────────
#
# Don't actually spawn caffeinate in the test — that would race with the
# user's real one if they have it on. Override the start/stop helpers with
# stubs that record what was called.

CAFFEINATE_CALLS=""
_caffeinate_start() { CAFFEINATE_CALLS+="start;"; }
_caffeinate_stop()  { CAFFEINATE_CALLS+="stop;";  }

CAFFEINATE_CALLS=""
_config_caffeinate on >/dev/null 2>&1
[[ "$CAFFEINATE_CALLS" == "start;" ]] \
  && ok "_config_caffeinate on: calls _caffeinate_start" \
  || ng "_config_caffeinate on: expected 'start;', got '$CAFFEINATE_CALLS'"

CAFFEINATE_CALLS=""
_config_caffeinate off >/dev/null 2>&1
[[ "$CAFFEINATE_CALLS" == "stop;" ]] \
  && ok "_config_caffeinate off: calls _caffeinate_stop" \
  || ng "_config_caffeinate off: expected 'stop;', got '$CAFFEINATE_CALLS'"

# Bad arg → non-zero exit, no spawn.
CAFFEINATE_CALLS=""
_config_caffeinate banana >/dev/null 2>&1 && ng "_config_caffeinate banana: should exit non-zero" \
                                          || ok "_config_caffeinate banana: rejected"
[[ -z "$CAFFEINATE_CALLS" ]] \
  && ok "_config_caffeinate banana: did not spawn" \
  || ng "_config_caffeinate banana: leaked a call ('$CAFFEINATE_CALLS')"

# Missing arg → usage error, non-zero exit.
CAFFEINATE_CALLS=""
_config_caffeinate "" >/dev/null 2>&1 && ng "_config_caffeinate (empty): should exit non-zero" \
                                      || ok "_config_caffeinate (empty): rejected"

# ─── cmd_status: caffeinate field exposed in JSON ────────────────────────────
#
# Re-run cmd_status with caffeinate "alive" via stubbed PID file and confirm
# the JSON output advertises it. Lock the schema contract so future Pager (or
# any other UI) can rely on the field's presence.

# Earlier blocks `unset -f _tmux_session_alive launchctl` to test the
# stripped-PATH path. Re-stub the data sources cmd_status needs so it can
# run cleanly here.
_la_loaded()          { return 0; }
_claude_ps_line()     { echo ""; }
_mcp_alive()          { return 1; }
_tmux_session_alive() { return 1; }
_last_activity()      { echo ""; }

CAFFEINATE_PID_FILE=$(mktemp)
echo "$$" > "$CAFFEINATE_PID_FILE"
JSON_CAFF=$(cmd_status json)
echo "$JSON_CAFF" | python3 -c '
import json, sys
data = json.load(sys.stdin)
caff = data["caffeinate"]
assert caff["alive"] is True, "alive should be True, got " + repr(caff)
assert isinstance(caff["pid"], int), "pid should be int, got " + repr(caff["pid"])
' \
  && ok "cmd_status json: caffeinate.alive=true exposed" \
  || ng "cmd_status json: caffeinate field missing or malformed"

rm -f "$CAFFEINATE_PID_FILE"
JSON_NOCAFF=$(cmd_status json)
echo "$JSON_NOCAFF" | python3 -c '
import json, sys
data = json.load(sys.stdin)
caff = data["caffeinate"]
assert caff["alive"] is False, "alive should be False, got " + repr(caff)
assert caff["pid"] is None, "pid should be null, got " + repr(caff["pid"])
' \
  && ok "cmd_status json: caffeinate.alive=false when no pid file" \
  || ng "cmd_status json: caffeinate=off state wrong"

# ─── summary ─────────────────────────────────────────────────────────────────

echo
echo "cta: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
