# claude-telegram-agent

Run [Claude Code](https://code.claude.com/) as a persistent Telegram agent on macOS — survives crashes, network blips, and reboots.

`install.sh` wires together three things:

1. A `tmux` session that keeps `claude` running in a `while true` loop with the official Telegram channel plugin attached.
2. A watchdog that restarts the session when the network returns after an outage **or** when the MCP plugin silently dies (claude alive, `bun server.ts` gone).
3. A `launchd` LaunchAgent so both come up automatically at login.

It also (optionally) provisions the bot token and allowlist at the canonical location the Claude Code Telegram plugin auto-discovers — so once `install.sh` finishes, the bot is live.

## Requirements

- macOS (Apple Silicon or Intel)
- `bash` (the scripts are bash, not zsh)
- [`claude`](https://code.claude.com/docs/en/getting-started) v2.1.80+ on `PATH`
- `tmux`
- `bun` (Claude Code currently requires it for plugin loading)
- A Telegram bot token from [@BotFather](https://t.me/BotFather)
- Your Telegram numeric user ID (DM [@userinfobot](https://t.me/userinfobot) to get it)

## Install

```sh
git clone https://github.com/ykawanabe/claude-telegram-agent.git
cd claude-telegram-agent
chmod +x install.sh
./install.sh
```

The installer will prompt for:

1. Claude Code working directory (default: `~/claude-home`)
2. Telegram bot token (silent input — not echoed to screen)
3. Your Telegram user ID for the allowlist (leave blank to start in `open` mode — **not recommended**)

After the LaunchAgent is loaded, send a DM to your bot from Telegram. Claude should reply within a few seconds.

## Manual setup

If you'd rather not run the installer:

```sh
# 1. Agent config
mkdir -p ~/.claude-telegram-agent
cp .env.example ~/.claude-telegram-agent/.env
$EDITOR ~/.claude-telegram-agent/.env

# 2. Scripts
mkdir -p ~/.local/bin
cp scripts/*.sh ~/.local/bin/
chmod +x ~/.local/bin/*.sh

# 3. Telegram plugin secrets (canonical location — auto-discovered by claude)
mkdir -p ~/.claude/channels/telegram
chmod 700 ~/.claude/channels/telegram
printf 'TELEGRAM_BOT_TOKEN=123456:AAxxx...\n' > ~/.claude/channels/telegram/.env
chmod 600 ~/.claude/channels/telegram/.env
cat > ~/.claude/channels/telegram/access.json <<'EOF'
{
  "dmPolicy": "allowlist",
  "allowFrom": ["YOUR_TELEGRAM_USER_ID"],
  "groups": {},
  "pending": {}
}
EOF
chmod 600 ~/.claude/channels/telegram/access.json

# 4. LaunchAgent
sed -e "s|__BIN_DIR__|$HOME/.local/bin|g" \
    -e "s|__HOME__|$HOME|g" \
    launchagent/com.claude-agent.plist.template \
    > ~/Library/LaunchAgents/com.claude-agent.plist
launchctl load ~/Library/LaunchAgents/com.claude-agent.plist
```

## Where the secrets live

| Path | What | Mode |
|---|---|---|
| `~/.claude-telegram-agent/.env` | Agent config (paths, tmux session names, ping target) | 644 |
| `~/.claude/channels/telegram/.env` | `TELEGRAM_BOT_TOKEN=...` | 600 |
| `~/.claude/channels/telegram/access.json` | Allowlist policy | 600 |
| `~/Library/LaunchAgents/com.claude-agent.plist` | LaunchAgent definition | 644 |

The Telegram plugin path is what Claude Code reads automatically when launched with `--channels plugin:telegram@claude-plugins-official`. You don't need to point it at the file — being in the canonical location is enough.

## Security — read this before you run it

`restart_claude.sh` launches Claude Code with `--dangerously-skip-permissions`. That flag means:

- **Every tool call is auto-approved.** Claude can read, write, and execute on your system without prompting.
- **Anyone who can DM the bot has the same privileges Claude has.** If your bot token leaks or your allowlist is empty, that's a remote shell.

Mandatory hardening:

1. **Set the allowlist.** `dmPolicy: "allowlist"` with your numeric Telegram user ID in `allowFrom`. The installer asks for this; don't skip it.
2. **Don't share the bot token.** It's stored at `~/.claude/channels/telegram/.env` with `chmod 600`. Don't commit it. Don't paste it into chats.
3. **Treat this Mac as the trusted machine.** Don't run the agent on a shared or unattended computer.
4. **Audit periodically.** `tail -f ~/.claude-telegram-agent/agent.log` shows what Claude is doing in real time.

If any of those bullets makes you uncomfortable, **do not run this**. Use the official `/telegram:configure` interactive flow inside Claude Code instead — it has a per-message approval mode.

## Troubleshooting

See [docs/troubleshooting.md](docs/troubleshooting.md).

Common issues:

- `claude: command not found` from the LaunchAgent — PATH issue in the plist, see troubleshooting doc.
- Messages not arriving — check the allowlist matches your Telegram user ID.
- After network outage, claude doesn't reconnect — verify both `claude` and `watchdog` tmux sessions are alive: `tmux ls`.

## Development

Run the shell test suite locally:

```sh
tests/run.sh
```

Covers `mcp_healthy`, `kick_claude_session`, and the `check-no-secrets` pre-commit hook. CI runs the same suite on every push.

## Uninstall

```sh
./uninstall.sh                  # leaves Telegram secrets in place
./uninstall.sh --purge-telegram # also removes ~/.claude/channels/telegram
```

Both modes back up `.env` files into `~/.claude-telegram-agent-backup-<timestamp>/` first.

## Acknowledgements

Architectural ideas borrowed from:

- [RichardAtCT/claude-code-telegram](https://github.com/RichardAtCT/claude-code-telegram) — Python SDK version
- [shaike1/relay](https://github.com/shaike1/relay) — multi-agent variant
- [Claude Code Channels docs](https://code.claude.com/docs/en/channels)

## License

[MIT](LICENSE)
