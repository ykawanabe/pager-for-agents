#!/bin/bash
# Uninstaller — undoes everything install.sh did. The .env and Telegram
# secrets are backed up to ~/.pager-backup-YYYYMMDDHHMMSS/ before removal
# so you don't lose them on accident.
set -euo pipefail

CONFIG_DIR="${CTA_STATE_DIR:-$HOME/.pager}"
LEGACY_CONFIG_DIR="$HOME/.claude-telegram-agent"
BIN_DIR="$HOME/.local/bin"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST_LABEL="com.claude-agent"
PLIST_PATH="$LAUNCH_AGENTS_DIR/${PLIST_LABEL}.plist"
TELEGRAM_DIR="$HOME/.claude/channels/telegram"

say() { printf "→ %s\n" "$*"; }

BACKUP_DIR="$HOME/.pager-backup-$(date +%Y%m%d%H%M%S)"

# Respect any custom session names the user set in .env. Falls back to the
# defaults from .env.example if .env is already gone (re-running uninstall).
TMUX_SESSION_CLAUDE="claude"
TMUX_SESSION_WATCHDOG="watchdog"
if [[ -f "$CONFIG_DIR/.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$CONFIG_DIR/.env"
  set +a
fi

# ---- 1. Kill tmux sessions --------------------------------------------------
for s in "$TMUX_SESSION_CLAUDE" "$TMUX_SESSION_WATCHDOG"; do
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
for s in restart_claude.sh watch_network.sh start_agents.sh cta; do
  if [[ -f "$BIN_DIR/$s" ]]; then
    rm -f "$BIN_DIR/$s"
    say "Removed $BIN_DIR/$s"
  fi
done

# ---- 4. Back up + remove agent config dir -----------------------------------
# Sweep BOTH the current dir (~/.pager by default, or $CTA_STATE_DIR override)
# AND the legacy dir from before the rename. Leftover legacy state confuses
# subsequent installs (it's what caused the `cta pair-code` vs poller mismatch).
for dir in "$CONFIG_DIR" "$LEGACY_CONFIG_DIR"; do
  [[ -d "$dir" ]] || continue
  if [[ -f "$dir/.env" ]]; then
    mkdir -p "$BACKUP_DIR"
    cp "$dir/.env" "$BACKUP_DIR/agent$([ "$dir" = "$LEGACY_CONFIG_DIR" ] && echo "-legacy").env"
    say "Backed up $dir/.env → $BACKUP_DIR/"
  fi
  rm -rf "$dir"
  say "Removed $dir"
done

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

# ---- 6. Remove deployed runtime modules ------------------------------------
# install.sh copies the runtime into ~/.local/share/pager/ (current) — and
# ~/.local/share/claude-telegram-agent/ for upgrades from pre-rename installs.
# Safe to drop wholesale — nothing user-generated lives here, and a re-install
# re-copies everything.
for dir in "${CTA_INSTALL_DIR:-$HOME/.local/share/pager}" "$HOME/.local/share/claude-telegram-agent"; do
  [[ -d "$dir" ]] || continue
  rm -rf "$dir"
  say "Removed $dir"
done

say "Done."
