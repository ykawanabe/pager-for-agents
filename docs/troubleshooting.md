# Troubleshooting

## Agent not running after login

The agent is two `launchd` jobs: the poller (`com.claude-agent`) and the
watchdog (`com.claude-watchdog`). Check them:

```sh
cta status
launchctl list | grep com.claude
```

If a job isn't loaded, `cta start` loads both. To force a clean restart:

```sh
cta stop
cta start
```

Then inspect the logs:

```sh
tail -n 100 ~/.pager/agent.log
tail -n 100 ~/.pager/agent.err.log
```

## `claude: command not found` inside the LaunchAgent

LaunchAgents don't inherit your shell's PATH. `install.sh` resolves the
absolute paths to `bun` and `claude` at install time and bakes them into the
plist / `start_agents.sh`. If you move or reinstall either binary afterward,
rerun `./install.sh` so the paths are re-resolved.

## Telegram messages not arriving in Claude

1. Confirm the bot token is present: `~/.claude/channels/telegram/.env` should
   hold `TELEGRAM_BOT_TOKEN=...`. A rejected token fails the poller's startup
   preflight — `~/.pager/agent.log` says so on the first lines after a restart.
2. Confirm the allowlist matches your Telegram user ID. Messages from anyone
   not on the allowlist are silently dropped.
3. Confirm the chat is paired: `cta status` shows the paired chat, or send
   `/pair <code>` (run `cta pair-code` to see the code).
4. Watch it live: `tail -f ~/.pager/agent.log` shows each inbound update being
   routed to its topic's `claude` daemon.

## The bot stopped responding after a network blip

The watchdog (`com.claude-watchdog`) kickstarts the poller whenever its
heartbeat (`~/.pager/heartbeat-poller`) goes stale, so a hung poller heals
itself within a couple of minutes. To force it now: `cta start`. To confirm
both jobs are alive: `cta status`.

## How to stop everything temporarily

```sh
cta stop      # unloads both LaunchAgents; SIGTERMs the poller + its claude daemons
```

Bring it all back with `cta start`.
