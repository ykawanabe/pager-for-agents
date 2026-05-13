#!/bin/bash
# Tear down Claude Pager: stop the LaunchAgent, remove the .app bundle and plist.
set -euo pipefail

APP_BUNDLE="$HOME/Applications/Claude Pager.app"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST_LABEL="com.claude-pager"
PLIST_PATH="$LAUNCH_AGENTS_DIR/${PLIST_LABEL}.plist"

say() { printf "→ %s\n" "$*"; }

if [[ -f "$PLIST_PATH" ]]; then
  launchctl unload "$PLIST_PATH" 2>/dev/null || true
  rm -f "$PLIST_PATH"
  say "Removed $PLIST_PATH"
fi

pkill -f "Claude Pager.app/Contents/MacOS/ClaudePager" 2>/dev/null || true
pkill -f "claude-pager$" 2>/dev/null || true

if [[ -d "$APP_BUNDLE" ]]; then
  rm -rf "$APP_BUNDLE"
  say "Removed $APP_BUNDLE"
fi

# Legacy raw-binary install (pre-bundle).
if [[ -f "$HOME/.local/bin/claude-pager" ]]; then
  rm -f "$HOME/.local/bin/claude-pager"
  say "Removed legacy ~/.local/bin/claude-pager"
fi

say "Done. Logs at ~/Library/Logs/claude-pager/ preserved."
