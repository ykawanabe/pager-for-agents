#!/bin/bash
# P3.12 — path encoding (cwd → ~/.claude/projects/<encoded>) regression
# guard.
#
# Background: claude-code encodes the project's cwd into a directory name
# under ~/.claude/projects/ using a string replacement rule. The poller
# mirrors that rule in agent/poller/slash-commands.ts (claudeProjectDirEncode),
# used by the JSONL resolver and the daemon's jsonlPathForSession. A mismatch
# makes the resolver miss the jsonl, pick --session-id over --resume, and
# claude crashes with "Session ID already in use" because it found the file
# via its OWN encoding.
#
# This test pins what we believe claude's rule to be against a golden
# fixture derived from real project dirs. If a claude bump changes the rule,
# this test fails and the operator updates the implementation + the fixture.
#
# (Until 2026-05-22 this also cross-checked a shell copy of the rule in
# agent/topic-wrapper.sh; that script was retired with the tmux removal, so
# slash-commands.ts is now the single source of truth.)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE="$SCRIPT_DIR/tests/fixtures/claude-path-encoding.tsv"
SLASH_TS="$SCRIPT_DIR/agent/poller/slash-commands.ts"

PASS=0
FAIL=0
ok() { echo "  ok  $1";   PASS=$((PASS + 1)); }
ng() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }

[[ -f "$FIXTURE" ]] || { ng "fixture missing: $FIXTURE"; exit 1; }
[[ -f "$SLASH_TS" ]] || { ng "slash-commands.ts missing"; exit 1; }

# The TypeScript implementation must exist and export the published shape.
if grep -q 'export function claudeProjectDirEncode' "$SLASH_TS"; then
  ok "slash-commands.ts has claudeProjectDirEncode export"
else
  ng "slash-commands.ts missing claudeProjectDirEncode export"
fi

# Encode using the TS function via bun. The eval wires the imported
# function into argv-driven output so we don't have to instantiate the
# whole module (which expects env vars / writes nothing else).
encode_via_ts() {
  local path="$1"
  bun -e "import { claudeProjectDirEncode } from '$SLASH_TS'; process.stdout.write(claudeProjectDirEncode(process.argv[1]));" "$path"
}

# ─── Fixture loop ──────────────────────────────────────────────────────────

ROW=0
MISMATCHES=0
while IFS=$'\t' read -r cwd expected; do
  # Skip comments / blanks
  [[ -z "$cwd" || "$cwd" =~ ^# ]] && continue
  ROW=$((ROW + 1))

  actual_ts=$(encode_via_ts "$cwd")

  if [[ "$actual_ts" != "$expected" ]]; then
    ng "row $ROW slash-commands.ts: '$cwd' → '$actual_ts' (expected '$expected')"
    MISMATCHES=$((MISMATCHES + 1))
  fi
done < "$FIXTURE"

if [[ "$MISMATCHES" -eq 0 && "$ROW" -gt 0 ]]; then
  ok "all $ROW fixture rows encode correctly in ts"
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
    our_encoded=$(encode_via_ts "$our_cwd")
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
