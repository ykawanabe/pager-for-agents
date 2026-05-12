#!/bin/bash
# Tests for scripts/cta.
#
# Strategy: source cta (BASH_SOURCE guard skips main), override the data-source
# helpers (_la_loaded, _claude_ps_line, etc.) with stubs, then call cmd_status
# and assert against the captured output. Pure-function helpers (_json_*) are
# tested directly.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../scripts/cta
source "$SCRIPT_DIR/scripts/cta"

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

# Simulate a user who renamed their tmux sessions in .env.
TMUX_SESSION_CLAUDE="my-bot"
TMUX_SESSION_WATCHDOG="my-watchdog"
_tmux_session_alive() { return 0; }
JSON=$(cmd_status json)
echo "$JSON" | grep -q '"name": "my-bot"'      && ok "json: respects custom claude session name"   || ng "json: respects custom claude session name"
echo "$JSON" | grep -q '"name": "my-watchdog"' && ok "json: respects custom watchdog session name" || ng "json: respects custom watchdog session name"

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

# ─── summary ─────────────────────────────────────────────────────────────────

echo
echo "cta: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
