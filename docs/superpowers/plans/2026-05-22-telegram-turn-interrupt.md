# Telegram turn-interrupt (`/stop`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `/stop` command that aborts the running claude turn for a topic on demand, while keeping the session resumable and leaving queued messages intact.

**Architecture:** A new `ClaudeDaemonRegistry.stopTurn(threadId)` kills the in-flight daemon (SIGTERM→SIGKILL via the existing `ClaudeDaemon.stop()`) **without** deleting the handle or rotating the session UUID — so the next message lazy-respawns and `--resume`s the same conversation. A poller-side `handleStop` wires `/stop` through the existing command dispatch, clears the orphaned typing indicator, and replies. This is the **reliable fallback** path; an in-band graceful interrupt is NOT possible (verified below) so v1 ships the kill-and-respawn path alone.

**Tech Stack:** TypeScript on Bun; `bun test` for unit tests; shell + mock-bot-api harness for e2e.

---

## Decisions locked at plan time (resolves the spec's open questions)

1. **Graceful in-band interrupt is NOT available (Open Q#1 → answered).** Verified 2026-05-22 against the installed CLI (`claude --version` → `2.1.148`) via claude-code-guide: the raw `claude -p --input-format stream-json` CLI has **no documented/implemented in-band interrupt control message**, and SIGINT terminates the whole headless process rather than just the turn. The Agent SDK's `query.interrupt()` does not apply to the raw-CLI subprocess we drive. **→ v1 ships ONLY the kill-and-respawn fallback.** A graceful path is deferred until the CLI gains stream-json interrupt support.

2. **Kill-mid-turn → `--resume` consistency is already proven in production (Open Q#2 → answered).** The inactivity watchdog (`armInFlightWatchdog`, shipped 2026-05-21) already `SIGKILL`s a wedged daemon **mid-turn** and respawns it via `--resume` (see `claude-daemon-registry.ts:315-335` and the crash→respawn path at `:422-448`). That path has run in production since the General-outage fix, so "abort mid-turn then resume the same session" is an exercised behavior, not a new risk. `stopTurn` uses the gentler `SIGTERM` (with the existing 5s→SIGKILL escalation in `ClaudeDaemon.stop()`), which gives claude a chance to release its session `.lock` cleanly — strictly safer than the watchdog's SIGKILL.

3. **The spec's "resolve pending ack glyphs" step is mostly moot (correction).** `onDaemonFlush` (`poller.ts:301-306`) already flips 👀→👌 for every queued message **at flush time** — i.e. the instant the batch is written to claude's stdin, before the turn runs. So by the time a turn is in-flight, its originating messages are already at 👌; there is nothing left to "resolve" for them. Messages that arrive *during* the in-flight turn carry their own 👀 and stay queued; `stopTurn` preserves that queue and they flip to 👌 naturally when the resumed turn flushes. **→ `handleStop` must NOT touch `pendingReadAcks`** (doing so would prematurely flip the *next* turn's glyphs). The one real loose end is the **typing indicator**: an aborted turn emits no `turn-end`, so the normal clear path (`onDaemonTurnEnd` → `clearTypingExternal`) never fires — `handleStop` clears it explicitly.

4. **Scope: in-flight only (spec-faithful).** `/stop` aborts a turn in the `inFlight` state. A topic in `pending` (debounce window, message queued but not yet sent to claude) is treated as "nothing running" — the queued message fires within the debounce window (≤2s) regardless. This matches the spec's "abort ONLY that topic's in-flight turn." Documented as a deliberate v1 limitation.

5. **`/cancel` is NOT aliased to `/stop`.** `/cancel` already means "drop a pending mount" (`handleCancel`, `poller.ts:1130`). Do not overload it. (Resolves spec Open Q#3.)

---

## File Structure

- **`agent/poller/claude-daemon-registry.ts`** (modify) — add `stopTurn(threadId): Promise<boolean>` and a per-handle `stopping` flag; teach the `on('crash')` handler to treat an intentional stop as a clean teardown (no backoff, no respawn schedule). Responsibility: per-topic daemon lifecycle.
- **`agent/poller/claude-daemon-registry.test.ts`** (modify) — unit tests for `stopTurn`.
- **`agent/poller/poller.ts`** (modify) — add `handleStop(msg)`, wire `/stop` into `tryHandleCommand`'s switch, add `/stop` to the `/help` text. Responsibility: Telegram-side command policy.
- **`agent/poller/poller.test.ts`** (modify) — dispatch + no-registry reply test for `/stop`.
- **`tests/e2e/scenarios/stop_resumes_session.sh`** (create) — full-flow e2e: mid-turn `/stop` → ack → next message resumes the same daemon.
- **`docs/superpowers/specs/2026-05-22-telegram-turn-interrupt-design.md`** (modify) — mark Open Q#1/#2/#3 resolved with the findings above.

No new files in the agent runtime — `/stop` is one method + one handler + one dispatch row, mirroring `/restart`.

---

## Task 1: Registry `stopTurn` — abort the in-flight turn, preserve session + queue

**Files:**
- Modify: `agent/poller/claude-daemon-registry.ts` (DaemonHandle interface ~`:54-77`; handle init in `enqueue` ~`:129-139`; crash handler ~`:422-448`; add `stopTurn` near `resetTopic` ~`:224`)
- Test: `agent/poller/claude-daemon-registry.test.ts`

- [ ] **Step 1: Write the failing tests**

Append a new describe block to `agent/poller/claude-daemon-registry.test.ts` (the file already defines `FIXTURE` and a `waitFor` helper at the bottom — reuse them):

```typescript
describe("ClaudeDaemonRegistry stopTurn", () => {
  let reg: ClaudeDaemonRegistry | null = null;
  afterEach(async () => { if (reg) { await reg.shutdown(); reg = null; } });

  test("stopTurn aborts an in-flight turn and returns true; topic stays usable", async () => {
    const texts: string[] = [];
    reg = new ClaudeDaemonRegistry({
      claudeBin: FIXTURE,
      debounceMs: 50,
      // hang-no-result keeps the fake daemon in-flight: it posts text then
      // never emits a result event, so the registry stays in "inFlight".
      daemonOptsFor: () => ({ cwd: "/tmp", env: { FAKE_CLAUDE_MODE: "hang-no-result" } }),
      // High watchdog so the inactivity timer never fires during the test.
      inFlightTimeoutMs: 60_000,
      onText: (_t, s) => texts.push(s),
    });

    reg.enqueue("topic-42", "long running");
    await waitFor(() => texts.length >= 1, 5000);          // turn is now in-flight
    expect(reg.getStatus("topic-42")).toBe("inFlight");

    const stopped = await reg.stopTurn("topic-42");
    expect(stopped).toBe(true);
    expect(reg.getStatus("topic-42")).toBe("idle");        // back to idle, NOT crashed
    expect(reg.daemonCount).toBe(0);                        // subprocess gone

    // Session/topic preserved: a new message lazy-respawns and processes.
    const spawnsBefore = reg.spawnedCount;
    reg.enqueue("topic-42", "after stop");
    await waitFor(() => texts.some((t) => t.includes("after stop")), 5000);
    expect(reg.spawnedCount).toBe(spawnsBefore + 1);        // respawned, not reused
  });

  test("stopTurn returns false when nothing is running (idle topic)", async () => {
    reg = new ClaudeDaemonRegistry({
      claudeBin: FIXTURE,
      debounceMs: 50,
      daemonOptsFor: () => ({ cwd: "/tmp" }),
      onText: () => {},
    });
    reg.enqueue("topic-7", "hi");
    await waitFor(() => reg!.getStatus("topic-7") === "idle", 5000); // turn finished
    expect(await reg.stopTurn("topic-7")).toBe(false);
  });

  test("stopTurn returns false for an absent topic", async () => {
    reg = new ClaudeDaemonRegistry({
      claudeBin: FIXTURE,
      debounceMs: 50,
      daemonOptsFor: () => ({ cwd: "/tmp" }),
      onText: () => {},
    });
    expect(await reg.stopTurn("never-seen")).toBe(false);
  });

  test("messages queued during the in-flight turn survive the stop", async () => {
    const texts: string[] = [];
    reg = new ClaudeDaemonRegistry({
      claudeBin: FIXTURE,
      debounceMs: 50,
      daemonOptsFor: () => ({ cwd: "/tmp", env: { FAKE_CLAUDE_MODE: "hang-no-result" } }),
      inFlightTimeoutMs: 60_000,
      onText: (_t, s) => texts.push(s),
    });

    reg.enqueue("topic-42", "first");
    await waitFor(() => texts.length >= 1, 5000);          // in-flight
    reg.enqueue("topic-42", "queued during turn");          // sits in the queue

    expect(await reg.stopTurn("topic-42")).toBe(true);
    // The preserved queue flushes on respawn → the queued message is processed.
    await waitFor(() => texts.some((t) => t.includes("queued during turn")), 5000);
  });
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd agent && bun test poller/claude-daemon-registry.test.ts -t stopTurn`
Expected: FAIL — `reg.stopTurn is not a function` (method doesn't exist yet).

- [ ] **Step 3: Add the `stopping` flag to the handle type and init**

In `agent/poller/claude-daemon-registry.ts`, add to the `DaemonHandle` interface (after `lastActivityAt`, ~`:76`):

```typescript
  /** True only during stopTurn()'s intentional teardown. The on('crash')
   *  handler checks it to treat the SIGTERM-driven close as a clean stop
   *  (no backoff escalation, no respawn schedule) rather than a real crash —
   *  same idea as the "released" guard, but for /stop. */
  stopping: boolean;
```

In `enqueue`, the handle initializer (the object literal at ~`:129-139`) — add `stopping: false,`:

```typescript
      handle = {
        daemon: null,
        state: "idle",
        queue: [],
        debounceTimer: null,
        backoffMs: 0,
        spawnedCount: 0,
        releasedAt: null,
        inFlightTimer: null,
        lastActivityAt: Date.now(),
        stopping: false,
      };
```

- [ ] **Step 4: Teach the crash handler to honor an intentional stop**

In `spawn`, inside `daemon.on("crash", ...)` (~`:422`), add the `stopping` guard right after the existing `released` guard:

```typescript
    daemon.on("crash", (info: CrashInfo) => {
      const h = this.handles.get(threadId);
      if (!h) return;
      this.clearInFlightTimer(h);
      // Clean exit during release-for-terminal is expected; don't treat as crash.
      if (h.state === "released") return;
      // Intentional /stop teardown: stopTurn() owns the post-stop transition
      // and re-arming. Don't apply crash backoff or schedule a respawn here.
      if (h.stopping) { h.daemon = null; return; }
      h.daemon = null;
      h.state = "crashed";
```

(Leave the rest of the handler unchanged.)

- [ ] **Step 5: Add the `stopTurn` method**

Insert after `resetTopic` (~`:239`, before `shutdown`):

```typescript
  /** Abort the in-flight turn for a topic WITHOUT discarding the session or
   *  queue. Mirrors the kill side of resetTopic but PRESERVES the handle and
   *  does NOT rotate the session UUID — the on-disk session is untouched, so
   *  the next enqueue lazy-respawns and --resumes the SAME conversation. Only
   *  the running turn is dropped.
   *
   *  Returns true if a turn was actually aborted, false if nothing was running
   *  (idle/pending/released/crashed/absent) — lets the caller pick the reply
   *  copy ("Stopped." vs "Nothing running to stop.").
   *
   *  v1 is the reliable fallback (SIGTERM→SIGKILL the subprocess, lazy respawn
   *  on next message). The raw `claude -p --input-format stream-json` CLI has
   *  no in-band interrupt control message and SIGINT kills the whole headless
   *  process (verified 2026-05-22, CLI v2.1.148), so a "leave the subprocess
   *  alive" graceful path is not available yet. */
  async stopTurn(threadId: string): Promise<boolean> {
    const handle = this.handles.get(threadId);
    if (!handle) return false;
    if (handle.state !== "inFlight") return false;
    this.clearInFlightTimer(handle);
    if (handle.debounceTimer) {
      clearTimeout(handle.debounceTimer);
      handle.debounceTimer = null;
    }
    // Mark intentional stop BEFORE awaiting stop() so the on('crash') handler
    // that fires during teardown takes the clean-stop branch (mirrors how
    // releaseForTerminal sets "released" before the await).
    handle.stopping = true;
    if (handle.daemon) {
      // SIGTERM (not SIGKILL): gives claude a chance to release its session
      // .lock cleanly so the next --resume doesn't refuse with "Session ID
      // already in use". stop() escalates to SIGKILL after 5s if needed.
      await handle.daemon.stop("SIGTERM");
      handle.daemon = null;
    }
    handle.stopping = false;
    handle.state = "idle";
    handle.backoffMs = 0;
    handle.lastActivityAt = Date.now();
    // Preserve the queue: any messages that arrived during the aborted turn
    // resume processing on the lazy respawn.
    if (handle.queue.length > 0) this.armDebounce(threadId, handle);
    return true;
  }
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `cd agent && bun test poller/claude-daemon-registry.test.ts -t stopTurn`
Expected: PASS (4 tests). Then run the whole registry suite to confirm no regression:
Run: `cd agent && bun test poller/claude-daemon-registry.test.ts`
Expected: PASS (all existing + new).

- [ ] **Step 7: Commit**

```bash
git add agent/poller/claude-daemon-registry.ts agent/poller/claude-daemon-registry.test.ts
git commit -m "feat(poller): ClaudeDaemonRegistry.stopTurn — abort in-flight turn, keep session

Co-Authored-By: Claude Opus 4.7 <noreply-trailer>"
```

---

## Task 2: Poller `handleStop` + `/stop` dispatch + help text

**Files:**
- Modify: `agent/poller/poller.ts` (add `handleStop` near `handleRestartCmd` ~`:1234`; add a `case "/stop"` in `tryHandleCommand`'s switch ~`:1688`; add a `/stop` line to `handleHelp` ~`:1586`)
- Test: `agent/poller/poller.test.ts`

- [ ] **Step 1: Write the failing test**

Add to the `describe("post-pair state", ...)` block in `agent/poller/poller.test.ts` (it already has `pair()` and the `sent`/`msg` helpers). The module-level `daemonRegistry` singleton is never initialized in these unit tests, so `/stop` exercises the "no turn running" reply path:

```typescript
  test("/stop with no running turn replies 'Nothing running to stop.'", async () => {
    pair();
    sent.length = 0;
    const handled = await poller.tryHandleCommand(
      msg({ text: "/stop", chat_id: -1001, thread_id: 42, from_id: 99 }),
    );
    expect(handled).toBe(true);
    expect(sent.some((m) => m.text.includes("Nothing running to stop"))).toBe(true);
  });

  test("/stop from a non-paired user is silently dropped (no reply)", async () => {
    pair({ user_id: 99 });
    sent.length = 0;
    const handled = await poller.tryHandleCommand(
      msg({ text: "/stop", chat_id: -1001, thread_id: 42, from_id: 12345 }),
    );
    expect(handled).toBe(true);  // consumed so claude doesn't see it
    expect(sent.length).toBe(0); // but no reply leaked
  });
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd agent && bun test poller/poller.test.ts -t "/stop"`
Expected: FAIL — `/stop` falls through to `return false` (unknown command → not consumed), so `handled` is `false` and no "Nothing running" reply is sent.

- [ ] **Step 3: Add the `handleStop` handler**

In `agent/poller/poller.ts`, add immediately after `handleRestartCmd` (~`:1256`):

```typescript
/**
 * Abort the in-flight claude turn for this topic. The session UUID is left
 * untouched, so the next message --resumes the same conversation — only the
 * running turn is dropped. Idempotent: replies "Nothing running to stop." when
 * no turn is in-flight.
 *
 * v1 is kill-and-respawn (registry.stopTurn → SIGTERM→SIGKILL the subprocess,
 * lazy respawn on the next message). The raw stream-json CLI has no in-band
 * interrupt, so there is no "graceful leave-it-alive" path yet (CLI v2.1.148).
 */
async function handleStop(msg: TgMessage): Promise<void> {
  const chat_id = msg.chat.id;
  const thread_id = msg.message_thread_id;
  const key: number | "dm" = thread_id != null ? thread_id : "dm";
  const threadIdStr = String(key);

  let stopped = false;
  if (daemonRegistry) {
    try {
      stopped = await daemonRegistry.stopTurn(threadIdStr);
    } catch (e) {
      process.stderr.write(`poller: handleStop stopTurn failed: ${e instanceof Error ? e.message : String(e)}\n`);
    }
  }

  // The aborted turn emits no turn-end, so onDaemonTurnEnd's clearTypingExternal
  // never fires — clear the typing indicator here so it doesn't keepalive to its
  // cap. (Read-ack glyphs need no handling: onDaemonFlush already flipped the
  // in-flight turn's messages to 👌 at flush time; messages queued during the
  // turn keep their 👀 and flip naturally when the resumed turn flushes.)
  if (isTyping(transport)) {
    void transport.clearTypingExternal({ channel: "telegram", chatId: chat_id, threadId: thread_id });
  }

  await reply(
    { chat_id, thread_id },
    stopped ? "⏹ Stopped." : "Nothing running to stop.",
  );
}
```

- [ ] **Step 4: Wire `/stop` into the command switch**

In `tryHandleCommand`'s switch (~`:1688`), add a `case` next to `/cancel`:

```typescript
    case "/cancel": await handleCancel(msg); return true;
    case "/stop":   await handleStop(msg); return true;
```

- [ ] **Step 5: Add `/stop` to the `/help` text**

In `handleHelp` (~`:1586`), add a line right after the `/restart` entry in the "Session commands" group:

```typescript
      "  /restart        — restart claude on this topic (keep session)",
      "  /stop           — abort the running turn (keeps session; queued messages stay)",
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `cd agent && bun test poller/poller.test.ts -t "/stop"`
Expected: PASS (2 tests). Then the whole poller suite:
Run: `cd agent && bun test poller/poller.test.ts`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add agent/poller/poller.ts agent/poller/poller.test.ts
git commit -m "feat(poller): /stop command — abort the running turn over Telegram

Co-Authored-By: Claude Opus 4.7 <noreply-trailer>"
```

---

## Task 3: E2E scenario — mid-turn `/stop` aborts the turn and the next message resumes

**Files:**
- Create: `tests/e2e/scenarios/stop_resumes_session.sh`

This drives the REAL poller process through the mock Bot API. It uses the
`fake-claude-daemon.sh` fixture in `hang-no-result` mode (posts text, then
stays alive without a result → the registry sits in `inFlight`) so a turn is
genuinely running when `/stop` arrives. The harness copies the whole agent
source into the sandbox, so the fixture is present at
`$CTA_INSTALL_DIR/agent/poller/fixtures/fake-claude-daemon.sh`. The poller
reads `PAGER_CLAUDE_BIN` (registry `claudeBin`) and `FAKE_CLAUDE_MODE` from its
env (see `initDaemonRegistry`, `poller.ts:626`); the harness sources
`$SCENARIO_DIR/plugin/.env` into the poller process, so we write both there.

- [ ] **Step 1: Write the scenario script**

Create `tests/e2e/scenarios/stop_resumes_session.sh`:

```bash
#!/bin/bash
# E2E scenario: mid-turn /stop aborts the running turn, then the next message
# resumes the SAME session (registry.stopTurn preserves the handle + UUID).
#
# Flow:
#   1. Spawn the poller with PAGER_CLAUDE_BIN=fake-claude-daemon.sh and
#      FAKE_CLAUDE_MODE=hang-no-result (turn posts text then hangs → inFlight).
#   2. Inject a plain message → daemon starts a turn, posts "You said: ...",
#      hangs (no result event) → registry stuck inFlight.
#   3. Inject /stop → handleStop → stopTurn kills the daemon → "⏹ Stopped." ack.
#   4. Inject another plain message → registry lazy-respawns + processes it,
#      proving the topic survived the stop (session resume path).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/harness.sh
source "$SCRIPT_DIR/../lib/harness.sh"

echo "▶ scenario: stop_resumes_session"
h_setup_sandbox "stop-resumes-session"
h_spawn_mock

h_seed_paired -1001234 99
h_seed_mount 42 "$SCENARIO_DIR" "iron-flow"
h_seed_session_uuid 42 "stop-uuid-aaaa"

# Point the poller's daemon registry at the fake claude in hang-no-result mode.
mkdir -p "$SCENARIO_DIR/plugin"
{
  echo "PAGER_CLAUDE_BIN=$CTA_INSTALL_DIR/agent/poller/fixtures/fake-claude-daemon.sh"
  echo "FAKE_CLAUDE_MODE=hang-no-result"
  echo "PAGER_DAEMON_DEBOUNCE_MS=100"
} >> "$SCENARIO_DIR/plugin/.env"

h_spawn_poller

# 1) Start a turn that hangs in-flight.
h_inject_text 42 "do something long" 99 -1001234
if h_wait_for_capture sendMessage \
   '[.[] | select(.body.text|test("You said: do something long"))] | length >= 1' 10; then
  h_ok "first turn started (assistant text streamed)"
else
  h_ng "first turn did not stream text within 10s"
  h_dump_captures
fi

# 2) /stop aborts it.
h_inject_text 42 "/stop" 99 -1001234
if h_wait_for_capture sendMessage \
   '[.[] | select(.body.text|test("Stopped"))] | length >= 1' 10; then
  h_ok "/stop acked with 'Stopped.'"
else
  h_ng "did NOT receive Stopped ack within 10s"
  h_dump_captures
fi

# 3) Next message resumes the topic (new turn runs → respawn worked).
h_inject_text 42 "are you back" 99 -1001234
if h_wait_for_capture sendMessage \
   '[.[] | select(.body.text|test("You said: are you back"))] | length >= 1' 10; then
  h_ok "topic resumed after /stop (next message processed)"
else
  h_ng "topic did NOT resume after /stop"
  h_dump_captures
fi

# Session UUID must be UNCHANGED (stop preserves the session; only /clear rotates).
UUID="$(tr -d '\n' < "$CTA_STATE_DIR/sessions/42" 2>/dev/null || true)"
if [[ "$UUID" == "stop-uuid-aaaa" ]]; then
  h_ok "session UUID preserved across /stop (still stop-uuid-aaaa)"
else
  h_ng "session UUID changed across /stop (got: '$UUID')"
fi

echo
echo "scenario stop_resumes_session: $H_PASS passed, $H_FAIL failed"
[[ "$H_FAIL" -eq 0 ]]
```

- [ ] **Step 2: Make it executable**

Run: `chmod +x tests/e2e/scenarios/stop_resumes_session.sh`

- [ ] **Step 3: Run the scenario**

Run: `bash tests/e2e/run.sh stop_resumes_session`
Expected: `scenario stop_resumes_session: 4 passed, 0 failed` and exit 0.

If the first turn never streams text, confirm the env wiring landed: the
poller log (`tmux -S "$TMUX_SOCKET" capture-pane -t poller -p`) should show the
daemon spawning the fixture. If `PAGER_CLAUDE_BIN` isn't being read, verify
`h_spawn_poller` sources `$SCENARIO_DIR/plugin/.env` (it does via the `plugin_env`
line in `harness.sh:151,162`).

- [ ] **Step 4: Run the full e2e suite to confirm no regression**

Run: `bash tests/e2e/run.sh`
Expected: all scenarios pass (previously 8/8, now 9/9 including this one).

- [ ] **Step 5: Commit**

```bash
git add tests/e2e/scenarios/stop_resumes_session.sh
git commit -m "test(e2e): mid-turn /stop aborts turn and next message resumes session

Co-Authored-By: Claude Opus 4.7 <noreply-trailer>"
```

---

## Task 4: Sync the design spec's open questions

**Files:**
- Modify: `docs/superpowers/specs/2026-05-22-telegram-turn-interrupt-design.md`

- [ ] **Step 1: Resolve the open questions in the spec**

Replace the `## Open questions to resolve at plan time` section (the last section, ~`:86-94`) with the resolved findings:

```markdown
## Open questions — RESOLVED at plan time (2026-05-22)

1. **In-band stream-json interrupt? NO.** Verified against CLI v2.1.148: the
   raw `claude -p --input-format stream-json` accepts no documented interrupt
   control message, and SIGINT kills the whole headless process. v1 ships the
   kill-and-respawn fallback ONLY; the graceful stage-1 is deferred until the
   CLI gains the capability.
2. **`--resume` consistent after a mid-turn kill? YES (already proven).** The
   inactivity watchdog (shipped 2026-05-21) already SIGKILLs daemons mid-turn
   and respawns via `--resume` in production. `/stop` uses the gentler SIGTERM
   (with the existing 5s→SIGKILL escalation), which releases the session lock
   cleanly — strictly safer than the watchdog path.
3. **`/stop` copy + `/cancel` alias?** Reply is `⏹ Stopped.` (turn aborted) or
   `Nothing running to stop.` (idempotent no-op). `/cancel` is NOT aliased — it
   already means "drop a pending mount."

Note: the spec's "resolve pending ack glyphs on stop" step proved unnecessary —
`onDaemonFlush` flips 👀→👌 at flush time, so an in-flight turn's glyphs are
already resolved. `/stop` clears only the orphaned typing indicator.
```

Also update the header line `Status:` to:

```markdown
Status: planned (docs/superpowers/plans/2026-05-22-telegram-turn-interrupt.md); v1 = fallback only
```

- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/specs/2026-05-22-telegram-turn-interrupt-design.md
git commit -m "docs(spec): resolve turn-interrupt open questions at plan time

Co-Authored-By: Claude Opus 4.7 <noreply-trailer>"
```

---

## Final verification

- [ ] Run the full agent unit suite: `cd agent && bun test`
- [ ] Run the full e2e suite: `bash tests/e2e/run.sh`
- [ ] Both green → ready to ship (`/ship` opens the PR). After deploy, smoke-test
      live per [[project-pager-install-deploy-gotcha]] is NOT required (no Pager
      binary changed — agent-only), but verify the poller restarts cleanly and
      a real mid-turn `/stop` in Telegram aborts a long turn and the next
      message resumes.

---

## Self-Review (completed)

- **Spec coverage:** Behavior section → Tasks 1+2 (`/stop` aborts in-flight only; "Nothing running" idempotent reply; partial text stays via existing onText; typing cleared). Interrupt mechanism → Task 1 (fallback `stop()`+lazy `--resume`; graceful stage-1 explicitly deferred per the verified CLI limitation). Touch points → all four files covered (slash-commands.ts needs NO change — `/stop` is not a JSONL-derived command, so it lives in poller dispatch, not slash-commands.ts; noted as a correction). Ack-glyph resolution → analyzed and shown unnecessary (correction documented). Session preserved → Task 1 (no UUID rotation) + Task 3 assertion. Future enhancements (inline ⏹ button, steer) → correctly out of scope.
- **Placeholder scan:** none — every step has concrete code/commands/expected output.
- **Type consistency:** `stopTurn(threadId: string): Promise<boolean>` used identically in registry (Task 1), tests (Task 1), and `handleStop` (Task 2). `stopping: boolean` added to `DaemonHandle` and initialized in `enqueue`. `handleStop(msg: TgMessage)` matches the existing handler signatures and the `case "/stop"` dispatch.
```