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

# ─── cmd_config idle-evict: threshold round-trip ───────────────────────────────
#
# `cta config idle-evict <min>` writes idle_evict_minutes to $STATE_DIR/settings.json
# (version 1); `0` disables; no-arg prints the current value; invalid input is
# rejected. The poller live-reloads settings.json so changes are restart-free.
# Tmp STATE_DIR/SETTINGS_FILE — no risk to the real config.

IE_TMP=$(mktemp -d)
STATE_DIR="$IE_TMP"
SETTINGS_FILE="$IE_TMP/settings.json"

# set 30 → idle_evict_minutes present + version stamped
cmd_config idle-evict 30 >/dev/null 2>&1
IE_AFTER=$(python3 -c "import json; d=json.load(open('$SETTINGS_FILE')); print(d.get('idle_evict_minutes'), d.get('version'))" 2>/dev/null)
[[ "$IE_AFTER" == "30 1" ]] \
  && ok "cmd_config idle-evict 30: writes idle_evict_minutes + version" \
  || ng "cmd_config idle-evict 30: expected '30 1', got '$IE_AFTER'"

# file written restrictively (mode 600), like the other state files
IE_MODE=$(stat -f '%Lp' "$SETTINGS_FILE" 2>/dev/null || stat -c '%a' "$SETTINGS_FILE" 2>/dev/null)
[[ "$IE_MODE" == "600" ]] \
  && ok "cmd_config idle-evict: settings.json is mode 600" \
  || ng "cmd_config idle-evict: expected mode 600, got '$IE_MODE'"

# no-arg → prints the current value
IE_SHOW=$(cmd_config idle-evict 2>/dev/null)
[[ "$IE_SHOW" == "30" ]] \
  && ok "cmd_config idle-evict (no arg): prints current value" \
  || ng "cmd_config idle-evict (no arg): expected 30, got '$IE_SHOW'"

# merge must preserve unrelated keys (mirrors the ack merge contract)
python3 -c "import json; d=json.load(open('$SETTINGS_FILE')); d['keep_me']='x'; json.dump(d, open('$SETTINGS_FILE','w'))"
cmd_config idle-evict 45 >/dev/null 2>&1
IE_KEEP=$(python3 -c "import json; d=json.load(open('$SETTINGS_FILE')); print(d.get('idle_evict_minutes'), d.get('keep_me'))" 2>/dev/null)
[[ "$IE_KEEP" == "45 x" ]] \
  && ok "cmd_config idle-evict: merge preserves unrelated keys" \
  || ng "cmd_config idle-evict: lost unrelated key (got '$IE_KEEP')"

# 0 → disables (persisted as 0, reads back 0)
cmd_config idle-evict 0 >/dev/null 2>&1
IE_OFF=$(cmd_config idle-evict 2>/dev/null)
[[ "$IE_OFF" == "0" ]] \
  && ok "cmd_config idle-evict 0: disables (reads back 0)" \
  || ng "cmd_config idle-evict 0: expected 0, got '$IE_OFF'"

# invalid → non-zero exit
cmd_config idle-evict abc >/dev/null 2>&1 && ng "cmd_config idle-evict abc: should exit non-zero" \
  || ok "cmd_config idle-evict abc: rejected with non-zero exit"

# no-arg with missing file → prints 0, no python traceback
rm -f "$SETTINGS_FILE"
IE_MISSING=$(cmd_config idle-evict 2>/dev/null)
[[ "$IE_MISSING" == "0" ]] \
  && ok "cmd_config idle-evict (no arg, missing file): prints 0" \
  || ng "cmd_config idle-evict (no arg, missing file): expected 0, got '$IE_MISSING'"
rm -rf "$IE_TMP"

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

# ─── pipefail+SIGPIPE regression guard ───────────────────────────────────────
# Under `set -uo pipefail`, the old `launchctl list | grep -q LABEL` (and
# similar ps|grep|head pipelines for _claude_ps_line / _mcp_alive) flipped
# false intermittently under I/O load: the downstream sink closes its stdin
# on first match, the upstream gets SIGPIPE, pipefail propagates non-zero,
# and Pager shows a spurious "Degraded — LaunchAgent not loaded".
#
# These tests assert the function bodies use the atomic forms (no
# `| grep -q`, no bare `| head -1` chain) so an accidental revert blows up
# CI instead of silently re-introducing the flicker. Empirical load-time
# verification (200/200 green) lives in the bug-investigation memory.

# Earlier sections override these functions with stubs, so re-source cta in a
# clean subshell and capture the real function bodies before assertions.
bodies=$(bash -c '
set -uo pipefail
source "'"$SCRIPT_DIR"'/cli/cta"
echo "===_la_loaded==="
declare -f _la_loaded
echo "===_mcp_alive==="
declare -f _mcp_alive
echo "===_claude_ps_line==="
declare -f _claude_ps_line
')

la_body="$(awk '/^===_la_loaded===/,/^===_mcp_alive===/' <<< "$bodies")"
mcp_body="$(awk '/^===_mcp_alive===/,/^===_claude_ps_line===/' <<< "$bodies")"
ps_body="$(awk '/^===_claude_ps_line===/,0' <<< "$bodies")"

if [[ "$la_body" != *"| grep -q"* ]]; then
  ok "_la_loaded: no pipefail-vulnerable grep -q pipe"
else
  ng "_la_loaded: still contains '| grep -q' (pipefail+SIGPIPE risk)"
fi
if [[ "$la_body" == *"launchctl list \"\$PLIST_LABEL\""* || "$la_body" == *"launchctl list \$PLIST_LABEL"* ]]; then
  ok "_la_loaded: uses atomic launchctl list LABEL form"
else
  ng "_la_loaded: does not use atomic launchctl list LABEL form"
fi

if [[ "$mcp_body" == *"pgrep"* && "$mcp_body" != *"| grep -v grep"* ]]; then
  ok "_mcp_alive: atomic pgrep -f form, no ps|grep|head chain"
else
  ng "_mcp_alive: not using atomic pgrep -f form"
fi

if [[ "$ps_body" == *"set +o pipefail"* ]]; then
  ok "_claude_ps_line: pipefail disabled in subshell around head -1 chain"
else
  ng "_claude_ps_line: missing 'set +o pipefail' guard around head -1 chain"
fi

# ─── _topic_name: forum topic name lookup ─────────────────────────────────────
# Topic names are cached by the poller in $STATE_DIR/topics.json from
# forum_topic_created / forum_topic_edited service messages. cta list joins
# this cache with the mount list so the user sees "Iron Flow" instead of
# bare thread_id 140. Test the helper in isolation against a fixture state dir.

topic_test_dir=$(mktemp -d)
mkdir -p "$topic_test_dir"
cat > "$topic_test_dir/paired.json" <<EOF
{"version":1,"chat_id":-1003738946626,"user_id":1,"paired_at":"2026-05-16T00:00:00Z"}
EOF
cat > "$topic_test_dir/topics.json" <<EOF
{"version":1,"topics":{"-1003738946626/140":{"name":"Iron Flow","captured_at":"2026-05-16T00:00:00Z"}}}
EOF

run_topic_name() {
  CTA_STATE_DIR="$topic_test_dir" bash -c '
    set -uo pipefail
    source "'"$SCRIPT_DIR"'/cli/cta"
    _topic_name "'"$1"'"
  '
}

[[ "$(run_topic_name 140)" == "Iron Flow" ]] \
  && ok "_topic_name: numeric thread_id with cached topic returns name" \
  || ng "_topic_name: 140 → expected 'Iron Flow', got '$(run_topic_name 140)'"

[[ -z "$(run_topic_name 999)" ]] \
  && ok "_topic_name: unknown numeric thread_id returns empty" \
  || ng "_topic_name: 999 (uncached) should return empty"

# dm in a group chat → "General" (the General topic catches no-thread_id
# messages; the fixture's chat_id is negative = group). For DMs the fixture
# would use a positive chat_id and dm would return empty — covered separately
# below.
[[ "$(run_topic_name dm)" == "General" ]] \
  && ok "_topic_name: 'dm' in group returns 'General'" \
  || ng "_topic_name: 'dm' in group should return 'General', got '$(run_topic_name dm)'"

[[ -z "$(run_topic_name '*')" ]] \
  && ok "_topic_name: wildcard '*' returns empty" \
  || ng "_topic_name: '*' should return empty"

# dm in a private chat (positive chat_id) → empty, since there's no General
# topic to label and the dm sentinel is just the chat root.
cat > "$topic_test_dir/paired.json" <<EOF
{"version":1,"chat_id":12345,"user_id":1,"paired_at":"2026-05-16T00:00:00Z"}
EOF
[[ -z "$(run_topic_name dm)" ]] \
  && ok "_topic_name: 'dm' in private chat returns empty" \
  || ng "_topic_name: 'dm' in private chat should return empty, got '$(run_topic_name dm)'"
# Restore group fixture for downstream tests
cat > "$topic_test_dir/paired.json" <<EOF
{"version":1,"chat_id":-1003738946626,"user_id":1,"paired_at":"2026-05-16T00:00:00Z"}
EOF

# Missing topics.json → graceful empty
rm -f "$topic_test_dir/topics.json"
[[ -z "$(run_topic_name 140)" ]] \
  && ok "_topic_name: missing topics.json returns empty without error" \
  || ng "_topic_name: missing topics.json should return empty"

# Missing paired.json → graceful empty (no chat_id, so no lookup key)
cat > "$topic_test_dir/topics.json" <<EOF
{"version":1,"topics":{"-1003738946626/140":{"name":"Iron Flow","captured_at":"2026-05-16T00:00:00Z"}}}
EOF
rm -f "$topic_test_dir/paired.json"
[[ -z "$(run_topic_name 140)" ]] \
  && ok "_topic_name: missing paired.json returns empty without error" \
  || ng "_topic_name: missing paired.json should return empty"

rm -rf "$topic_test_dir"

# ─── state path derivation regression guard ──────────────────────────────────
# Bug: cta hardcoded $HOME/.claude-telegram-agent/pairing-code for the pairing
# code file, while the poller (agent/lib/paths.ts) reads from
# stateDir()/pairing-code (default $HOME/.pager). Result: `cta pair-code`
# showed code A, poller checked against code B, every /pair attempt failed
# with "Pairing code did not match."
#
# Same shape failed for paired.json and mounts.json. Root cause: a legacy
# hardcode kept after state-dir migration. Class of bug, not one-off.
#
# Defense:
#   1. Top-of-file STATE_DIR block defines all state-file paths from $STATE_DIR.
#   2. This test asserts (a) the values resolve through $STATE_DIR / $INSTALL_DIR
#      and (b) no NEW legacy hardcodes have been added outside cmd_migrate_state.

state_paths_resolve_from_state_dir() {
  bash -c '
    set -uo pipefail
    source "'"$SCRIPT_DIR"'/cli/cta"
    # Each state-file path must contain $STATE_DIR (default ~/.pager) or
    # $INSTALL_DIR (default ~/.local/share/pager) when expanded.
    for var in PAIRING_CODE_FILE PAIRED_STATE_FILE MOUNTS_FILE ENV_FILE CAFFEINATE_PID_FILE; do
      val="${!var}"
      case "$val" in
        "$STATE_DIR"/*) ;;
        *) echo "FAIL: $var=$val does not start with \$STATE_DIR=$STATE_DIR"; exit 1 ;;
      esac
    done
    case "$MOUNT_STORE_TS" in
      "$INSTALL_DIR"/*) ;;
      *) echo "FAIL: MOUNT_STORE_TS=$MOUNT_STORE_TS does not start with \$INSTALL_DIR=$INSTALL_DIR"; exit 1 ;;
    esac
  '
}
if state_paths_resolve_from_state_dir; then
  ok "state paths: all resolve from \$STATE_DIR / \$INSTALL_DIR"
else
  ng "state paths: at least one hardcodes a legacy location"
fi

# Override CTA_STATE_DIR to make sure the path indirection is real (not just
# a literal "$HOME/.pager" coincidence). If any path is hardcoded, this fails.
overridden_state_dir_takes_effect() {
  CTA_STATE_DIR=/tmp/cta-test-state-$$ bash -c '
    set -uo pipefail
    source "'"$SCRIPT_DIR"'/cli/cta"
    for var in PAIRING_CODE_FILE PAIRED_STATE_FILE MOUNTS_FILE ENV_FILE CAFFEINATE_PID_FILE; do
      val="${!var}"
      case "$val" in
        /tmp/cta-test-state-*/*) ;;
        *) echo "FAIL: $var=$val ignored CTA_STATE_DIR override"; exit 1 ;;
      esac
    done
  '
}
if overridden_state_dir_takes_effect; then
  ok "state paths: respect CTA_STATE_DIR env override"
else
  ng "state paths: at least one ignores CTA_STATE_DIR (hardcoded path)"
fi

# Structural guard: grep for legacy hardcodes outside the allowlist.
# Allowed legacy refs are: LEGACY_STATE_DIR / LEGACY_INSTALL_DIR definitions
# (intentional, for migrate-state), the warning comment, and the body of
# cmd_migrate_state. Anything else is a regression.
legacy_hardcode_count() {
  # Strip cmd_migrate_state body (function-scope only)
  awk '
    /^cmd_migrate_state\(\) \{/ { in_fn=1 }
    in_fn && /^\}/ { in_fn=0; next }
    !in_fn
  ' "$SCRIPT_DIR/cli/cta" | grep -cE '\$HOME/\.(claude-telegram-agent|local/share/claude-telegram-agent)'
}
hc=$(legacy_hardcode_count)
# Expected refs OUTSIDE cmd_migrate_state:
#   - LEGACY_STATE_DIR=...        (line 49)
#   - LEGACY_INSTALL_DIR=...      (line 50)
#   - the comment that explains the bug (1 line)
if [[ "$hc" -le 3 ]]; then
  ok "legacy hardcodes outside cmd_migrate_state: $hc (allowlisted: LEGACY_*_DIR + warning comment)"
else
  ng "legacy hardcodes outside cmd_migrate_state: $hc (expected ≤3 — new hardcode? use \$STATE_DIR / \$INSTALL_DIR)"
fi

# ─── Phase 4 status semantics regression guard ───────────────────────────────
# In Phase 4 daemon mode the long-lived "always-on" process is the POLLER
# (bun), not a persistent `claude --channels` process. Status helpers must
# resolve their liveness against the poller pattern, not v0's claude grep.
#
# Source of truth: scripts/check-no-secrets.sh' style — grep the script
# itself so a refactor that drops the poller pattern breaks this test.
# Stronger than a behavioral test because there's no good way to mock
# `ps` and `pgrep` cross-platform without spawning real processes.
if grep -q 'bun .\*/agent/poller/poller\\.ts\$' "$SCRIPT_DIR/cli/cta"; then
  ok "Phase 4: _claude_ps_line + _mcp_alive use the anchored poller pattern"
else
  ng "Phase 4: poller pattern missing — Pager status flips red between turns"
fi

# Both helpers must use the SAME anchored pattern. Diverging here would
# create a "claude.pid found but telegram_mcp false" state that confuses
# the Pager status pill.
if [[ $(grep -c 'bun .\*/agent/poller/poller\\.ts\$' "$SCRIPT_DIR/cli/cta") -ge 2 ]]; then
  ok "Phase 4: claude.pid + telegram_mcp use the same poller-anchored pattern"
else
  ng "Phase 4: claude.pid + telegram_mcp diverged — Pager status will flap"
fi

# heartbeat-poller must be the last_activity source. v0 bot.pid alone
# doesn't get touched in Phase 4 (the official plugin's heartbeat — daemon
# mode never starts it), so last_activity would be null forever.
if grep -q 'heartbeat-poller' "$SCRIPT_DIR/cli/cta"; then
  ok "Phase 4: _last_activity reads from heartbeat-poller"
else
  ng "Phase 4: _last_activity still uses only bot.pid → null in daemon mode"
fi

# ─── summary ─────────────────────────────────────────────────────────────────

echo
echo "cta: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
