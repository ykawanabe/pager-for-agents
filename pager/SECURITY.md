# Security policy

## What this app does and doesn't do

Claude Pager is a status monitor. It:

- Reads process info (`ps`), launchd state (`launchctl list`), and tmux session listings (`tmux ls`) to determine whether the Telegram bot is alive.
- Writes the bot token and allowlist to canonical paths under `~/.claude/channels/telegram/` (mode `600`).
- Shells out to Terminal.app via AppleScript when you click "Watch bot live" or "Show recent activity".

It does NOT:

- Connect to Telegram itself (the bot subprocess does).
- Send any data off your Mac.
- Modify any files outside `~/.claude/channels/telegram/`.

## Threat model

The interesting attack surface is the **bot the app monitors**, not the app itself — see the companion project's [SECURITY.md](https://github.com/ykawanabe/claude-telegram-agent/blob/main/SECURITY.md) for the real threat model. The bot runs Claude Code with `--dangerously-skip-permissions`, so anyone who can DM the bot has shell-level access to your Mac.

Specific to this app:

- **Token storage.** The Settings UI writes the token to `~/.claude/channels/telegram/.env` with `chmod 600`. The file is plaintext, locked to owner read/write.
- **Allowlist UI.** Editing access.json from the UI overwrites the file. We preserve `groups` and `pending` keys; we replace `dmPolicy` and `allowFrom`. If those fields had unusual values, they'll be lost.
- **No code signing yet.** Downloaded binaries from GitHub Releases are notarized; locally-built binaries from `./install.sh` are unsigned. macOS Gatekeeper will warn on first launch of an unsigned build.

## Reporting a vulnerability

Use GitHub's [Private Vulnerability Reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability) on this repo — click **Report a vulnerability** under the Security tab. I'll acknowledge within 72 hours.

If the issue is in SwiftUI / AppKit itself, please report it to Apple via [Feedback Assistant](https://developer.apple.com/bug-reporting/).
