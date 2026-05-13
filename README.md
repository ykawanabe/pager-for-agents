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
./install.sh                  # interactive: also offers to install Pager
# or:
./install.sh --with-pager     # always install both
./install.sh --no-pager       # CLI-only, headless setups
```

You'll be prompted for one thing: the Telegram bot token from
[@BotFather](https://t.me/BotFather). Paste it (silent input). When install
finishes, the last line printed is your **pairing code**:

```
═══════════════════════════════════════════════════════════
  PAIRING CODE:  XXXX-XXXX
═══════════════════════════════════════════════════════════
```

## Pair the bot from Telegram

After install, the bot is running but isn't connected to a chat yet. Pairing fixes that.

### DM (easiest case)

1. Search Telegram for your bot's @username.
2. Send `/start`. The bot replies with a "✓ Yes, pair me here" button.
3. Tap it.

Every message you DM the bot now reaches claude.

### Group or forum group

Groups need one extra step, because of a Telegram default:

1. Open [@BotFather](https://t.me/BotFather), send `/setprivacy`, pick your bot, choose **Disable**. Otherwise, in groups, the bot only sees messages that @-mention it or reply to its own. (DMs aren't affected — this is a group-only quirk.)
2. Invite the bot to the chat.
3. Tap "✓ Yes, pair me here" when the bot asks. Only the person who invited it can confirm.

In a forum group, every topic spawns its own claude session in whatever default project dir you picked at install. Pin a topic to a different dir with `/mount ~/path` inside it.

### Fallback: manual pairing code

If the button never appears (privacy mode cached, bot isn't admin), use the code printed by `install.sh`:

```
/pair XXXX-XXXX
```

Run `cta pair-code` on your Mac to re-show it.

### Available commands

Send these inside Telegram (in the paired chat, as the paired user):

| Command | Where | What |
|---|---|---|
| `/pair <code>` | Any chat | One-time pairing (consumed on success) |
| `/start` | Any chat | Welcome message + pairing hint |
| `/mount <path>` | Inside a forum topic | Bind that topic to a Mac directory |
| `/dm <path>` | In the bot's DM | Bind the DM to a Mac directory |
| `/unmount` | The mounted topic/DM | Remove that mount |
| `/list` | Anywhere | Show current mounts |
| `/help` | Anywhere | List commands |

### Host-side commands (terminal)

| Command | What |
|---|---|
| `cta status` | Health snapshot (LaunchAgent, tmux, MCP, last activity) |
| `cta start` / `cta stop` | Restart / stop the agent |
| `cta pair-code` | Re-display the pairing code |
| `cta pair-code --reset` | Regenerate (invalidates the previous code) |
| `cta list` | Same as `/list` but in your terminal |
| `cta mount <thread> <path>` | Same as `/mount` but in your terminal |

### Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `/pair` is silent, no reply at all | Pairing code already consumed | `cta pair-code --reset` on host, retry with new code |
| `/pair … did not match` | Wrong code | Run `cta pair-code` to see the current value |
| Bot doesn't respond to anything | Token rejected by Bot API (preflight failed) | Check `~/.claude/channels/telegram/.env`, rerun `./install.sh` |
| `/mount` says "not a directory" | Path doesn't exist on the Mac | Use full path, no relative or shell-globbed paths |
| `/mount` says "inside a forum topic" | You sent it in the chat root, not a topic | Open a topic and resend, or use `/dm` for the DM mount |
| Messages arrive but no claude reply | tmux session crashed / claude died | `tmux attach -t topic-<id>` to inspect; `cta start` to restart |
| Want to start over | — | `cta stop`, delete `~/.claude-telegram-agent/paired.json`, `cta pair-code --reset`, `cta start` |

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

## Project layout

```
.
├── install.sh / uninstall.sh        Top-level installers (chains pager/ optionally)
├── cli/cta                          User-facing CLI (status, mount, pair, …)
├── agent/                           Runtime
│   ├── start_agents.sh              LaunchAgent entry — spawns tmux sessions
│   ├── watch_network.sh             Watchdog (network + MCP plugin health)
│   ├── restart_claude.sh            Single-topic v0 claude restart loop
│   ├── topic-wrapper.sh             Per-topic claude launcher (MULTI_TOPIC)
│   ├── poller/                      Telegram long-poll → tmux dispatch
│   ├── mcp-telegram/                MCP outbound server (one per topic)
│   └── mount-store/                 mounts.json read/write with O_EXCL lock
├── launchagent/                     com.claude-agent.plist template
├── tests/                           bun + shell test suite
├── docs/                            Prose docs + (currently un-published) landing
│   ├── test-plan.md                 Failure-mode matrix
│   └── troubleshooting.md
├── scripts/                         Dev tooling (check-no-secrets pre-commit)
├── skills/                          Claude Code skills
└── pager/                           Companion macOS menu bar app (Claude Pager)
    ├── Sources/ClaudePager/         SwiftUI app
    ├── Package.swift
    └── install.sh                   Builds + signs + installs as a LaunchAgent
```

Pager was its own repo (`claude-telegram-agent-bar`, archived) until
2026-05-13; merged in because they ship together and share `cta` as the
contract.

## Acknowledgements

Architectural ideas borrowed from:

- [RichardAtCT/claude-code-telegram](https://github.com/RichardAtCT/claude-code-telegram) — Python SDK version
- [shaike1/relay](https://github.com/shaike1/relay) — multi-agent variant
- [Claude Code Channels docs](https://code.claude.com/docs/en/channels)

## License

[MIT](LICENSE)
