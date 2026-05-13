# Claude Pager

A tiny menu bar app for macOS that shows whether your [Claude Code Telegram bot](https://github.com/ykawanabe/claude-telegram-agent) is alive — at a glance, all the time.

Sits in the menu bar as a paperplane icon:

| Icon | Meaning |
|---|---|
| `paperplane.fill` | Everything is up: claude is running, the Telegram plugin is polling, both tmux sessions are alive. |
| `paperplane` | Partial — the bot is up but one of the supporting tmux sessions is missing. |
| `exclamationmark.triangle.fill` | Down — the Telegram bot isn't running or the MCP plugin has died. |

Click the icon for details, a one-tap "Watch bot live" terminal, and a Settings… pane to manage the Telegram bot token and allowed user IDs.

## Companion project

This is the GUI half of a pair. The CLI half — the actual launchd-managed bot — lives at [ykawanabe/claude-telegram-agent](https://github.com/ykawanabe/claude-telegram-agent). Install that first.

## Requirements

- macOS 14+ (Sonoma)
- Swift 5.10+ (ships with Xcode 15.3+)
- Apple Silicon or Intel — both supported

## Install

```sh
git clone https://github.com/ykawanabe/claude-telegram-agent.git
cd claude-telegram-agent/pager
./install.sh
```

`install.sh` builds a release binary, copies it to `~/.local/bin/claude-pager`, registers a LaunchAgent (`com.claude-pager`), and starts it. The icon appears in the menu bar within a second.

## What the menu shows

```
Online
Last seen 3 min ago
───────────────
Watch bot live
Show recent activity
Restart bot
Run diagnostics…
───────────────
Settings…   ⌘,
Quit Claude Pager  ⌘Q
```

When the bot is degraded or offline the top line changes to `Degraded` / `Offline` and the menu lists the specific broken components (e.g. `Bot not running`, `Plugin not polling`).

- **Watch bot live** — opens Terminal attached to the bot's tmux session. You see exactly what messages Claude is receiving and replying with, in real time.
- **Show recent activity** — tails the agent log (`~/.claude-telegram-agent/agent.log`).
- **Restart bot** — kicks the underlying `start_agents.sh` to restart both tmux sessions.
- **Run diagnostics…** — walks the full pipeline (token → Telegram `getMe` → send a test message → local processes) and reports which step failed.

## Settings

Open with `⌘,` from the menu. Two sections:

- **Telegram bot token** — masked SecureField; written to `~/.claude/channels/telegram/.env` with mode `600`. The official Claude Code Telegram plugin auto-discovers this path.
- **Allowed users** — numeric Telegram user IDs. Stored in `~/.claude/channels/telegram/access.json` as an `allowlist` policy. An empty list silently downgrades to `open` policy (anyone can DM the bot — not recommended).

After saving, restart the bot from the menu so the plugin re-reads the env file.

## Security

The bot runs Claude Code with `--dangerously-skip-permissions`. Anyone who can DM the bot has the same shell-level privileges Claude has on your Mac. This app:

- Stores the bot token at mode 600 in `~/.claude/channels/telegram/`.
- Provides a UI for setting the allowlist so you don't forget.

That's the extent of the security model. The threat is the bot itself — see the companion project's [SECURITY.md](https://github.com/ykawanabe/claude-telegram-agent/blob/main/SECURITY.md).

## Development

```sh
swift test
```

Covers `AgentStatus.color` traffic-light logic, `TelegramConfig` env / allowlist round-trips, and the `Diagnostics` report formatter. CI runs the same suite on every push.

## Upgrade

Re-run `./install.sh` — it rebuilds and reloads the LaunchAgent.

## Uninstall

```sh
./uninstall.sh
```

Removes the binary, plist, and unloads the agent. Logs at `~/Library/Logs/claude-pager/` are preserved.

## Distribution

Pre-built binaries are ad-hoc signed for distribution. Download the latest `.zip` from [Releases](https://github.com/ykawanabe/claude-telegram-agent/releases/latest). On first launch, right-click the app → Open to bypass Gatekeeper once.

If you run an unsigned dev build (via `swift run` or unsigned `./install.sh`), Gatekeeper may complain on first launch. Right-click the binary → Open → Confirm.

## License

[MIT](LICENSE)
