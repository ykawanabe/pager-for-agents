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
  bash -c "source '$SCRIPT_DIR/scripts/cta' >/dev/null 2>&1; echo \$PATH")

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
  bash -c "source '$SCRIPT_DIR/scripts/cta' >/dev/null 2>&1; echo \$PATH")
if [[ "$EFFECTIVE_PATH_UNSET" == *"/usr/bin"* && "$EFFECTIVE_PATH_UNSET" == *"/bin"* ]]; then
  ok "cta provides /usr/bin:/bin fallback when PATH is unset"
else
  ng "cta provides /usr/bin:/bin fallback when PATH is unset (got: $EFFECTIVE_PATH_UNSET)"
fi

# ─── summary ─────────────────────────────────────────────────────────────────

echo
echo "cta: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
