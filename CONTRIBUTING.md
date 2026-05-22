# Contributing

Thanks for your interest. This project is small and opinionated; here's how to land changes.

## Before you start

- File an issue describing the change *before* sending a PR for anything non-trivial. Saves both of us from a rejected diff.
- Bug reports: include `sw_vers`, Mac arch (`uname -m`), `claude --version`, `bun --version`, and the relevant lines from `~/.pager/agent.log`.

## Local development

```sh
git clone https://github.com/ykawanabe/pager-for-agents.git
cd pager-for-agents
shellcheck install.sh uninstall.sh scripts/*.sh
bash -n install.sh        # syntax check
./install.sh              # run on your own machine
```

The installer is destructive in the sense that it writes to `~/.local/bin/`, `~/.claude/`, and `~/Library/LaunchAgents/`. Test in a throwaway user account or VM if you're modifying installer logic.

## Style

- Bash everywhere (not zsh) — explicit `#!/bin/bash` shebang and `set -euo pipefail` (except the watchdog loop, which must keep running through transient errors).
- Comments in English.
- Quote all variable expansions: `"$VAR"` not `$VAR`. Pass `shellcheck` cleanly.
- Don't reach for new tools (Python, jq, ...) without good reason. The point of this project is to be a thin shell layer.

## What's out of scope

- Cross-platform support (Linux, Windows). This project is macOS-specific by design.
- Containerization. If you want containers, use [shaike1/relay](https://github.com/shaike1/relay).
- Multi-project routing. Possibly a future feature (see roadmap in README), but PRs that bolt on partial implementations will be declined.

## Security-sensitive changes

Anything touching the bot token, allowlist policy, or `--dangerously-skip-permissions` flag handling is high-stakes. Open an issue first to discuss. See [SECURITY.md](SECURITY.md) for the threat model.
