#!/bin/bash
# Tests for `cta init` — the 5-step onboarding wizard (project-onboarding-wizard-plan).
#
# Steps are inferred from FILE STATE (the load-bearing decision in the plan):
#   1. Token present in TG plugin .env AND getMe verified
#   2. /setprivacy nudge shown (no machine signal — always shown)
#   3. First inbound seen (paired.json exists OR poller log has ≥1 inbound)
#   4. paired.json populated
#   5. Wildcard "*" mount in mounts.json
#
# We test the pure step-state helpers, the bot-token verify helper, and the
# top-level "show me where I'm at" status report. We do NOT test interactive
# I/O end-to-end (read -s + getMe network call) — those require a TTY and
# a real Telegram API. The sourceable helpers are the contract.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CTA="$SCRIPT_DIR/cli/cta"

PASS=0
FAIL=0
ok() { echo "  ok  $1";   PASS=$((PASS + 1)); }
ng() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }

# Sandbox so the live ~/.pager isn't touched.
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
export CTA_STATE_DIR="$SANDBOX/state"
export CTA_INSTALL_DIR="$SANDBOX/install"
export CTA_AGENT_DIR="$SCRIPT_DIR/agent"
export HOME="$SANDBOX/home"
mkdir -p "$CTA_STATE_DIR" "$CTA_INSTALL_DIR/agent" "$HOME/.claude/channels/telegram"

# Source cta to expose the wizard helpers without invoking main.
# shellcheck source=../cli/cta
source "$CTA"

# ─── _init_step1_token_ready ────────────────────────────────────────────────
# Token-present check is "token line in plugin .env, non-empty, matches the
# Telegram bot-token shape (digits:rest)". We do NOT call getMe here — that's
# a separate helper (_init_verify_bot_token) tested below.

# Fresh sandbox: no .env at all.
if _init_step1_token_ready; then
  ng "step1: missing plugin .env → not ready"
else
  ok "step1: missing plugin .env → not ready"
fi

# .env exists but no token line.
mkdir -p "$HOME/.claude/channels/telegram"
echo "OTHER_VAR=x" > "$HOME/.claude/channels/telegram/.env"
if _init_step1_token_ready; then
  ng "step1: .env without token line → not ready"
else
  ok "step1: .env without token line → not ready"
fi

# Token present.
echo "TELEGRAM_BOT_TOKEN=12345:ABC-DEF_ghi-jklmnopqrstuvwxyz0123456789" \
  > "$HOME/.claude/channels/telegram/.env"
if _init_step1_token_ready; then
  ok "step1: token in plugin .env → ready"
else
  ng "step1: token in plugin .env → ready"
fi

# Token line present but value empty.
echo "TELEGRAM_BOT_TOKEN=" > "$HOME/.claude/channels/telegram/.env"
if _init_step1_token_ready; then
  ng "step1: empty token value → not ready"
else
  ok "step1: empty token value → not ready"
fi

# ─── _init_validate_token_shape ─────────────────────────────────────────────
# Pre-flight regex so we don't make a getMe call for obvious garbage.
# Telegram format: <numeric bot id>:<35-ish-char base64-ish secret>.

if _init_validate_token_shape "12345:ABC-DEF_ghi-jklmnopqrstuvwxyz0123456789"; then
  ok "shape: valid token passes"
else
  ng "shape: valid token passes"
fi
if _init_validate_token_shape ""; then
  ng "shape: empty rejected"
else
  ok "shape: empty rejected"
fi
if _init_validate_token_shape "not-a-token-at-all"; then
  ng "shape: garbage rejected"
else
  ok "shape: garbage rejected"
fi
if _init_validate_token_shape "12345:tooshort"; then
  ng "shape: short secret rejected"
else
  ok "shape: short secret rejected"
fi

# ─── _init_step3_inbound_seen ───────────────────────────────────────────────
# True when paired.json exists OR agent.log has an inbound marker.
# (paired.json means we already pulled past first inbound.)

rm -f "$CTA_STATE_DIR/paired.json" "$CTA_STATE_DIR/agent.log"
if _init_step3_inbound_seen; then
  ng "step3: no paired.json + no log → not seen"
else
  ok "step3: no paired.json + no log → not seen"
fi

# Agent log with an inbound marker.
mkdir -p "$CTA_STATE_DIR"
echo '[2026-05-19T00:00:00Z] update 42 → daemon[dm] (5 chars)' \
  > "$CTA_STATE_DIR/agent.log"
if _init_step3_inbound_seen; then
  ok "step3: agent.log shows daemon dispatch → seen"
else
  ng "step3: agent.log shows daemon dispatch → seen"
fi

# Paired.json present (later signal, also passes).
rm -f "$CTA_STATE_DIR/agent.log"
echo '{"version":1,"chat_id":-1001,"user_id":42,"paired_at":"x"}' \
  > "$CTA_STATE_DIR/paired.json"
if _init_step3_inbound_seen; then
  ok "step3: paired.json exists → seen"
else
  ng "step3: paired.json exists → seen"
fi

# ─── _init_step4_paired ─────────────────────────────────────────────────────

rm -f "$CTA_STATE_DIR/paired.json"
if _init_step4_paired; then
  ng "step4: no paired.json → not paired"
else
  ok "step4: no paired.json → not paired"
fi

echo '{"version":1,"chat_id":-1001,"user_id":42,"paired_at":"x"}' \
  > "$CTA_STATE_DIR/paired.json"
if _init_step4_paired; then
  ok "step4: paired.json with chat_id → paired"
else
  ng "step4: paired.json with chat_id → paired"
fi

# Malformed (no chat_id) → not paired.
echo '{"version":1}' > "$CTA_STATE_DIR/paired.json"
if _init_step4_paired; then
  ng "step4: paired.json missing chat_id → not paired"
else
  ok "step4: paired.json missing chat_id → not paired"
fi

# ─── _init_step5_default_mount ──────────────────────────────────────────────
# True when a wildcard "*" mount exists in mounts.json.

rm -f "$CTA_STATE_DIR/mounts.json"
if _init_step5_default_mount; then
  ng "step5: no mounts.json → no default mount"
else
  ok "step5: no mounts.json → no default mount"
fi

# Mount with only a specific thread (no wildcard).
echo '{"version":2,"mounts":[{"channel":"telegram","thread_id":42,"path":"/tmp","tmux_session":"topic-42"}]}' \
  > "$CTA_STATE_DIR/mounts.json"
if _init_step5_default_mount; then
  ng "step5: only specific thread → no default mount"
else
  ok "step5: only specific thread → no default mount"
fi

# Wildcard present.
echo '{"version":2,"mounts":[{"channel":"telegram","thread_id":"*","path":"/tmp/proj","tmux_session":"topic-wild"}]}' \
  > "$CTA_STATE_DIR/mounts.json"
if _init_step5_default_mount; then
  ok "step5: wildcard mount → default mount set"
else
  ng "step5: wildcard mount → default mount set"
fi

# ─── _init_status: prints all 5 step states ─────────────────────────────────
# Used by the top of `cta init` to show "you're on step N". Output is
# machine-readable for the Pager wizard's IPC.

# Reset to a known mid-flight state: token + log inbound, no pair, no default mount.
echo "TELEGRAM_BOT_TOKEN=12345:ABC-DEF_ghi-jklmnopqrstuvwxyz0123456789" \
  > "$HOME/.claude/channels/telegram/.env"
echo '[2026-05-19T00:00:00Z] update 42 → daemon[dm] (5 chars)' \
  > "$CTA_STATE_DIR/agent.log"
rm -f "$CTA_STATE_DIR/paired.json" "$CTA_STATE_DIR/mounts.json"
OUT=$(_init_status 2>&1)

# Format: one "step <n> <done|pending>" line per step. Test parses lines.
for n in 1 2 3 4 5; do
  if ! echo "$OUT" | grep -qE "^step $n "; then
    ng "_init_status: missing 'step $n' line (got: $OUT)"
    break
  fi
done
if echo "$OUT" | grep -qE '^step [0-9]+ '; then
  ok "_init_status: prints one 'step N done|pending' line per step"
fi

# In this state: 1=done (token), 2=done (no machine signal, treat as done),
# 3=done (log inbound), 4=pending, 5=pending.
if echo "$OUT" | grep -qE '^step 1 done'; then
  ok "_init_status: step 1 reports done with token present"
else
  ng "_init_status: step 1 reports done with token present (got: $OUT)"
fi
if echo "$OUT" | grep -qE '^step 4 pending'; then
  ok "_init_status: step 4 reports pending without paired.json"
else
  ng "_init_status: step 4 reports pending without paired.json (got: $OUT)"
fi

echo
if [[ "$FAIL" -eq 0 ]]; then
  echo "✅ test_cta_init.sh: $PASS passed"
  exit 0
else
  echo "❌ test_cta_init.sh: $PASS passed, $FAIL failed"
  exit 1
fi
