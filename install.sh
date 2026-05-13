#!/bin/bash
# Interactive installer for claude-telegram-agent on macOS.
#
# Copies scripts into ~/.local/bin, writes ~/.claude-telegram-agent/.env,
# registers a LaunchAgent to start everything at login, and (optionally)
# provisions the Claude Code Telegram plugin secrets at the canonical
# location the plugin reads from automatically:
#
#   ~/.claude/channels/telegram/.env         (TELEGRAM_BOT_TOKEN=...)
#   ~/.claude/channels/telegram/access.json  (allowlist policy)
#
# That path is auto-discovered when claude is launched with
# `--channels plugin:telegram@claude-plugins-official`, so no extra wiring
# is needed.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$HOME/.claude-telegram-agent"
BIN_DIR="$HOME/.local/bin"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST_LABEL="com.claude-agent"
PLIST_PATH="$LAUNCH_AGENTS_DIR/${PLIST_LABEL}.plist"

# Canonical path the Claude Code Telegram plugin reads from.
TELEGRAM_DIR="$HOME/.claude/channels/telegram"
TELEGRAM_ENV="$TELEGRAM_DIR/.env"
TELEGRAM_ACCESS="$TELEGRAM_DIR/access.json"

say() { printf "→ %s\n" "$*"; }
die() { printf "✗ %s\n" "$*" >&2; exit 1; }

# ---- 1. Dependency check ----------------------------------------------------
say "Checking dependencies"

require() {
  local cmd="$1" hint="$2"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    die "Missing dependency: $cmd
  Install: $hint"
  fi
}

require claude "npm install -g @anthropic-ai/claude-code  (or use bun/pnpm)"
require tmux   "brew install tmux"
require bun    "brew install oven-sh/bun/bun  (or curl -fsSL https://bun.sh/install | bash)"
require jq     "brew install jq"

CLAUDE_VERSION="$(claude --version 2>/dev/null || echo unknown)"
say "Detected claude: $CLAUDE_VERSION"

# ---- 2. Write agent .env ----------------------------------------------------
mkdir -p "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"

if [[ -f "$CONFIG_DIR/.env" ]]; then
  say ".env already exists at $CONFIG_DIR/.env — leaving it alone"
else
  # umask 077 so the cp lands at 0600 — matches the plugin's .env at
  # ~/.claude/channels/telegram/.env. The agent .env holds CLAUDE_CWD (a
  # path that reveals project location) and BOT_SESSION_ID; not as
  # devastating as a token leak, but no reason to ship it world-readable.
  (umask 077 && cp "$REPO_DIR/.env.example" "$CONFIG_DIR/.env")

  default_cwd="$HOME/claude-home"
  printf "\nEnter the Claude Code working directory [%s]: " "$default_cwd"
  read -r CLAUDE_CWD_INPUT
  CLAUDE_CWD_INPUT="${CLAUDE_CWD_INPUT:-$default_cwd}"

  # Escape sed-replacement metacharacters in the user-supplied path so a
  # directory containing '|', '&', or '\' doesn't corrupt the .env line.
  esc_cwd=$(printf '%s' "$CLAUDE_CWD_INPUT" | sed -e 's/[\\&|]/\\&/g')
  sed -i '' "s|^CLAUDE_CWD=.*|CLAUDE_CWD=${esc_cwd}|" "$CONFIG_DIR/.env"
  say "Wrote $CONFIG_DIR/.env (CLAUDE_CWD=$CLAUDE_CWD_INPUT)"
fi

# Generate a stable session UUID if one isn't already present. With it,
# `restart_claude.sh` passes `--session-id $BOT_SESSION_ID` so the bot resumes
# the same Claude Code conversation across restarts (sleep, crash, kick).
# Without it, every restart wipes context — bad UX for a chat bot.
# This is a v0 patch; multi-topic mode replaces it with per-topic sessions.
if ! grep -q '^BOT_SESSION_ID=..*' "$CONFIG_DIR/.env" 2>/dev/null; then
  bot_uuid=$(uuidgen | tr '[:upper:]' '[:lower:]')
  printf '\nBOT_SESSION_ID=%s\n' "$bot_uuid" >> "$CONFIG_DIR/.env"
  say "Generated BOT_SESSION_ID=$bot_uuid for conversation persistence"
fi

# Always clamp .env to 0600. Catches pre-existing installs that ran before
# we tightened the cp umask, and re-asserts on every run as cheap insurance.
chmod 600 "$CONFIG_DIR/.env" 2>/dev/null || true

# ---- 3. Install scripts -----------------------------------------------------
mkdir -p "$BIN_DIR"
for s in restart_claude.sh watch_network.sh start_agents.sh cta; do
  cp "$REPO_DIR/scripts/$s" "$BIN_DIR/$s"
  chmod +x "$BIN_DIR/$s"
  say "Installed $BIN_DIR/$s"
done

# ---- 3b. Install F1+F2 services (MULTI_TOPIC mode) --------------------------
# Layout: ~/.local/share/claude-telegram-agent/services/{poller,mcp-telegram,
# topic-wrapper.sh}. Honors XDG-ish convention (executables in ~/.local/bin,
# data/code in ~/.local/share). Services stay opt-in via MULTI_TOPIC=1 in
# .env, so installing them on a v0 host is a no-op until the user flips that
# flag. start_agents.sh's MULTI_TOPIC branch refuses to start if these
# files are missing, so install/uninstall stay symmetric.
SERVICES_DIR="$HOME/.local/share/claude-telegram-agent/services"
if [[ -d "$REPO_DIR/services" ]]; then
  mkdir -p "$SERVICES_DIR/poller" "$SERVICES_DIR/mcp-telegram" "$SERVICES_DIR/mount-store"
  cp "$REPO_DIR/services/poller/poller.ts" "$REPO_DIR/services/poller/package.json" "$SERVICES_DIR/poller/"
  cp "$REPO_DIR/services/mcp-telegram/server.ts" "$REPO_DIR/services/mcp-telegram/package.json" "$SERVICES_DIR/mcp-telegram/"
  cp "$REPO_DIR/services/mount-store/mount-store.ts" "$REPO_DIR/services/mount-store/bind-helper.ts" "$REPO_DIR/services/mount-store/package.json" "$SERVICES_DIR/mount-store/"
  cp "$REPO_DIR/services/topic-wrapper.sh" "$SERVICES_DIR/topic-wrapper.sh"
  chmod +x "$SERVICES_DIR/topic-wrapper.sh"

  # Resolve mcp-telegram's runtime deps (the SDK). Poller has no deps but
  # `bun install` is a cheap no-op there. If bun is missing, warn and skip
  # — the v0 path still works; only MULTI_TOPIC=1 needs bun-resolved deps.
  if command -v bun >/dev/null 2>&1; then
    ( cd "$SERVICES_DIR/mcp-telegram" && bun install --silent ) || say "WARN: bun install failed in mcp-telegram"
    say "Installed services under $SERVICES_DIR"
  else
    say "WARN: bun not found on PATH — F1+F2 MULTI_TOPIC mode will not start until bun is installed"
  fi
fi

# ---- 3c. Install bind-telegram-topic skill (Phase 2) -----------------------
# Ships a Claude Code slash command that wraps `cta bind`. Installed into the
# user's global skills dir so it's available from any project. Don't clobber
# user edits — `diff` and skip if changed.
SKILLS_SRC="$REPO_DIR/skills/bind-telegram-topic"
SKILLS_DST="$HOME/.claude/skills/bind-telegram-topic"
if [[ -d "$SKILLS_SRC" ]]; then
  mkdir -p "$SKILLS_DST"
  if [[ -f "$SKILLS_DST/SKILL.md" ]] && ! cmp -s "$SKILLS_SRC/SKILL.md" "$SKILLS_DST/SKILL.md"; then
    say "Skill bind-telegram-topic has local edits at $SKILLS_DST/SKILL.md — leaving alone"
  else
    cp "$SKILLS_SRC/SKILL.md" "$SKILLS_DST/SKILL.md"
    say "Installed skill bind-telegram-topic"
  fi
fi

# ---- 4. Provision Telegram plugin secrets (optional) -----------------------
mkdir -p "$TELEGRAM_DIR"
chmod 700 "$TELEGRAM_DIR"

# Bot token
if [[ -f "$TELEGRAM_ENV" ]] && grep -q '^TELEGRAM_BOT_TOKEN=..*' "$TELEGRAM_ENV"; then
  say "Telegram bot token already present at $TELEGRAM_ENV — skipping"
else
  printf "\nTelegram bot token (from @BotFather), or blank to skip: "
  # -s = silent (don't echo), -r = no backslash processing
  IFS= read -rs TOKEN
  printf "\n"

  if [[ -z "${TOKEN:-}" ]]; then
    # Drop a commented stub so the user can find where to put the token later.
    umask 077
    cat > "$TELEGRAM_ENV" <<'EOF'
# Paste your Telegram bot token from @BotFather on the line below.
# TELEGRAM_BOT_TOKEN=123456789:AA...
EOF
    chmod 600 "$TELEGRAM_ENV"
    say "Token skipped — stub written to $TELEGRAM_ENV (edit when ready)"
  else
    # Sanity: Telegram bot tokens are 8-12 digits, a colon, and 35+ url-safe
    # chars. Same shape check-no-secrets.sh enforces; keep them in sync so a
    # typo can't slip past the installer and then trip the commit hook later.
    if [[ ! "$TOKEN" =~ ^[0-9]{8,12}:[A-Za-z0-9_-]{35,}$ ]]; then
      printf "⚠  Token does not match expected Telegram format — saving anyway\n"
    fi
    umask 077
    printf "TELEGRAM_BOT_TOKEN=%s\n" "$TOKEN" > "$TELEGRAM_ENV"
    chmod 600 "$TELEGRAM_ENV"
    # Mask all but the last 4 characters when echoing back for confirmation.
    masked="****${TOKEN: -4}"
    say "Wrote $TELEGRAM_ENV ($masked, mode 600)"
  fi
fi

# Allowlist
if [[ -f "$TELEGRAM_ACCESS" ]]; then
  say "Telegram access.json already present at $TELEGRAM_ACCESS — skipping"
else
  printf "\nYour Telegram user ID (numeric), or blank to leave the channel open: "
  read -r ALLOW_ID

  if [[ -z "${ALLOW_ID:-}" ]]; then
    printf "⚠  No allowlist configured. ANYONE who finds the bot can DM Claude.\n"
    printf '   Strongly recommend: set ALLOWED_USERS later in %s.\n' "$TELEGRAM_ACCESS"
    cat > "$TELEGRAM_ACCESS" <<'EOF'
{
  "dmPolicy": "open",
  "allowFrom": [],
  "groups": {},
  "pending": {}
}
EOF
  else
    if [[ ! "$ALLOW_ID" =~ ^[0-9]+$ ]]; then
      die "Telegram user ID must be numeric (got: $ALLOW_ID)"
    fi
    cat > "$TELEGRAM_ACCESS" <<EOF
{
  "dmPolicy": "allowlist",
  "allowFrom": [
    "$ALLOW_ID"
  ],
  "groups": {},
  "pending": {}
}
EOF
    say "Wrote $TELEGRAM_ACCESS (allowlist: $ALLOW_ID)"
  fi
  chmod 600 "$TELEGRAM_ACCESS"
fi

# ---- 5. Generate and load LaunchAgent ---------------------------------------
mkdir -p "$LAUNCH_AGENTS_DIR"
sed -e "s|__BIN_DIR__|$BIN_DIR|g" \
    -e "s|__HOME__|$HOME|g" \
    "$REPO_DIR/launchagent/com.claude-agent.plist.template" > "$PLIST_PATH"
say "Wrote $PLIST_PATH"

launchctl unload "$PLIST_PATH" 2>/dev/null || true
launchctl load "$PLIST_PATH"
say "Loaded LaunchAgent $PLIST_LABEL"

# ---- 6. Done ----------------------------------------------------------------
cat <<EOF

✓ Installed.

Next steps:
  1. Verify both tmux sessions are running:  tmux ls
  2. Tail the agent log:                     tail -f $CONFIG_DIR/agent.log
  3. Send a DM to your bot from Telegram — Claude should reply.

Telegram secrets live at $TELEGRAM_DIR (mode 700).
The Claude Code Telegram plugin auto-discovers them when claude is launched
with --channels plugin:telegram@claude-plugins-official (handled by the
agent's restart loop).

Security: this agent runs claude with --dangerously-skip-permissions.
Make sure the allowlist is set BEFORE sending anything sensitive. See README.
EOF
