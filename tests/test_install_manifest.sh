#!/bin/bash
# P3.11 / Principle 10 — install.sh manifest completeness CI gate.
#
# Catches the D2-class drift bug (a new file added under agent/ that
# wasn't wired into install.sh, silently fails in production).
#
# Three checks against agent/MANIFEST.txt:
#   1. Every non-test file under agent/ is listed in the manifest.
#   2. Every manifest entry exists in the repo (no stale listings).
#   3. Every manifest entry except `bin` is referenced in install.sh
#      (the cp commands in section 3b copy them to $INSTALL_DIR).
#
# `bin` entries are excluded from #3 because install.sh copies them in a
# loop using $REPO_DIR/agent/$s ($s = filename), not by literal name —
# matching that pattern in grep would be noise.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$SCRIPT_DIR/agent/MANIFEST.txt"
INSTALL_SH="$SCRIPT_DIR/install.sh"

PASS=0
FAIL=0
ok() { echo "  ok  $1";   PASS=$((PASS + 1)); }
ng() { echo "  FAIL $1"; FAIL=$((FAIL + 1)); }

[[ -f "$MANIFEST" ]] || { ng "manifest missing: $MANIFEST"; exit 1; }
[[ -f "$INSTALL_SH" ]] || { ng "install.sh missing: $INSTALL_SH"; exit 1; }

# Build the set of manifest entries (skip comments + blank lines).
manifest_entries() {
  awk '!/^#/ && NF >= 3 {print $1}' "$MANIFEST"
}

# Build the set of "shippable" files under agent/. Excludes:
#   - .DS_Store / dotfiles
#   - MANIFEST.txt itself
#   - node_modules / build artifacts
#   - *.test.ts (unit tests, not shipped)
#   - .gitignore'd files (bun.lock, etc. — local-only)
filesystem_entries() {
  cd "$SCRIPT_DIR"
  # `git ls-files` lists tracked files only — matches what install.sh
  # would actually copy. Falls back to find when not in a git repo (e.g.
  # someone running tests inside a stripped-down archive).
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    # Tracked files only. Excludes MANIFEST.txt itself, *.test.ts (unit
    # tests don't ship), and per-package .gitignore files (gitignored
    # children of each bun package — they're tracked for hygiene but not
    # part of the runtime install).
    git ls-files agent/ \
      | grep -v '^agent/MANIFEST\.txt$' \
      | grep -v '\.test\.ts$' \
      | grep -v '/\.gitignore$' \
      | sed 's|^agent/||' \
      | sort
  else
    find agent -type f \
      ! -name '.*' \
      ! -name 'MANIFEST.txt' \
      ! -path '*/node_modules/*' \
      ! -path '*/dist/*' \
      ! -name '*.test.ts' \
      ! -name 'bun.lock' \
      | sed 's|^agent/||' \
      | sort
  fi
}

# ─── Check 1: filesystem files all in manifest ───────────────────────────

missing_from_manifest=()
while IFS= read -r f; do
  if ! manifest_entries | grep -qxF "$f"; then
    missing_from_manifest+=("$f")
  fi
done < <(filesystem_entries)

if [[ "${#missing_from_manifest[@]}" -eq 0 ]]; then
  ok "every file under agent/ is in MANIFEST.txt"
else
  ng "files under agent/ NOT in manifest: ${missing_from_manifest[*]}"
fi

# ─── Check 2: every manifest entry exists ────────────────────────────────

stale_entries=()
while IFS= read -r e; do
  if [[ ! -f "$SCRIPT_DIR/agent/$e" ]]; then
    stale_entries+=("$e")
  fi
done < <(manifest_entries)

if [[ "${#stale_entries[@]}" -eq 0 ]]; then
  ok "every MANIFEST.txt entry has a corresponding file"
else
  ng "MANIFEST.txt entries with no file: ${stale_entries[*]}"
fi

# ─── Check 3: every non-bin manifest entry is referenced in install.sh ──

# Read entry + prefix to know which to require in install.sh.
unrefd_entries=()
while IFS=$'\t' read -r path prefix _perms; do
  [[ -z "$path" || "$path" =~ ^# ]] && continue
  [[ "$prefix" == "bin" ]] && continue  # bin loop uses $s var, not literal
  # The entry path must appear as a `$REPO_DIR/agent/<path>` substring
  # somewhere in install.sh.
  if ! grep -qF "\$REPO_DIR/agent/$path" "$INSTALL_SH"; then
    unrefd_entries+=("$path")
  fi
done < <(awk '!/^#/ && NF >= 3 {print $1"\t"$2"\t"$3}' "$MANIFEST")

if [[ "${#unrefd_entries[@]}" -eq 0 ]]; then
  ok "every non-bin manifest entry is referenced in install.sh's cp commands"
else
  ng "manifest entries NOT referenced by install.sh: ${unrefd_entries[*]}"
fi

echo
if [[ "$FAIL" -eq 0 ]]; then
  echo "✅ test_install_manifest.sh: $PASS passed"
  exit 0
else
  echo "❌ test_install_manifest.sh: $PASS passed, $FAIL failed"
  exit 1
fi
