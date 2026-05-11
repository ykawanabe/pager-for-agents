# Troubleshooting

## tmux sessions not running after login

Check the LaunchAgent status:

```sh
launchctl list | grep com.claude-agent
```

If it's not listed, reload it:

```sh
launchctl unload ~/Library/LaunchAgents/com.claude-agent.plist 2>/dev/null
launchctl load   ~/Library/LaunchAgents/com.claude-agent.plist
```

Then inspect the log:

```sh
tail -n 100 ~/.claude-telegram-agent/agent.log
tail -n 100 ~/.claude-telegram-agent/agent.err.log
```

## `claude: command not found` inside the LaunchAgent

LaunchAgents don't inherit your shell's PATH. The plist sets PATH to include
`/opt/homebrew/bin`, `/usr/local/bin`, and `~/.local/bin`. If you installed
`claude` somewhere else, edit `~/Library/LaunchAgents/com.claude-agent.plist`
and add that directory to the PATH key, then reload the agent.

## Telegram messages not arriving in Claude

1. Confirm the bot token is configured: inside Claude Code, run
   `/telegram:configure` and re-paste the token.
2. Confirm the allowlist matches your Telegram user ID. If you locked the
   channel to a different account, your messages will be silently dropped.
3. Confirm `claude` was started with `--channels plugin:telegram@...`. Run
   `tmux attach -t claude` and check the startup banner.

## Network recovery doesn't restart claude

The watchdog only kicks the session when state changes from offline → online.
If the Mac was online the whole time but `claude` itself died, the restart
loop inside `restart_claude.sh` is what brings it back — check that loop is
still running with `tmux attach -t claude`.

## "Address already in use" or duplicate-session errors

Run the start script again — it kills existing sessions before spawning new
ones:

```sh
~/.local/bin/start_agents.sh
```

## How to stop everything temporarily

```sh
launchctl unload ~/Library/LaunchAgents/com.claude-agent.plist
tmux kill-session -t claude
tmux kill-session -t watchdog
```

Reload the plist to bring it all back.
