# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `install.sh` interactive installer (deps check, token + allowlist prompts, LaunchAgent registration).
- `uninstall.sh` with `--purge-telegram` opt-in for removing the plugin secrets too.
- `scripts/restart_claude.sh` `while true` loop that respawns claude on exit.
- `scripts/watch_network.sh` ping watchdog that kicks the claude tmux session when connectivity returns after an outage.
- `scripts/start_agents.sh` tmux session launcher.
- `launchagent/com.claude-agent.plist.template` for login auto-start.
- `docs/troubleshooting.md`.

### Notes
- PATH in the LaunchAgent template includes both `/opt/homebrew/bin` (Apple Silicon) and `/usr/local/bin` (Intel), plus `~/.bun/bin` so the Telegram plugin's `bun` subprocess resolves correctly.
