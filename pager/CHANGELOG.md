# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-05-12

First tagged release. Pairs with [claude-telegram-agent v0.1.0](https://github.com/ykawanabe/pager-for-agents/releases/tag/v0.1.0).

### Added
- SwiftUI menu bar app (`MenuBarExtra`) with three states: `paperplane.fill` (healthy) / `paperplane` (degraded) / `exclamationmark.triangle.fill` (offline).
- `CTAClient` — typed wrapper around the agent's `cta status --json` (schema_version=1). Pager now reads agent state through this single contract instead of re-implementing process detection. Agent-side changes (rename a tmux session, switch plugin runtime) don't break Pager as long as cta's schema stays compatible.
- `StatusMonitor` polls `cta status --json` every 5s and maps the result into `AgentStatus`. When `cta` isn't installed (older agent build, or agent never installed), Pager surfaces "agent not installed" instead of a generic red. Schema-mismatch surfaces explicitly too.
- Menu actions: Watch bot live, Show recent activity, Restart bot, Run diagnostics…, Settings, Quit.
- `Diagnostics` end-to-end pipeline check — validates token via Telegram `getMe`, sends a real test message, then samples the local runtime; reports per-step pass/fail in an alert so the user knows exactly which link is broken.
- Settings scene with token + allowlist editor (writes to `~/.claude/channels/telegram/{.env,access.json}` with `chmod 600`).
- `install.sh` builds a release binary, places it at `~/.local/bin/claude-pager`, registers a `com.claude-pager` LaunchAgent with `KeepAlive=dict{SuccessfulExit=false}` so clean Quit stays dead but crashes respawn.
- Intel and Apple Silicon both supported (tmux binary resolved across `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`).
- Singleton `StatusMonitor` to survive SwiftUI's double-init of `@main App`.
- Non-blocking pipe drain in `Process.run()` to avoid the 64 KB pipe-buffer deadlock.
- XCTest suite (`Tests/ClaudePagerTests/`) covering `AgentStatus.color`, `CTAClient` JSON-decode (happy path, nullable fields, custom session names), `TelegramConfig` env/allowlist round-trips, and the `Diagnostics` report formatter. CI runs `swift test` on every push.

### Changed
- **`StatusMonitor` no longer scrapes processes directly.** Previously hardcoded the tmux session names `claude:` and `watchdog:`, which silently broke for any user who customized `TMUX_SESSION_CLAUDE` / `TMUX_SESSION_WATCHDOG` in the agent's `.env`. Now reads those names from the agent's `cta status --json` output — end-to-end customization works.
- **`AgentControl` no longer calls `launchctl` and `tmux` directly to start/stop the bot.** Delegates to `cta start` / `cta stop`. Pager doesn't need to know which plist or which sessions exist — the agent owns that.
- `TelegramConfig.init` now accepts optional `envPath` / `accessPath` parameters (defaulting to the canonical `~/.claude/channels/telegram/` paths) so tests can read and write against temp directories.

### Fixed
- Red state previously asked for `paperplane.slash`, which doesn't exist in the SF Symbols catalog. SwiftUI silently refused to render the menu bar item when status was red — the icon would just disappear. Switched red to `exclamationmark.triangle.fill`.
- Removed a duplicate `NSApplication.shared.setActivationPolicy(.accessory)` call from `App.init` — `LSUIElement=true` in Info.plist already does this, and the duplicate was reported to conflict with MenuBarExtra registration on some macOS versions.

### Requires
- claude-telegram-agent v0.1.0 or later (needs the `cta` CLI to exist on disk). On older agent installs Pager renders an "agent not installed" state instead of crashing.
