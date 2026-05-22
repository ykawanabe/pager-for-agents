# Telegram turn-interrupt (`/stop`) — design

Date: 2026-05-22
Status: design approved (Yusuke), not yet planned/implemented
Decision owner: Yusuke ("Bでいいかな" — B locked)

## Problem

When the bot's claude daemon is mid-turn, sending another Telegram message does
NOT stop it. The poller `enqueue`s inbound messages onto a per-topic queue
(debounced) and processes them on the NEXT turn — there is no way to abort the
running turn. A long or wrong turn must finish before anything else happens. The
user's pain is specifically "I can't stop a runaway/long turn," not "I want every
message to interrupt."

## Approach (chosen: B — explicit `/stop`)

Considered three models when a message arrives mid-turn:
- **A. Auto-interrupt** — any new message aborts the current turn. REJECTED:
  chat is bursty (people send "also…", "and check X" in a row); the debounce/queue
  exists precisely for that. Auto-abort would destroy useful in-flight work and
  feel chaotic.
- **B. Explicit `/stop`** — plain messages keep queuing (correct for adding
  context); only an explicit `/stop` (and, later, a tappable "⏹ Stop" inline
  button) aborts the running turn. CHOSEN: solves the real pain (stop on demand)
  without surprise interruptions.
- **C. Steer mid-turn** — inject the new message into the running turn to redirect
  without losing work. DEFERRED: feasibility unverified (needs CLI stream-json to
  accept an interrupt/steer control message) and it's a different, more ambitious
  feature than "let me stop it."

## Behavior

- Normal messages: unchanged — debounce + per-topic queue + process next turn.
- `/stop` (in any topic): abort ONLY that topic's in-flight turn. If no turn is
  running, reply something like "Nothing running to stop." (idempotent, no error).
- Partial assistant text already streamed to Telegram stays (multi-message UX).
  The aborted turn emits no `turn-end`; the bot posts a short "⏹ Stopped." ack.
- Pending ack glyphs (👀 awaiting 👌) for the interrupted turn must be resolved
  so they don't hang — flip/clear them on stop (see ack fan-in in poller.ts).
- After stop, the session is preserved: the next message resumes the SAME session
  (`--resume <uuid>`), so context isn't lost — only the in-flight turn is dropped.

## Interrupt mechanism (two-stage)

1. **Graceful first (preferred, needs verification):** send a stream-json control
   message to the daemon's stdin to interrupt the current turn, leaving the
   subprocess alive and the session clean. REQUIRES confirming `claude -p
   --input-format stream-json` accepts an interrupt control request (the Agent SDK
   exposes `query.interrupt()`; whether the raw CLI stream-json input honors a
   `{"type":"control_request",...}` / interrupt envelope must be verified against
   the installed claude version — check via claude-code-guide / docs before
   building). If supported, this is the clean path (no cold start, partial turn
   persisted by claude itself).
2. **Reliable fallback (always works):** `ClaudeDaemon.stop()` the subprocess
   (SIGTERM → SIGKILL escalation already implemented) and let the registry respawn
   it lazily on the next enqueue with `--resume`. Same shape as
   `ClaudeDaemonRegistry.resetTopic`. Cost: a cold start on the next message and
   claude may not persist the aborted partial turn to JSONL — acceptable for an
   explicit stop. Watch the per-session `~/.claude/tasks/<uuid>/.lock` cleanup
   (shutdown handler already releases it; verify on mid-turn kill).

Ship the fallback first (guaranteed to work); upgrade to graceful once the CLI
control-message support is confirmed.

## Touch points (code)

- `agent/poller/slash-commands.ts` — add `/stop` parsing/dispatch (currently
  handles `/clear`, `/cancel`; no turn-abort today).
- `agent/poller/claude-daemon.ts` — add an `interrupt()` (graceful control message)
  alongside the existing `stop(signal)`; `send()`/`stop()` shapes already exist.
- `agent/poller/claude-daemon-registry.ts` — a `stopTurn(threadId)` that tries
  `interrupt()` then falls back to `stop()`+lazy-respawn (mirror `resetTopic`).
- `agent/poller/poller.ts` — wire `/stop` through dispatch; resolve the topic's
  pending-read-ack handles on stop; post the "⏹ Stopped." reply via the transport.
- Tests: slash-commands `/stop`, daemon interrupt/stop, registry stopTurn, an e2e
  scenario (mid-turn `/stop` → turn ends, next message resumes same session).

## Future enhancements (out of scope for v1)

- "⏹ Stop" inline button (more discoverable than a slash command). Needs a host
  message to attach the button to — e.g. attach it to the working/typing
  indicator. Adds a posted message; weigh intrusiveness.
- Option C (steer mid-turn) once graceful interrupt + message-injection is proven.

## Open questions to resolve at plan time

1. Does the installed `claude -p --input-format stream-json` accept an interrupt
   control message? (Determines whether stage-1 graceful is available at v1 or the
   fallback ships alone.)
2. On mid-turn SIGTERM, does claude persist the partial turn to the session JSONL,
   and does `--resume` stay consistent? (Affects what the user sees after `/stop`.)
3. Exact `/stop` reply copy + whether to also accept `/cancel` as an alias (note:
   `/cancel` currently means "drop a pending mount" — don't overload).
