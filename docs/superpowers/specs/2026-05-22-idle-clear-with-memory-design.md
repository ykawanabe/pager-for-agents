# Idle session clear with memory flush — design

Date: 2026-05-22
Status: design approved (Yusuke — "作ってmergeして再起動まで")
Decision owner: Yusuke

## Problem

The opt-in idle feature today is **evict, not clear**: `sweepIdle → resetTopic`
SIGTERMs the daemon to reclaim RAM but leaves the session UUID on disk, so the
next message `--resume`s the **same** session. For a topic whose transcript has
bloated (the dm/General session hit 5.1 MB on 2026-05-22, per-turn cost climbing
$14→$17 and each turn replaying the whole context), eviction does nothing for
cost or latency — the bloat persists across the evict/respawn.

The pain is concrete: after an agent restart killed the warm daemon, the first
dm message cold-started + `--resume`d the 5.1 MB session under `--effort max` and
took minutes, feeling like the bot ignored the user.

## Goal

On idle past the configured threshold, **clear** a bloated topic (rotate its
session UUID → next message starts a fresh, cheap session) instead of merely
evicting it — but **flush durable memory first** so the fresh session doesn't
lose what mattered. Small/cheap sessions keep today's evict-only behavior (RAM
reclaim, no context loss).

## Decisions (locked with Yusuke)

- **Action = clear, not compact.** Sidesteps the unverified "can the stream-json
  daemon be told to `/compact`" dependency entirely. Clear = rotate the
  per-topic session UUID (same lever as `/clear`).
- **Size-gated.** Only sessions whose JSONL exceeds a threshold are cleared.
  Small sessions are left on the cheap evict path (don't nuke a 5-message chat
  every hour for no benefit — the memory #2 "don't compact tiny sessions" guard).
- **Remember before clearing.** Before rotating, run one "flush memory" turn that
  tells claude to append durable notes to `~/.pager/shared-context.md`. That file
  is already in every daemon's `--append-system-prompt` (the cross-session memory
  convention), so the fresh session picks the notes up with **no extra wiring**.
- **Reuse the existing setting.** `idle_evict_minutes` (settings.json, `cta config
  idle-evict`, Pager toggle) stays the single knob for "how long idle before the
  sweep acts." Default 60. The size threshold is an env constant, not a new UI
  field.

## Approach (chosen: Option A — flush to shared-context.md)

Considered for the memory destination:
- **A. Append to `~/.pager/shared-context.md`** (CHOSEN) — the global cross-session
  memory file every daemon already reads via its system prompt. Fresh session
  recovers the notes for free. Minimal. Risk: global file mixes topics and can
  itself grow — acceptable for a single-operator bot; it's 5.8 KB today and the
  convention keeps entries short.
- **B. Per-topic carryover file** — cleaner separation but needs new per-topic
  `--append-system-prompt` wiring so the fresh daemon reads its own file. Deferred
  (build only if A's mixing becomes a problem).
- **C. Seed the summary as the new session's first message** — burns a turn before
  the user speaks and is awkward to trigger. Rejected.

## Behavior

The idle sweep (housekeeping tick, gated on `idle_evict_minutes > 0`) inspects
each idle-eligible topic (state `idle`, empty queue, alive daemon, idle ≥ N min):

- **Large session** (JSONL size > `IDLE_CLEAR_MIN_BYTES`, default 1 MB):
  1. Run a **flush turn** on the still-alive daemon: a fixed prompt instructing
     claude to append durable context (user prefs, ongoing tasks, open decisions,
     key facts) to `~/.pager/shared-context.md`, then reply with one short
     user-facing line. The reply posts to the topic normally (good UX — the user
     sees "saved context, started fresh to stay fast").
  2. On flush turn-end (or a hard timeout), if the topic is **still idle with an
     empty queue** (no real message arrived mid-flush), rotate the session UUID
     (the `/clear` lever) and `resetTopic`. The next message starts fresh.
  3. If a real message arrived during the flush, **skip the clear** this round —
     the memory was saved anyway and the user is clearly back; let the
     conversation continue (it'll re-qualify next idle window if still large).
- **Small session** (≤ threshold): `resetTopic` only — today's evict behavior
  (keep UUID, RAM reclaim, no context loss).

### Non-blocking requirement (load-bearing)

The sweep runs inside the main poll loop's housekeeping tick. The flush turn can
take minutes on a bloated session, so it MUST NOT be `await`ed in the tick —
blocking the tick stalls `getUpdates` and makes the bot unresponsive. The flush +
clear runs as a **detached background task** (`void flushAndClear(...)`), with a
per-topic in-progress guard so subsequent ticks don't launch a second flush for
the same topic.

## Components

- **`ClaudeDaemonRegistry.idleCandidates(idleMs): string[]`** — returns idle-eligible
  topic IDs **without** side effects (replaces the all-in-one `sweepIdle` for the
  new poller-driven decision; `sweepIdle` is removed since its only caller moves
  to this split). Eligibility: state `idle`, empty queue, alive daemon, `now -
  lastActivityAt ≥ idleMs`.
- **`ClaudeDaemonRegistry.runTurnAndWait(threadId, text, timeoutMs): Promise<"completed" | "timeout" | "skipped">`**
  — send `text` directly to the topic's alive idle daemon (bypassing debounce),
  transition to `inFlight`, and resolve on that turn's `turn-end` or after
  `timeoutMs`. Returns `"skipped"` if the daemon isn't alive/idle. A per-handle
  one-shot resolver, fired by the existing `turn-end` handler.
- **`ClaudeDaemonRegistry.isIdleEmpty(threadId): boolean`** — true if state `idle`
  and queue empty (the post-flush "still safe to clear?" check).
- **Poller `rotateSessionUuid(key)`** — extracted from `handleClear`'s UUID-rotation
  block; reused by both `handleClear` and idle-clear (DRY).
- **Poller `flushAndClear(threadIdStr)`** — the detached orchestrator: build flush
  prompt → `runTurnAndWait` → if `isIdleEmpty`, `rotateSessionUuid` + `resetTopic`.
- **Poller sweep rewrite** (poller.ts:2049) — iterate `idleCandidates`, size-gate
  via the JSONL path (`jsonlPathForMount`/`jsonlPathForSession`), launch
  `flushAndClear` (large) or `resetTopic` (small); track in-progress flushes.

## Config

- `idle_evict_minutes` — unchanged knob (default 60; 0 = off). Now means "idle
  threshold for the sweep" (evict small, flush+clear large).
- `IDLE_CLEAR_MIN_BYTES` — env, default `1048576` (1 MB). Sessions above this are
  cleared (with flush); at/below are evicted.
- `IDLE_FLUSH_TIMEOUT_MS` — env, default `180000` (3 min). Hard cap on the flush
  turn before abandoning it.
- **Pager** `SettingsView.swift` — update the toggle copy from "Close idle sessions
  to free memory" to reflect the new behavior, e.g. "Reset long idle conversations
  (saves key context first)" + a one-line footnote. Single label change; no new
  control.

## Error handling

- Flush turn errors / times out → log, do NOT clear (leave the session; it'll
  re-qualify next window). Never leave a topic stuck `inFlight` — `runTurnAndWait`
  always resolves (turn-end, timeout, or skipped) and the existing inactivity
  watchdog is a backstop.
- `rotateSessionUuid` write failure → log, skip clear (registry untouched).
- Background `flushAndClear` rejection → caught + logged; never crashes the tick.
- In-progress guard prevents overlapping flushes for the same topic.

## Testing

- Registry: `idleCandidates` returns only eligible idle topics (not pending/inFlight/
  released/crashed, not too-recent, not empty-of-daemon).
- Registry: `runTurnAndWait` resolves `"completed"` on turn-end (fake daemon),
  `"timeout"` when no turn-end before the cap, `"skipped"` for a non-idle/dead topic.
- Registry: `isIdleEmpty` true only when idle + empty queue.
- Poller/registry: a large idle session → flush turn runs (prompt sent), then UUID
  rotates + topic resets; a small idle session → evict only, UUID unchanged.
- Poller: a message arriving during the flush aborts the clear (UUID preserved).
- E2E (optional): idle-clear end-to-end with the fake daemon + a seeded large JSONL.

## Out of scope (v1)

- Per-topic carryover files (Option B) — only if shared-context mixing bites.
- Compaction (`/compact`) — replaced by clear.
- Pager UI beyond the one label change (no separate size-threshold control).
