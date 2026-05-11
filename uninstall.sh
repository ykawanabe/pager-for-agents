#!/bin/bash
# Uninstaller — undoes everything install.sh did. The .env and Telegram
# secrets are backed up to ~/.claude-telegram-agent-backup-YYYYMMDDHHMMSS/
# before removal so you don't lose them on accident.
set -euo pipefail

CONFIG_DIR="$HOME/.claude-telegram-agent"
BIN_DIR="$HOME/.local/bin"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST_LABEL="com.claude-agent"
PLIST_PATH="$LAUNCH_AGENTS_DIR/${PLIST_LABEL}.plist"
TELEGRAM_DIR="$HOME/.claude/channels/telegram"

say() { printf "→ %s\n" "$*"; }

BACKUP_DIR="$HOME/.claude-telegram-agent-backup-$(date +%Y%m%d%H%M%S)"

# ---- 1. Kill tmux sessions --------------------------------------------------
for s in claude watchdog; do
  if tmux has-session -t "$s" 2>/dev/null; then
    tmux kill-session -t "$s"
    say "Killed tmux session: $s"
  fi
done

# ---- 2. Unload + remove LaunchAgent ----------------------------------------
if [[ -f "$PLIST_PATH" ]]; then
  launchctl unload "$PLIST_PATH" 2>/dev/null || true
  rm -f "$PLIST_PATH"
  say "Removed $PLIST_PATH"
fi

# ---- 3. Remove scripts ------------------------------------------------------
for s in restart_claude.sh watch_network.sh start_agents.sh; do
  if [[ -f "$BIN_DIR/$s" ]]; then
    rm -f "$BIN_DIR/$s"
    say "Removed $BIN_DIR/$s"
  fi
done

# ---- 4. Back up + remove agent config dir -----------------------------------
if [[ -d "$CONFIG_DIR" ]]; then
  if [[ -f "$CONFIG_DIR/.env" ]]; then
    mkdir -p "$BACKUP_DIR"
    cp "$CONFIG_DIR/.env" "$BACKUP_DIR/agent.env"
    say "Backed up agent .env → $BACKUP_DIR/agent.env"
  fi
  rm -rf "$CONFIG_DIR"
  say "Removed $CONFIG_DIR"
fi

# ---- 5. Telegram secrets: opt-in removal -----------------------------------
# The plugin secrets live in ~/.claude/ and may be shared with other Claude
# Code setups, so we DON'T remove them by default. Pass --purge-telegram to
# also wipe the bot token and access.json.
if [[ "${1:-}" == "--purge-telegram" ]]; then
  if [[ -d "$TELEGRAM_DIR" ]]; then
    mkdir -p "$BACKUP_DIR/telegram"
    cp -a "$TELEGRAM_DIR/." "$BACKUP_DIR/telegram/" 2>/dev/null || true
    say "Backed up Telegram secrets → $BACKUP_DIR/telegram/"
    rm -rf "$TELEGRAM_DIR"
    say "Removed $TELEGRAM_DIR"
  fi
else
  say "Telegram secrets at $TELEGRAM_DIR preserved (pass --purge-telegram to remove)"
fi

say "Done."
