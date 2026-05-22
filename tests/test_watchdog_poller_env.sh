#!/bin/bash
# P1.7 / D12 — a watchdog-triggered poller restart must propagate the FULL
# project .env to the poller, not a cherry-picked subset. Custom vars like
# PAGER_DISABLE_HELPER (operator opt-out for auto-mount) must survive a restart;
# otherwise a user who set the flag finds the helper re-enabled after one kick.
#
# P6c (2026-05-22): the watchdog no longer respawns a tmux session with a hand-
# built env. It force-restarts the launchd job (`launchctl kickstart -k
# com.claude-agent`), and launchd re-runs start_agents.sh, which sources the
# ENTIRE $STATE_DIR/.env (set -a; source …) before exec'ing the poller. So the
# D12 invariant is now guaranteed by start_agents.sh's wholesale env source.
#
# This test pins both halves of the new contract:
#   1. kick_poller_session restarts via launchctl (not a cherry-picked env).
#   2. start_agents.sh sources the full .env wholesale, so EVERY var propagates.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

PASS=0
FAIL=0
ok() { echo "  ok  $1";   PASS=$((PASS + 1)); }
ng() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }

# ─── 1. kick restarts via launchctl, carrying no per-var env ─────────────────
# shellcheck source=../agent/watch_network.sh
source "$SCRIPT_DIR/agent/watch_network.sh"

LAUNCHCTL_CALLS=()
launchctl() { LAUNCHCTL_CALLS+=("$*"); return 0; }

kick_poller_session "unit test" >/dev/null 2>&1 || true

kick_via_launchctl=0
for c in "${LAUNCHCTL_CALLS[@]:-}"; do
  case "$c" in kickstart*com.claude-agent*) kick_via_launchctl=1 ;; esac
done
if [[ "$kick_via_launchctl" -eq 1 ]]; then
  ok "kick_poller_session: restarts the poller via launchctl kickstart"
else
  ng "kick_poller_session: expected a launchctl kickstart of com.claude-agent (got '${LAUNCHCTL_CALLS[*]:-}')"
fi
unset -f launchctl

# ─── 2. start_agents.sh sources the whole .env (full propagation) ────────────
# Functional check: seed a custom var in .env, source start_agents.sh's env
# block, and confirm the var lands in the environment. This is the actual
# mechanism by which a kicked poller inherits PAGER_DISABLE_HELPER et al.

SANDBOX=$(mktemp -d)
mkdir -p "$SANDBOX/.pager" "$SANDBOX/install/agent/poller" "$SANDBOX/install/agent/mount-store"
cat > "$SANDBOX/.pager/.env" <<'EOF'
MAIN_CHAT_ID=12345
MULTI_TOPIC=1
PAGER_DISABLE_HELPER=1
EOF
touch "$SANDBOX/install/agent/poller/poller.ts" "$SANDBOX/install/agent/mount-store/mount-store.ts"

PROPAGATED=$(
  HOME="$SANDBOX" CTA_STATE_DIR="$SANDBOX/.pager" CTA_INSTALL_DIR="$SANDBOX/install" \
  bash -c "
    source '$SCRIPT_DIR/agent/start_agents.sh' 2>/dev/null
    echo \"\${PAGER_DISABLE_HELPER:-UNSET}\"
  "
)
if [[ "$PROPAGATED" == "1" ]]; then
  ok "start_agents.sh: sources full .env (custom PAGER_DISABLE_HELPER propagates)"
else
  ng "start_agents.sh: custom .env var did NOT propagate (got '$PROPAGATED') — D12 regression"
fi

# Structural guard: the env source must be a wholesale `source …/.env`, not a
# grep/cut of two cherry-picked vars (the original D12 bug shape).
if grep -Eq 'source +"\$ENV_FILE"|\. +"\$ENV_FILE"' "$SCRIPT_DIR/agent/start_agents.sh"; then
  ok "start_agents.sh: sources \$ENV_FILE wholesale (not cherry-picked)"
else
  ng "start_agents.sh: no wholesale '\$ENV_FILE' source found — vars may be cherry-picked again"
fi

rm -rf "$SANDBOX"

echo
if [[ "$FAIL" -eq 0 ]]; then
  echo "✅ test_watchdog_poller_env.sh: $PASS passed"
  exit 0
else
  echo "❌ test_watchdog_poller_env.sh: $PASS passed, $FAIL failed"
  exit 1
fi
