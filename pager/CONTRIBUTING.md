# Contributing

Thanks for your interest. This is a small SwiftUI menu bar utility.

## Before you start

- File an issue before sending a PR for anything beyond a typo or small bug.
- Bug reports: include macOS version (`sw_vers`), Mac arch (`uname -m`), Swift version (`swift --version`), and the relevant lines from `~/Library/Logs/claude-pager/pager.err.log`.

## Local development

```sh
git clone https://github.com/ykawanabe/claude-telegram-agent.git
cd claude-telegram-agent/pager
swift build
swift run ClaudePager   # debug build, runs in foreground; Ctrl-C to quit
```

For an iterative loop while the LaunchAgent-managed copy is running:

```sh
# Edit code
swift build -c release
launchctl unload ~/Library/LaunchAgents/com.claude-pager.plist
cp .build/release/ClaudePager ~/.local/bin/claude-pager
launchctl load ~/Library/LaunchAgents/com.claude-pager.plist
```

Or just re-run `./install.sh`.

## Style

- Swift 5.10+.
- Concurrency: `Task.detached` for any shell-out work. Never block the main actor.
- File reads/writes use `chmod 600` for credentials, `700` for credential directories.
- No emoji in source code (icons and labels can use SF Symbols).
- Match the surrounding code's verbosity — short methods, sparse comments, explain *why* not *what*.

## What's out of scope

- Multi-platform UI (iOS, iPad). This is a Mac menu bar utility.
- Telegram message sending from the app itself (use Claude directly via the bot).
- Mac App Store distribution. We use too many APIs that the MAS sandbox blocks (process inspection, AppleScript, file writes outside the container). See [SECURITY.md](SECURITY.md) for the rationale.

## Security-sensitive changes

Anything touching token storage or the allowlist UI is high-stakes — open an issue first.
