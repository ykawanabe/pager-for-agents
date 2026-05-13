---
name: bind-telegram-topic
description: Bind the currently-running claude session to a Telegram forum topic (or DM) so messages route into THIS pane instead of spawning a fresh per-topic claude.
---

# bind-telegram-topic

Use this skill when the user wants to attach their current claude session to a
Telegram topic. After binding, any message the user sends to that topic in
Telegram is delivered into THIS pane via tmux send-keys, and any reply this
claude writes (via `send_telegram`) goes back to the topic.

## Hard requirement

This claude must be running inside `tmux`. `cta bind` refuses if `$TMUX` is
unset. If the user is in a bare terminal, instruct them to:

1. `tmux new -s work` (or attach to an existing session)
2. Re-run claude inside that session
3. Invoke this skill again

## Workflow

1. Ask the user for the `thread_id`. They can read it from any Telegram
   message URL in the target topic: right-click the message → Copy Link →
   the trailing number after the chat id is the `thread_id`. For direct
   messages to the bot, the thread_id is the literal string `dm`.

2. Run `cta bind <thread_id>` from a shell — Bash tool. cta reads the
   current tmux session name and pane cwd, writes a mounts.json entry, and
   prints a confirmation.

3. Tell the user the bind succeeded and that the poller will now route
   messages from that topic into THIS pane. The poller hot-reloads
   mounts.json so no restart is needed.

## Failure modes worth surfacing

- **already mounted**: `cta umount <thread_id>` first, then re-bind. Don't
  silently take over a binding the user may have intentionally set.
- **poller not running**: `cta status` to check. Bind will still record the
  mount, but routing won't take effect until `cta start`.
- **bare terminal**: see Hard requirement above.

## Don't

- Don't try to guess the `thread_id` — always ask.
- Don't run `cta mount` instead of `cta bind` — that spawns a fresh tmux
  session running its own claude, which is the opposite of what bind does.
