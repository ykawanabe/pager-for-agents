# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `install.sh` interactive installer (deps check, token + allowlist prompts, LaunchAgent registration).
- `uninstall.sh` with `--purge-telegram` opt-in for removing the plugin secrets too.
- `scripts/restart_claude.sh` `while true` loop that respawns claude on exit.
- `scripts/watch_network.sh` ping watchdog that kicks the claude tmux session when connectivity returns after an outage.
- Silent-MCP-death detection in the watchdog: if `claude --channels` is alive but `bun server.ts` has exited, restart the session after 3 consecutive failed checks (~30s).
- `scripts/start_agents.sh` tmux session launcher.
- `launchagent/com.claude-agent.plist.template` for login auto-start.
- `docs/troubleshooting.md`.
- `tests/` shell test suite covering `mcp_healthy`, `kick_claude_session`, and the `check-no-secrets` hook. Wired into CI.

### Fixed
- `scripts/check-no-secrets.sh` email regex used PCRE negative lookahead (`(?!example\.com)`), which BSD/macOS `grep -E` doesn't support — the email check silently no-op'd. Switched to a plain regex with an explicit `ALLOW` post-filter (`@example.com`, `@example.org`, `@example.net`, `users.noreply.github.com`).
- `install.sh` printf used a variable inside the format string (SC2059). Switched to `%s` + arg.
- `# shellcheck source=/dev/null` directives moved adjacent to each `source` call so SC1090 stays suppressed under newer shellcheck.

### Notes
- PATH in the LaunchAgent template includes both `/opt/homebrew/bin` (Apple Silicon) and `/usr/local/bin` (Intel), plus `~/.bun/bin` so the Telegram plugin's `bun` subprocess resolves correctly.
