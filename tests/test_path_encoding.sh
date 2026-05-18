#!/bin/bash
# P3.12 — path encoding (cwd → ~/.claude/projects/<encoded>) regression
# guard.
#
# Background: claude-code encodes the project's cwd into a directory name
# under ~/.claude/projects/ using a string replacement rule. We mirror
# that rule in agent/restart_claude.sh and agent/topic-wrapper.sh because
# session_arg_flag needs to find the conversation transcript jsonl to
# choose between --resume and --session-id. A mismatch makes the function
# miss the jsonl, pick --session-id, and claude crashes with "Session ID
# already in use" because it found the file via its OWN encoding.
#
# This test pins what we believe claude's rule to be against a golden
# fixture derived from real project dirs. If a claude bump changes the
# rule, this test fails and the operator updates both shell encoders +
# the fixture. Catches the D13-class drift.
#
# Three checks:
#   1. agent/restart_claude.sh claude_project_dir_encode matches fixture
#   2. agent/topic-wrapper.sh   claude_project_dir_encode matches fixture
#   3. The two implementations agree on every fixture row (DRY-protect:
#      if someone fixes one and forgets the other, this fires).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE="$SCRIPT_DIR/tests/fixtures/claude-path-encoding.tsv"
RESTART="$SCRIPT_DIR/agent/restart_claude.sh"
WRAPPER="$SCRIPT_DIR/agent/topic-wrapper.sh"

PASS=0
FAIL=0
ok() { echo "  ok  $1";   PASS=$((PASS + 1)); }
ng() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }

[[ -f "$FIXTURE" ]] || { ng "fixture missing: $FIXTURE"; exit 1; }
[[ -f "$RESTART" ]] || { ng "restart_claude.sh missing"; exit 1; }
[[ -f "$WRAPPER" ]] || { ng "topic-wrapper.sh missing"; exit 1; }

# Extract just the function body from each script — sourcing the full
# script trips its top-level arg validation / .env loading. We re-execute
# the encoder via bash -c after extracting.
extract_encoder() {
  local script="$1"
  awk '
    /^claude_project_dir_encode\(\) \{/ { capturing=1 }
    capturing { print }
    capturing && /^\}/ { exit }
  ' "$script"
}

RESTART_FN=$(extract_encoder "$RESTART")
WRAPPER_FN=$(extract_encoder "$WRAPPER")

if [[ -n "$RESTART_FN" ]]; then
  ok "agent/restart_claude.sh has claude_project_dir_encode function"
else
  ng "agent/restart_claude.sh missing claude_project_dir_encode"
fi

if [[ -n "$WRAPPER_FN" ]]; then
  ok "agent/topic-wrapper.sh has claude_project_dir_encode function"
else
  ng "agent/topic-wrapper.sh missing claude_project_dir_encode"
fi

# Encode using a script's function — pass each call through bash -c with
# the function pre-defined so we exercise the actual production code.
encode_via_script() {
  local fn_body="$1" path="$2"
  bash -c "$fn_body; claude_project_dir_encode '$path'"
}

# ─── Fixture loop ──────────────────────────────────────────────────────────

ROW=0
MISMATCHES=0
while IFS=$'\t' read -r cwd expected; do
  # Skip comments / blanks
  [[ -z "$cwd" || "$cwd" =~ ^# ]] && continue
  ROW=$((ROW + 1))

  actual_restart=$(encode_via_script "$RESTART_FN" "$cwd")
  actual_wrapper=$(encode_via_script "$WRAPPER_FN" "$cwd")

  if [[ "$actual_restart" != "$expected" ]]; then
    ng "row $ROW restart_claude.sh: '$cwd' → '$actual_restart' (expected '$expected')"
    MISMATCHES=$((MISMATCHES + 1))
  fi
  if [[ "$actual_wrapper" != "$expected" ]]; then
    ng "row $ROW topic-wrapper.sh: '$cwd' → '$actual_wrapper' (expected '$expected')"
    MISMATCHES=$((MISMATCHES + 1))
  fi
  # DRY guard: the two scripts must agree even if they disagree with the
  # fixture (drift in one without the other is the worse failure mode).
  if [[ "$actual_restart" != "$actual_wrapper" ]]; then
    ng "row $ROW DRIFT: restart='$actual_restart' wrapper='$actual_wrapper'"
    MISMATCHES=$((MISMATCHES + 1))
  fi
done < "$FIXTURE"

if [[ "$MISMATCHES" -eq 0 && "$ROW" -gt 0 ]]; then
  ok "all $ROW fixture rows encode identically in both scripts"
fi

# ─── Cross-check: probe one real ~/.claude/projects entry ──────────────────
# If the user has at least one project dir on this machine, verify that
# our encoder produces a name that EXISTS under projects. Catches the
# class of bug where our rule is right per fixture but claude has changed.

if [[ -d "$HOME/.claude/projects" ]]; then
  sample_real_dir=$(ls "$HOME/.claude/projects" 2>/dev/null | head -1)
  if [[ -n "$sample_real_dir" ]]; then
    # Find a known cwd: use this repo's own location. Encode it and
    # check the encoded dir exists.
    our_cwd="$SCRIPT_DIR"
    our_encoded=$(encode_via_script "$RESTART_FN" "$our_cwd")
    if [[ -d "$HOME/.claude/projects/$our_encoded" ]]; then
      ok "live check: this repo's cwd encodes to an existing claude project dir"
    else
      # Not a hard failure — repo might never have been opened in claude.
      # But report so the operator notices.
      echo "  info: $HOME/.claude/projects/$our_encoded doesn't exist"
      echo "        (this is OK if claude has never run in $our_cwd)"
    fi
  fi
fi

echo
if [[ "$FAIL" -eq 0 ]]; then
  echo "✅ test_path_encoding.sh: $PASS passed, $ROW fixture rows verified"
  exit 0
else
  echo "❌ test_path_encoding.sh: $PASS passed, $FAIL failed"
  exit 1
fi
