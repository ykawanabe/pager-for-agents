# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `cta config ack <on|off>` — toggle the bot's per-message ack reaction without hand-editing access.json. `on` writes `ackReaction: "👀"` (Telegram's whitelist-friendly "seen" emoji), `off` removes the key entirely. Plugin re-reads access.json per request so the change is live on the next message (no bot restart). Default emoji kept in sync with Pager's `kDefaultAckEmoji` constant. 5 new tests in `test_cta.sh` (round-trip, allowlist preservation, key removal on off, invalid-value rejection, missing-file error).

## [0.1.3] - 2026-05-12

Hotfix. Bot stopped auto-recovering after a network reconnect: watchdog kicked the session, but `restart_claude.sh` then crashlooped indefinitely with "Session ID is already in use" and the bot never came back online.

### Fixed
- **`restart_claude.sh` used `claude --session-id <uuid>` for every restart, but that flag only works on FIRST launch.** Once the session jsonl exists under `~/.claude/projects/<encoded-cwd>/<uuid>.jsonl`, claude refuses with `Error: Session ID <uuid> is already in use.` and exits in <1s. Symptom: at 14:37 on 2026-05-12, `watch_network.sh` fired "Connectivity restored — restarting claude session"; the new claude immediately exited; backoff climbed 3 → 6 → 12 → 24 → 48 → 60s and stuck at the cap forever. Bot stayed dead until manual intervention. Now `restart_claude.sh` checks whether the session jsonl already exists and chooses the right flag: `--session-id` for the first launch (so claude creates the session under our chosen UUID), `--resume` for every subsequent restart (so it picks up the existing transcript instead of trying to claim an already-claimed UUID). Pure path arithmetic extracted into `session_arg_flag()` for unit testing. Four new regression tests in `test_restart_claude.sh` pin the contract (no jsonl → `--session-id`, jsonl exists → `--resume`, different UUID → `--session-id`, different cwd → `--session-id`).

## [0.1.2] - 2026-05-12

Hotfix. Continued live `/qa` after v0.1.1 surfaced one more bug: the Telegram bot was randomly silent after a restart cycle.

### Fixed
- **`cta stop` left an orphan `bun` MCP process behind.** Killing the tmux session killed the `claude` process, but the official telegram plugin's bun grandchildren (the wrapper `bun run --cwd …/telegram` and its `bun server.ts` child) reparented to launchd and kept long-polling Telegram's `getUpdates`. The next `cta start` spawned a fresh bun → two consumers raced for `getUpdates` → ~half of inbound messages went to the orphan, which had no claude listening and silently dropped them. Symptom: the bot replied to roughly every other message after a restart, with no log line on the dropped side. Now `cmd_stop` targets the plugin's bun tree directly: `pgrep -f "claude-plugins-official.*telegram.*start"` for the wrapper, then `pgrep -P <wrapper-pid>` for the bun server child. **Critically, it does NOT pkill any `bun server.ts` on the system** — only the children of a process matching the plugin's command line. A user running their own `bun server.ts` in another project is untouched. Four new regression tests in `test_cta.sh` pin the contract (kills wrapper, kills child, searches the plugin pattern, never searches a generic `bun.*server\.ts`).

## [0.1.1] - 2026-05-12

Hotfix release. Two v0.1.0 regressions surfaced during live `/qa` verification.

### Fixed
- **`cta` couldn't find `tmux` under launchd's stripped PATH.** When Claude Pager (or any launchd-spawned caller) shelled out to `cta status`, the `tmux has-session` calls silently failed with "command not found" and cta reported `tmux: false` for both sessions even when they were healthy. Symptom: Pager's Diagnostics window showed `✗ tmux sessions` while the bot was fully operational. Root cause: launchd ships a stripped default PATH (`/usr/bin:/bin:/usr/sbin:/sbin`) that doesn't include `/opt/homebrew/bin` (Apple Silicon) or `/usr/local/bin` (Intel). All four scripts (`cta`, `start_agents.sh`, `watch_network.sh`, `restart_claude.sh`) now prepend `$HOME/.bun/bin:/opt/homebrew/bin:/usr/local/bin` and append `$HOME/.local/bin` so child commands resolve regardless of caller context. Three new regression tests in `test_cta.sh` pin the PATH augmentation under stripped-PATH conditions.
- **`cta start` was destructive — it killed and respawned both tmux sessions even when the bot was already healthy.** `start_agents.sh` is intentionally destructive for fresh boots and recovery, but `cta start` is the "make sure it's up" command and must not drop a running conversation. Pager calls this on every launch via `ensureBotRunning()`; every Pager launch was taking the bot offline for ~3 seconds and churning the claude PID. `cta start` is now idempotent — if both sessions are alive, it logs "Already running" and returns. Two new regression tests pin this contract.

## [0.1.0] - 2026-05-12

First tagged release. The bot survives crash, sleep, and network drops on macOS; companion menu-bar app ([Claude Pager](https://github.com/ykawanabe/claude-telegram-agent-bar)) now talks to the agent through `cta` instead of greping `ps`.

### Added
- `install.sh` interactive installer (deps check, token + allowlist prompts, LaunchAgent registration).
- `uninstall.sh` with `--purge-telegram` opt-in for removing the plugin secrets too.
- `scripts/restart_claude.sh` `while true` loop that respawns claude on exit. Now does **exponential backoff** (3→6→12→24→48→60s cap) so a misconfigured token or missing plugin can't hot-loop the log file past the 10MB rotation threshold. A run that survives ≥30s resets the ladder, so transient hiccups don't leave the next failure waiting a full minute.
- `scripts/watch_network.sh` ping watchdog. Recovers from three failure modes: network outage, Telegram-only outage, silent MCP plugin death (claude alive but `bun server.ts` gone). New in 0.1.0: **orphan-session kick** — if the claude tmux session vanishes entirely (manual kill, `restart_claude.sh` died, OOM), watchdog kicks it past a 60-second startup grace. Previously the bot stayed dead until reboot.
- `scripts/cta` — single source of truth for "what is the agent doing?" Emits a versioned JSON status (`cta status --json`, schema_version=1) covering LaunchAgent state, claude PID/RSS, MCP server, tmux sessions, and last bot activity. Plus `cta start` / `cta stop`. Pager (and any future UI) reads this instead of re-implementing process detection — agent-side changes (rename a session, switch runtime) won't break the UI as long as schema stays backward-compatible. Schema version bumps reserved for breaking changes (F1+F2 multi-topic).
- `scripts/start_agents.sh` tmux session launcher with startup log rotation (10MB threshold, 30-day archive retention).
- `launchagent/com.claude-agent.plist.template` for login auto-start.
- `docs/troubleshooting.md`.
- `tests/` shell test suite — 51 tests across 4 files. Covers `compute_next_delay` (backoff progression and healthy-run reset), `past_startup_grace` (orphan-kick gating), `mcp_healthy`, `kick_claude_session`, `cta status --json` (schema validity + custom session names + down-state), and the `check-no-secrets` hook. Wired into CI.

### Fixed
- `scripts/check-no-secrets.sh` email regex used PCRE negative lookahead (`(?!example\.com)`), which BSD/macOS `grep -E` doesn't support — the email check silently no-op'd. Switched to a plain regex with an explicit `ALLOW` post-filter (`@example.com`, `@example.org`, `@example.net`, `users.noreply.github.com`).
- `install.sh` printf used a variable inside the format string (SC2059). Switched to `%s` + arg.
- `install.sh` `sed` substitution on user-supplied `CLAUDE_CWD` no longer breaks when the path contains `|`, `&`, or `\` (escapes the replacement before writing `.env`).
- `install.sh` Telegram bot token regex tightened to `^[0-9]{8,12}:[A-Za-z0-9_-]{35,}$` — matches `check-no-secrets.sh` so a typo can't slip past the installer and then trip the commit hook later.
- `uninstall.sh` sources `.env` (when present) and uses the configurable `TMUX_SESSION_CLAUDE` / `TMUX_SESSION_WATCHDOG` names instead of hardcoded `claude` / `watchdog`. Customized sessions no longer get orphaned on uninstall.
- `# shellcheck source=/dev/null` directives moved adjacent to each `source` call so SC1090 stays suppressed under newer shellcheck.

### Notes
- PATH in the LaunchAgent template includes both `/opt/homebrew/bin` (Apple Silicon) and `/usr/local/bin` (Intel), plus `~/.bun/bin` so the Telegram plugin's `bun` subprocess resolves correctly.
- `cta` schema is versioned (`schema_version: 1`). The companion Pager app (>= v0.1.0) only parses `schema_version == 1` and degrades gracefully on mismatch.
